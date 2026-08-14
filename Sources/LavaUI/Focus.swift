import Foundation

/// Which node currently receives keyboard input.
///
/// Focus is keyed by `NodeID` rather than by a view value, because the view
/// struct is rebuilt every frame while the node persists — the same reason
/// `@State` storage lives on the node side.
///
/// Per window (state lives on `WindowScope`), which is both what the OS does
/// and what users expect: clicking into another window and back leaves the
/// field you were editing still focused. A single process-wide focus would
/// also mean a key event delivered to one window reaching a field in another.
public enum FocusManager {
    public static var focusedID: NodeID? { WindowScope.currentOrMain.focused }

    public static func isFocused(_ id: NodeID) -> Bool {
        WindowScope.currentOrMain.focused == id
    }

    public static func focus(
        _ id: NodeID,
        onKey: @escaping (KeyEvent) -> Bool,
        onChar: @escaping (Character) -> Bool
    ) {
        let scope = WindowScope.currentOrMain
        if scope.focused != id { ViewInvalidation.markDirty() }
        scope.focused = id
        scope.keyHandler = onKey
        scope.charHandler = onChar
    }

    public static func resignFocus(_ id: NodeID) {
        guard WindowScope.currentOrMain.focused == id else { return }
        clear()
    }

    public static func clear() {
        let scope = WindowScope.currentOrMain
        if scope.focused != nil { ViewInvalidation.markDirty() }
        scope.focused = nil
        scope.keyHandler = nil
        scope.charHandler = nil
    }

    /// Declares where keys go when *nothing* is focused.
    ///
    /// For a window whose whole purpose is one keyboard target — a terminal,
    /// a game, a full-window editor. Focus is a click-driven idea, and it is
    /// the right one where a window holds several things worth typing into;
    /// applied to a window holding exactly one, it produces an application
    /// that ignores the keyboard until you have told it which of its one
    /// thing you meant.
    ///
    /// A fallback rather than a permanent claim, so anything that genuinely
    /// wants focus — a find bar, a rename prompt — still takes it and gives
    /// it back on its own terms. Nothing here overrides `focus`.
    public static func setDefault(
        _ id: NodeID,
        onKey: @escaping (KeyEvent) -> Bool,
        onChar: @escaping (Character) -> Bool
    ) {
        let scope = WindowScope.currentOrMain
        scope.defaultFocus = id
        scope.defaultKeyHandler = onKey
        scope.defaultCharHandler = onChar
    }

    /// Whether `id` receives keys right now, either by holding focus or by
    /// being the default while nothing does. What a caret should be drawn on.
    public static func isActive(_ id: NodeID) -> Bool {
        let scope = WindowScope.currentOrMain
        return scope.focused == id || (scope.focused == nil && scope.defaultFocus == id)
    }

    /// Routes a key to the focused node. Returns true if it was consumed, so
    /// the app can fall through to global shortcuts otherwise.
    @discardableResult
    public static func handle(_ event: KeyEvent) -> Bool {
        let scope = WindowScope.currentOrMain
        if let handler = scope.keyHandler { return handler(event) }
        return scope.defaultKeyHandler?(event) ?? false
    }

    @discardableResult
    public static func handle(character: Character) -> Bool {
        let scope = WindowScope.currentOrMain
        if let handler = scope.charHandler { return handler(character) }
        return scope.defaultCharHandler?(character) ?? false
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
    public var alt: Bool { KeyMods.contains(mods, KeyMods.alt) }
    public var superKey: Bool { KeyMods.contains(mods, KeyMods.superKey) }
}

/// Caret blink, expressed as a phase rather than a timer.
///
/// The plan called for deciding this deliberately rather than drifting into it:
/// a blinking caret dirties a frame twice a second forever, which is the one
/// thing that defeats idle frame-gating. The compromise here is to blink only
/// while focused, and to hold the caret solid for a moment after any edit so
/// it never blinks mid-typing.
///
/// The phase is a pure function of the clock, so it is shared; what is per
/// window (`WindowScope.caretLastPhase`) is the *last phase this window
/// drew*, since two windows both showing a caret would otherwise consume each
/// other's flips and one of them would stop blinking.
public enum CaretBlink {
    public static let period: Double = 1.0
    nonisolated(unsafe) private static var lastEditAt: Double = 0

    public static func noteEdit() {
        lastEditAt = now()
        WindowScope.currentOrMain.caretLastPhase = true
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
        let scope = WindowScope.currentOrMain
        let visible = isVisible
        defer { scope.caretLastPhase = visible }
        return visible != scope.caretLastPhase
    }

