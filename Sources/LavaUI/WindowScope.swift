import Foundation

/// The per-window half of LavaUI's framework state.
///
/// `ViewInvalidation`, `FocusManager`, `NodeVisibility` and the caret blink
/// were written as process-wide statics under an explicit single-window
/// assumption. With two windows in one process each of them is a bug: window A
/// consuming the invalidation level swallows window B's redraw, a key event
/// delivered to B reaches the field focused in A, and A's `emitTree` clears the
/// visibility set that B's animations are gated on.
///
/// The fix keeps every one of those APIs exactly where it was — forty-odd call
/// sites across widgets say `ViewInvalidation.markNeedsRedraw()` with no window
/// in scope, and threading one through all of them would be both invasive and
/// wrong, since a widget genuinely does not know which window it is in. Instead
/// the *storage* moves here, and the statics resolve to a scope:
///
/// - **Ambient.** The frame loop marks a window current around everything it
///   does for that window — input, body, layout, emit. A widget invalidating
///   from a click handler or a body therefore lands in the right window
///   without ever naming it.
/// - **By node.** `markBodyDirty(node)` cannot use the ambient scope: an
///   `@Observable` model mutated by a handler in window A can be observed by a
///   node in window B, and B is the one that has to recompute. `CompositeNode`
///   captures its scope at mount, when the ambient one is correct by
///   construction, and routes there for the rest of its life.
/// - **Broadcast.** Outside any window phase — `MainQueue` results, deferred
///   `FrameTasks` — there is no answer to "which window", so a coarse
///   invalidation goes to all of them. Wasteful in the case where only one
///   window cared, but never wrong, which is the correct trade for the path
///   that runs once per worker result rather than once per frame.
///
/// Single-window behaviour is unchanged: everything resolves to `.main`.
///
/// What deliberately stays global is anything keyed by `NodeID`, because those
/// ids are unique process-wide and so cannot collide between windows —
/// `ScrollRouter`, `DropRouter`, `PointerCapture`, `AnimationDriver`'s
/// registry. So is anything the *loop* owns rather than a window:
/// `FrameScheduler` (one loop, one sleep, earliest wake wins), `FrameTasks`,
/// `MainQueue`. And so are the resource caches — `FontStore`, `ImageStore`,
/// `Theme` — which is the whole reason a second window is cheap.
///
/// Not thread-safe, and not meant to be: it is read and written by the frame
/// loop only. That is exactly what `MainQueue` exists to preserve.
public final class WindowScope {
    /// For diagnostics only — the window title, typically.
    public let label: String

    /// The engine window this scope drives.
    ///
    /// Here rather than only on `LavaWindow` so a view can ask which window it
    /// is running in (`LavaApp.currentWindow`) without the framework threading
    /// an id through every body — the same ambient answer, from the same
    /// place, as the rest of this type.
    public let windowID: WindowID

    public init(label: String, windowID: WindowID = .main) {
        self.label = label
        self.windowID = windowID
    }

    /// The scope every static resolves to when nothing is current: tests,
    /// `LavaBench`, and the first window of any app.
    nonisolated(unsafe) public static let main = WindowScope(label: "main")

    // ─── Ambient scope ───────────────────────────────────────────────────

    /// The window whose frame is being processed, or `nil` between windows.
    nonisolated(unsafe) public private(set) static var current: WindowScope?

    /// Resolves the scope a static with no window in scope should act on.
    public static var currentOrMain: WindowScope { current ?? main }

    /// Runs `body` with `scope` current, restoring whatever was current
    /// before — nested is fine, and an early return cannot leak the scope.
    @discardableResult
    public static func withCurrent<T>(
        _ scope: WindowScope, _ body: () throws -> T
    ) rethrows -> T {
        let previous = current
        current = scope
        defer { current = previous }
        return try body()
    }

    // ─── Registry ────────────────────────────────────────────────────────

    nonisolated(unsafe) private static var registry: [WindowScope] = []

    /// Registered by the frame loop as each window opens. `main` is not
    /// implicitly a member — a single-window app that never calls this still
    /// works, because broadcast falls back to `main`.
    public static func register(_ scope: WindowScope) {
        guard !registry.contains(where: { $0 === scope }) else { return }
        registry.append(scope)
    }

    public static func unregister(_ scope: WindowScope) {
        registry.removeAll { $0 === scope }
    }

    /// Where a coarse invalidation goes when no window is current.
    static var broadcastTargets: [WindowScope] {
        registry.isEmpty ? [main] : registry
    }

    // ─── Invalidation (see `ViewInvalidation`) ───────────────────────────

    var pending: InvalidationLevel = .body
    var coarseBodyDirty = true
    var dirtyBodyNodes: [ObjectIdentifier: any BodyRecomputable] = [:]

    func raise(_ level: InvalidationLevel) {
        if level > pending { pending = level }
    }

    // ─── Focus (see `FocusManager`) ──────────────────────────────────────

    var focused: NodeID?
    var keyHandler: ((KeyEvent) -> Bool)?
    var charHandler: ((Character) -> Bool)?

    // ─── Caret blink (see `CaretBlink`) ──────────────────────────────────

    /// Per window, so two windows with focused fields do not eat each other's
    /// phase flips. The *timing* stays global: the blink is a function of the
    /// clock, and a solid-after-typing hold belongs to the keyboard, which
    /// only one window has at a time.
    var caretLastPhase = true

    // ─── Visibility (see `NodeVisibility`) ───────────────────────────────

    var visibleNodes: Set<NodeID> = []

    /// False while this window is minimized or occluded. Read by
    /// `AnimationDriver` so a hidden window's animations cost nothing while a
    /// visible window's keep running — the loop-wide gate this replaces could
    /// only express "no window is visible".
    var windowVisible = true
}
