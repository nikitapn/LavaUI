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

/// Last known window-space pointer position, updated on every `.mouseMove`.
///
/// Exists because `.scroll` events carry no position of their own (a wheel
/// notch has no coordinates) — a handler that wants to know *where* the
/// wheel happened, to zoom a chart around the cursor rather than its center,
/// has nowhere else to ask. One frame stale at worst, same as any
/// event-driven position cache.
public enum PointerState {
    nonisolated(unsafe) private static var last: (x: Float, y: Float) = (0, 0)

    public static func set(x: Float, y: Float) { last = (x, y) }
    public static var window: (x: Float, y: Float) { last }
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

/// Routes an OS drag-and-drop to whichever node it landed on. The node
/// under the drop point is resolved the same way hover is (`hitTestHover`);
/// unlike hover, this is a one-shot lookup at the moment the drop event
/// arrives, not a continuously tracked position.
public enum DropRouter {
    nonisolated(unsafe) private static var handlers: [NodeID: ([String]) -> Void] = [:]

    public static func register(_ id: NodeID, handler: @escaping ([String]) -> Void) {
        handlers[id] = handler
    }

    public static func unregister(_ id: NodeID) { handlers[id] = nil }

    /// So hit-testing can treat a drop-registered box as a valid target even
    /// though it carries no visual hover feedback of its own (see
    /// `LayoutHost.hoverWalk`).
    public static func hasHandler(_ id: NodeID) -> Bool { handlers[id] != nil }

    /// Delivers to `target` if it has a registered handler. Returns true if
    /// consumed — a caller can use this to decide whether to fall back to
    /// some other drop behavior (or none).
    @discardableResult
    public static func deliver(to target: NodeID?, paths: [String]) -> Bool {
        guard let target, let handler = handlers[target] else { return false }
        handler(paths)
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
    /// Nodes wanting more than a fill swap — a button retargeting its
    /// animation, say — register here.
    nonisolated(unsafe) private static var handlers: [NodeID: (Bool) -> Void] = [:]

    public static func isHovered(_ id: NodeID) -> Bool { hovered == id }

    public static func register(_ id: NodeID, handler: @escaping (Bool) -> Void) {
        handlers[id] = handler
    }

    public static func unregister(_ id: NodeID) { handlers[id] = nil }

    /// Returns true when the hovered node actually changed.
    @discardableResult
    public static func set(_ id: NodeID?) -> Bool {
        guard hovered != id else { return false }
        let previous = hovered
        hovered = id
        if let previous { handlers[previous]?(false) }
        if let id { handlers[id]?(true) }
        // Hover only changes pixels, never view values — the cheapest level.
        ViewInvalidation.markNeedsRedraw()
        return true
    }

    public static func clear() { set(nil) }
}