    /// Adopts the current phase without reporting a change. The blink is
    /// suspended while the window is invisible, so `lastPhase` is stale by an
    /// arbitrary number of periods on restore; the caller redraws once anyway
    /// and only wants the *next* `phaseChanged()` to be meaningful.
    public static func resync() {
        WindowScope.currentOrMain.caretLastPhase = isVisible
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

    /// Called when the pointer leaves this window entirely.
    ///
    /// A window hears about the pointer only while it is inside, so "it has
    /// gone" is information no amount of watching positions can produce. A
    /// dock that reveals itself on approach hides again from here; hover
    /// clearing is handled without it.
    nonisolated(unsafe) public static var onLeave: (@Sendable () -> Void)?

    static func left() { onLeave?() }
}

/// How many leaves want to know where the pointer is *inside* them.
///
/// Hover identity is the renderer's answer now — it has the pointer and the
/// node rects, and asking the producer would be a round trip for something
/// already known. What the renderer cannot answer is where inside a node the
/// pointer landed in the widget's own terms: a `Scene3D` picks by projecting
/// its scene, geometry the renderer has never seen.
///
/// So that question still costs a tree walk per motion event — and this is
/// what stops every app paying for it. Nearly none have such a widget, and
/// those apps do no work on a mouse move at all, which is the property that
/// made moving hover into the renderer worth doing.
enum LocalHoverTargets {
    nonisolated(unsafe) private(set) static var liveCount = 0

    static var isInUse: Bool { liveCount > 0 }

    /// Counts transitions, not assignments: a handler reinstalled on every
    /// reconcile — which is what `Scene3D.configure` does — must not read as
    /// another widget each frame.
    static func track(had: Bool, has: Bool) {
        guard had != has else { return }
        liveCount += has ? 1 : -1
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

    /// Drops a capture held by a node that is going away, without running its
    /// `onUp` — the drag is not finishing, its window is closing under it.
    static func discard(ids: Set<NodeID>) {
        guard let owner, ids.contains(owner) else { return }
        self.owner = nil
        moveHandler = nil
        upHandler = nil
    }

    /// Window coordinates; the owner converts to its own space.
    public static func move(x: Float, y: Float) {
        moveHandler?(x, y)
    }

    public static func release() {
        // Cleared *before* the handler runs, so an `onUp` that chains straight
        // into another capture — a drag that hands off to a second phase —
        // keeps it, instead of having it wiped by the lines after the call.
        let handler = upHandler
        owner = nil
        moveHandler = nil
        upHandler = nil
        guard let handler else { return }
        handler()

        // The same rule `.mouseDown` applies after a click handler: a handler
        // exists to change something, so running one is a repaint request.
        // It has to be said here as well because a control that fires on
        // *release* — every `Button` — runs its action from this call and not
        // from that one, and nothing else on the mouse-up path asks for a
        // frame. A live-read presenter like `overlay(isPresented:)` is only
        // resolved during emit, so without this, opening a menu by clicking a
        // button showed nothing until an unrelated event happened to repaint.
        //
        // It used to work by accident: the press tint was an `Animated<Color>`
        // driven by this loop, so the fade back after release re-emitted the
        // draw list for ~0.12s. The renderer owns that tint now and its own
        // frames arrive as `takeInternalRepaint`, which redraws the retained
        // list without re-emitting — so the accident is gone.
        //
        // `.redraw` is the right floor, for the reason `Binding.set`
        // documents: anything that genuinely changed the tree has already
        // raised `.body` through observation.
        ViewInvalidation.markNeedsRedraw()
    }
}

/// Where a wheel notch goes when nothing in the view tree wanted it.
///
/// The renderer stood aside because a node under the pointer claimed the
/// wheel; if that node and every ancestor then declines, the container around
/// them should still scroll — the notch goes back to whoever owns the scene.
/// In one process that is a call into the engine. Under a compositor the scene
/// is in another process, and a client's own engine has no renderer to hand it
/// to, so the notch was simply dropped: an editor inside a scrolling page
/// pinned the page.
///
/// Same shape as `ClipboardBridge`, `DropBridge` and `ScreenshotBridge`, and
/// unset means windowed.
public enum ScrollBridge {
    nonisolated(unsafe) public static var handBack: (@Sendable (Float, Float) -> Void)?

    static func unclaimed(dx: Float, dy: Float, window: WindowID, editor: Editor) {
        if let handBack {
            handBack(dx, dy)
            return
        }
        _ = editor.scrollSceneUnclaimed(dx: dx, dy: dy, window: window)
    }
}

/// Wheel routing. The node under the pointer receives the wheel, focused or
/// not — that is what every desktop app does, and it means scrolling a panel
/// does not steal focus from a field.
///
/// Unlike hover and click, delivery **bubbles**: the caller supplies the whole
/// ancestor chain under the pointer (`LayoutHost.hitTestScrollChain`) and the
/// first eligible handler wins. Routing to the single topmost hit instead meant
/// any interactive child — a button, a text field — silently swallowed the
/// wheel for the `ScrollView` around it.
public enum ScrollRouter {
    private struct Entry {
        let handler: (Float, Float) -> Void
        /// nil means "always takes it": a widget with wheel behavior of its own
        /// consumes deliberately rather than leaking notches to an ancestor.
        let canScroll: ((Float, Float) -> Bool)?
    }

