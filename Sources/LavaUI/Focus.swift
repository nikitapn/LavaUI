import Foundation

/// Which node currently receives keyboard input.
///
/// Focus is keyed by `NodeID` rather than by a view value, because the view
/// struct is rebuilt every frame while the node persists — the same reason
/// `@State` storage lives on the node side.
///
/// Single-window assumption, like `ViewInvalidation`. Per-window focus would
/// need this scoped to a `LayoutHost`.
public enum FocusManager {
    nonisolated(unsafe) private static var focused: NodeID?

    /// Set by the focused node at mount/reconcile so key events can reach it
    /// without the app knowing what a text field is.
    nonisolated(unsafe) private static var keyHandler: ((KeyEvent) -> Bool)?
    nonisolated(unsafe) private static var charHandler: ((Character) -> Bool)?

    public static var focusedID: NodeID? { focused }

    public static func isFocused(_ id: NodeID) -> Bool { focused == id }

    public static func focus(
        _ id: NodeID,
        onKey: @escaping (KeyEvent) -> Bool,
        onChar: @escaping (Character) -> Bool
    ) {
        if focused != id { ViewInvalidation.markDirty() }
        focused = id
        keyHandler = onKey
        charHandler = onChar
    }

    public static func resignFocus(_ id: NodeID) {
        guard focused == id else { return }
        clear()
    }

    public static func clear() {
        if focused != nil { ViewInvalidation.markDirty() }
        focused = nil
        keyHandler = nil
        charHandler = nil
    }

    /// Routes a key to the focused node. Returns true if it was consumed, so
    /// the app can fall through to global shortcuts otherwise.
    @discardableResult
    public static func handle(_ event: KeyEvent) -> Bool {
        keyHandler?(event) ?? false
    }

    @discardableResult
    public static func handle(character: Character) -> Bool {
        charHandler?(character) ?? false
    }
}

/// A key transition, decoded from the raw engine event.
public struct KeyEvent {
    public let key: Int32
    public let mods: Int32
    public let isRepeat: Bool

    public init(key: Int32, mods: Int32, isRepeat: Bool = false) {
        self.key = key
        self.mods = mods
        self.isRepeat = isRepeat
    }

    public var shift: Bool { KeyMods.contains(mods, KeyMods.shift) }
    public var control: Bool { KeyMods.contains(mods, KeyMods.control) }
}

/// Caret blink, expressed as a phase rather than a timer.
///
/// The plan called for deciding this deliberately rather than drifting into it:
/// a blinking caret dirties a frame twice a second forever, which is the one
/// thing that defeats idle frame-gating. The compromise here is to blink only
/// while focused, and to hold the caret solid for a moment after any edit so
/// it never blinks mid-typing.
public enum CaretBlink {
    public static let period: Double = 1.0
    nonisolated(unsafe) private static var lastEditAt: Double = 0
    nonisolated(unsafe) private static var lastPhase: Bool = true

    public static func noteEdit() {
        lastEditAt = now()
        lastPhase = true
    }

    public static var isVisible: Bool {
        let t = now()
        // Solid for half a second after typing.
        if t - lastEditAt < 0.5 { return true }
        return t.truncatingRemainder(dividingBy: period) < period / 2
    }

    /// Call once per frame while a field is focused: reports whether the blink
    /// phase flipped, which is the only reason an idle app needs to redraw.
    public static func phaseChanged() -> Bool {
        let visible = isVisible
        defer { lastPhase = visible }
        return visible != lastPhase
    }

    private static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
