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

/// Routes pointer motion to whichever node started a drag.
///
/// Without capture, a drag that leaves the field's bounds would stop extending
/// the selection — the hit test would simply miss. Capture is what makes
/// "press inside, drag anywhere" behave the way every text control does.
public enum PointerCapture {
    nonisolated(unsafe) private static var owner: NodeID?
    nonisolated(unsafe) private static var moveHandler: ((Float, Float) -> Void)?
    nonisolated(unsafe) private static var upHandler: (() -> Void)?

    public static var isActive: Bool { owner != nil }

    public static func capture(
        _ id: NodeID,
        onMove: @escaping (Float, Float) -> Void,
        onUp: @escaping () -> Void = {}
    ) {
        owner = id
        moveHandler = onMove
        upHandler = onUp
    }

    /// Window coordinates; the owner converts to its own space.
    public static func move(x: Float, y: Float) {
        moveHandler?(x, y)
    }

    public static func release() {
        upHandler?()
        owner = nil
        moveHandler = nil
        upHandler = nil
    }
}

/// Wheel routing. The node under the pointer receives the wheel, focused or
/// not — that is what every desktop app does, and it means scrolling a panel
/// does not steal focus from a field.
public enum ScrollRouter {
    nonisolated(unsafe) private static var handlers: [NodeID: (Float, Float) -> Void] = [:]
    /// Modifier state carried on the scroll event, so handlers do not have to
    /// track key state themselves.
    nonisolated(unsafe) public private(set) static var shiftHeld = false

    public static func register(_ id: NodeID, handler: @escaping (Float, Float) -> Void) {
        handlers[id] = handler
    }

    public static func unregister(_ id: NodeID) { handlers[id] = nil }

    /// Delivers to `target` if it is scrollable. Returns true if consumed.
    @discardableResult
    public static func deliver(
        to target: NodeID?, dx: Float, dy: Float, mods: Int32 = 0
    ) -> Bool {
        shiftHeld = KeyMods.contains(mods, KeyMods.shift)
        guard let target, let handler = handlers[target] else { return false }
        handler(dx, dy)
        return true
    }
}

/// Multi-click detection. Kept here rather than in the field so any control
/// can share one notion of what counts as a double click.
public enum ClickCounter {
    /// Generous enough for a deliberate double click, tight enough that two
    /// separate clicks on the same spot are not merged.
    public static let interval: Double = 0.4
    public static let slop: Float = 4

    nonisolated(unsafe) private static var lastAt: Double = 0
    nonisolated(unsafe) private static var lastX: Float = 0
    nonisolated(unsafe) private static var lastY: Float = 0
    nonisolated(unsafe) private static var streak: Int = 0

    /// Returns how many clicks this one continues (1 = single, 2 = double…).
    public static func register(x: Float, y: Float) -> Int {
        let t = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let near = abs(x - lastX) <= slop && abs(y - lastY) <= slop
        streak = (t - lastAt <= interval && near) ? streak + 1 : 1
        lastAt = t
        lastX = x
        lastY = y
        return streak
    }
}

/// Which node the pointer is over.
///
/// Tracked as a single id rather than per-node flags so a move only ever
/// invalidates when the *hovered node changes* — pointer motion arrives per
/// pixel, and redrawing on every one of those would undo the frame gating.
public enum HoverState {
    nonisolated(unsafe) private static var hovered: NodeID?

    public static func isHovered(_ id: NodeID) -> Bool { hovered == id }

    /// Returns true when the hovered node actually changed.
    @discardableResult
    public static func set(_ id: NodeID?) -> Bool {
        guard hovered != id else { return false }
        hovered = id
        ViewInvalidation.markDirty()
        return true
    }

    public static func clear() { set(nil) }
}