    nonisolated(unsafe) private static var handlers: [NodeID: Entry] = [:]
    /// Modifier state carried on the scroll event, so handlers do not have to
    /// track key state themselves.
    nonisolated(unsafe) public private(set) static var shiftHeld = false

    /// `canScroll` is the nested-scroll policy: a container already pinned at
    /// its end reports false and the notch continues out to the next eligible
    /// ancestor, so an inner list that cannot scroll farther does not deadlock
    /// the outer one. Omit it to consume unconditionally.
    public static func register(
        _ id: NodeID,
        canScroll: ((Float, Float) -> Bool)? = nil,
        handler: @escaping (Float, Float) -> Void
    ) {
        handlers[id] = Entry(handler: handler, canScroll: canScroll)
    }

    public static func unregister(_ id: NodeID) { handlers[id] = nil }

    /// Whether this node has wheel behaviour of its own.
    ///
    /// The emitter asks so it can tell the renderer, which otherwise scrolls
    /// whatever container encloses the node and never lets the handler run.
    /// A registration *is* the claim — the widget makes it by the act of
    /// registering — so there is no second list to keep in step with this one.
    static func claimsWheel(_ id: NodeID) -> Bool { handlers[id] != nil }

    static func unregisterAll(ids: Set<NodeID>) {
        for id in ids { handlers[id] = nil }
    }

    /// Delivers to the innermost node in `chain` that has a handler willing to
    /// take this notch. Returns true if consumed.
    @discardableResult
    public static func deliver(
        to chain: [NodeID], dx: Float, dy: Float, mods: Int32 = 0
    ) -> Bool {
        shiftHeld = KeyMods.contains(mods, KeyMods.shift)
        for id in chain {
            guard let entry = handlers[id] else { continue }
            // Evaluated after `shiftHeld` is published, since eligibility can
            // depend on which axis the notch will end up moving.
            if let canScroll = entry.canScroll, !canScroll(dx, dy) { continue }
            entry.handler(dx, dy)
            return true
        }
        return false
    }

    /// Single-node delivery, for callers that resolved one target themselves.
    @discardableResult
    public static func deliver(
        to target: NodeID?, dx: Float, dy: Float, mods: Int32 = 0
    ) -> Bool {
        deliver(to: target.map { [$0] } ?? [], dx: dx, dy: dy, mods: mods)
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

    static func unregisterAll(ids: Set<NodeID>) {
        for id in ids { handlers[id] = nil }
    }

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
///
/// One id for the whole process, not one per window, because the pointer is
/// one thing: moving from window A into window B has to un-hover A's button,
/// and nothing else reliably reports that. GLFW's cursor-leave would, but only
/// for the window the pointer left — a pointer that jumps straight from one
/// window to another still needs the arrival to do the work. So the *scope*
/// that was current when the hover was set is remembered alongside it, and a
/// cross-window move repaints both windows.
public enum HoverState {
    nonisolated(unsafe) private static var hovered: NodeID?
    /// Which window `hovered` is in, so it can be repainted when the pointer
    /// leaves it for another one.
    nonisolated(unsafe) private static var hoveredScope: WindowScope?
    /// Nodes wanting more than a fill swap — a button retargeting its
    /// animation, say — register here. Keyed by `NodeID`, which is unique
    /// process-wide, so one map serves every window.
    nonisolated(unsafe) private static var handlers: [NodeID: (Bool) -> Void] = [:]

    public static func isHovered(_ id: NodeID) -> Bool { hovered == id }

    public static func register(_ id: NodeID, handler: @escaping (Bool) -> Void) {
        handlers[id] = handler
    }

    public static func unregister(_ id: NodeID) { handlers[id] = nil }

    /// Forgets a closing window's nodes. Clears the hover outright if it was
    /// one of them, so a node that no longer exists cannot stay "hovered" and
    /// block the next real hover from registering as a change.
    static func unregisterAll(ids: Set<NodeID>) {
        for id in ids { handlers[id] = nil }
        if let hovered, ids.contains(hovered) {
            self.hovered = nil
            hoveredScope = nil
        }
    }

    /// Returns true when the hovered node actually changed.
    @discardableResult
    public static func set(_ id: NodeID?) -> Bool {
        guard hovered != id else { return false }
        let previous = hovered
        hovered = id
        hoveredScope = id == nil ? nil : WindowScope.currentOrMain
        if let previous { handlers[previous]?(false) }
        if let id { handlers[id]?(true) }
        // Renderer-owned tints have already repainted. Semantic handlers that
        // change Swift state are responsible for their normal invalidation.
        return true
    }

    public static func clear() { set(nil) }
}
