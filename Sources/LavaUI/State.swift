import Foundation
import Observation

// Phase 5 — view-local state.
//
// Two separate problems, deliberately solved by separate mechanisms:
//
//   1. Ownership. A view is a struct rebuilt by its parent on every update,
//      so `@State` declared inside it is brand new each time. The *storage*
//      has to outlive the struct and be re-attached to each fresh copy.
//      That is `StateBox` + `StateTransfer` below.
//
//   2. Change tracking. Knowing that something was mutated, and by whom.
//      That is `Observation` — `StateStorage` is `@Observable`, so simply
//      reading `wrappedValue` inside `withObservationTracking` registers a
//      dependency at property granularity, for `@State` and for any
//      `@Observable` model object a body happens to touch.
//
// Conflating the two is the usual mistake; they need different machinery.

/// The value that actually persists across view rebuilds.
///
/// `@Observable` is what makes a read inside `withObservationTracking` register
/// a dependency, so this is both the storage *and* the change source.
@Observable
public final class StateStorage<Value> {
    public var value: Value
    init(_ value: Value) { self.value = value }
}

/// Indirection so a *copy* of a `State` struct can still rewire the original.
///
/// `Mirror` hands out copies, and a copy's `box` is the same class instance as
/// the original's — so assigning `box.storage` through the copy mutates the
/// real field. That is the entire reason this second level of indirection
/// exists; without it, state could not be transplanted at all.
final class StateBox<Value> {
    var storage: StateStorage<Value>
    init(_ storage: StateStorage<Value>) { self.storage = storage }
}

/// A source of truth owned by a view, surviving that view being rebuilt.
@propertyWrapper
public struct State<Value> {
    let box: StateBox<Value>

    public init(wrappedValue: Value) {
        box = StateBox(StateStorage(wrappedValue))
    }

    public var wrappedValue: Value {
        get { box.storage.value }
        nonmutating set { box.storage.value = newValue }
    }

    /// `$value` — a read/write reference for child views.
    public var projectedValue: Binding<Value> {
        // Bind to the storage, not the box: the box is replaced on transplant,
        // the storage is the thing that persists.
        let storage = box.storage
        return Binding(get: { storage.value }, set: { storage.value = $0 })
    }
}

/// View-local state whose changes only require re-emitting pixels.
///
/// Use this for transient values consumed by an already-retained paint closure:
/// a canvas cursor, drag boundary, hover position, or animation phase. Unlike
/// `State`, reads deliberately do not participate in body observation, and a
/// write raises only `.redraw`. The storage still survives view reconstruction.
///
/// Do not use `DrawState` for values that change view structure, text outside
/// the paint closure, or layout; those require ordinary `State`.
@propertyWrapper
public struct DrawState<Value> {
    final class Storage {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
    final class Box {
        var storage: Storage
        init(_ storage: Storage) { self.storage = storage }
    }

    let box: Box

    public init(wrappedValue: Value) {
        box = Box(Storage(wrappedValue))
    }

    public var wrappedValue: Value {
        get { box.storage.value }
        nonmutating set {
            box.storage.value = newValue
            ViewInvalidation.markNeedsRedraw()
        }
    }
}

/// A two-way reference to a value owned somewhere else.
@propertyWrapper
public struct Binding<Value> {
    private let get: () -> Value
    private let set: (Value) -> Void

    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self.get = get
        self.set = set
    }

    public var wrappedValue: Value {
        get { get() }
        nonmutating set {
            set(newValue)
            // Observation alone is not enough here. Only `view.body` runs
            // inside `withObservationTracking`, and a body that merely passes
            // `$value` to a control never *reads* through the binding — so no
            // dependency is registered and the write notifies nobody. A
            // `Slider` bound to state nothing else displayed moved its knob and
            // repainted nothing at all.
            //
            // `redraw`, not `body`, is the right floor. If a body did read the
            // value, `onChange` raises `body` on its own and this is harmless;
            // if nothing read it, the only thing that can have changed is what
            // the control itself draws, and it maintains that on its node. The
            // difference is not academic: `body` implies a full Yoga pass, and
            // forcing one per pointer pixel put ~5ms between a drag and the
            // pixels, which is exactly the lag it looks like.
            ViewInvalidation.markNeedsRedraw()
        }
    }

    public var projectedValue: Binding<Value> { self }

    /// A binding that never changes. For previews and for controls that are
    /// shown in a fixed state — a disabled toggle has to display *something*,
    /// and inventing a throwaway `@State` for it is worse.
    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { _ in })
    }
}

// MARK: - Transplanting storage across rebuilds

/// Implemented by every property wrapper whose storage must outlive the view.
protocol StateProperty {
    /// Adopt `other`'s storage, discarding the freshly-initialised storage this
    /// copy was born with.
    func adoptStorage(from other: Any)
}

extension State: StateProperty {
    func adoptStorage(from other: Any) {
        guard let previous = other as? State<Value> else { return }
        box.storage = previous.box.storage
    }
}

extension DrawState: StateProperty {
    func adoptStorage(from other: Any) {
        guard let previous = other as? DrawState<Value> else { return }
        box.storage = previous.box.storage
    }
}

enum StateTransfer {
    /// Re-attaches `old`'s state storage onto the freshly built `new`.
    ///
    /// `Mirror` is read-only, which is fine: it yields copies whose `box` is
    /// shared with the real field, so mutating through the copy lands on `new`.
    ///
    /// This is correct but reflective, and it runs per composite node per
    /// update. If it ever shows up in a profile, replace it with a `@View`
    /// macro synthesising a typed `_adoptState(from:)` — same semantics, no
    /// `Mirror`. Do not do that first: the macro is an optimisation, not a
    /// correctness fix.
    static func adopt<V>(into new: V, from old: V) {
        let newFields = Mirror(reflecting: new).children
        let oldFields = Mirror(reflecting: old).children
        guard !newFields.isEmpty else { return }

        for (newChild, oldChild) in zip(newFields, oldFields) {
            guard let target = newChild.value as? any StateProperty else { continue }
            target.adoptStorage(from: oldChild.value)
        }
    }
}

// MARK: - Invalidation

/// How much of the pipeline a change actually invalidates.
///
/// Levels are ordered and inclusive: `body` implies `layout` implies `redraw`.
/// The distinction earns its keep with animation — a colour fade must not
/// re-run every `body` and every `Mirror`-based state transplant sixty times a
/// second just to change a pixel value.
public enum InvalidationLevel: Int, Comparable, Sendable {
    case none = 0
    /// Re-emit the draw list. Layout and view values are unchanged.
    case redraw = 1
    /// Re-run Yoga, then emit.
    case layout = 2
    /// Recompute bodies, reconcile, lay out, emit.
    case body = 3

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A retained node that can re-evaluate its own `body` in place, using
/// whatever `view` value it already holds — no new value from a parent is
/// needed, because nothing about *that value* changed; only some
/// `@State`/`@Observable` property it reads did, and that storage is a
/// reference type living outside the struct, so it is already current.
/// `CompositeNode` is the only conformer; the protocol exists so
/// `ViewInvalidation` can hold a dirty node without depending on its
/// generic view type.
public protocol BodyRecomputable: AnyObject {
    func recomputeBody()

    /// Which window this node's tree belongs to, captured when it mounted.
    ///
    /// Needed because the node, not the caller, decides where a targeted
    /// `.body` invalidation goes: an `@Observable` model mutated from window
    /// A's click handler can be observed by a node in window B, and B is the
    /// one that has to recompute. The ambient scope at the moment of the
    /// *write* is therefore the wrong answer; the one at the moment of the
    /// *mount* is the right one. `nil` falls back to ambient.
    var invalidationScope: WindowScope? { get }
}

extension BodyRecomputable {
    public var invalidationScope: WindowScope? { nil }
}

/// "Something changed; do at least this much work again."
///
/// The frame loop decides *when* to act on it, which is what keeps the
/// design frame-driven — a state change never synchronously walks the
/// graph. `.body` additionally tracks *which* composite nodes actually need
/// to run again (`markBodyDirty`), so a change three levels deep does not
/// force every unrelated node's body to recompute along with it — only
/// wherever `.body` was raised without naming a node (the first frame, or
/// state that lives outside the View-body-observation system entirely,
/// like a `TextField`'s own buffer) falls back to rebuilding the whole tree,
/// which is always correct, just coarser than it has to be.
///
/// State lives per window on `WindowScope`; every method here resolves to one.
/// A coarse mark goes to the window whose frame is being processed, or to all
/// of them when that is nobody — see `WindowScope` for why those are the only
/// two answers that are ever right.
public enum ViewInvalidation {
    /// Called from `withObservationTracking`'s `onChange`, i.e. *before* the
    /// new value is written. Raising a level is safe there; reading state is not.
    ///
    /// No node identity here, so this forces a full rebuild from the root —
    /// prefer `markBodyDirty(_:)` wherever a specific node is in scope.
    public static func markDirty() { raiseCoarse() }

    /// A view value changed: bodies must run again. Same "no specific node"
    /// caveat as `markDirty()`.
    public static func markNeedsBody() { raiseCoarse() }

    /// Geometry changed but no view value did — a resize, a font swap.
    public static func markNeedsLayout() { raise(.layout) }

    /// Only pixels changed: an animation tick, a caret blink, a hover fill.
    /// The cheapest level, and the reason the cascade exists.
    public static func markNeedsRedraw() { raise(.redraw) }

    /// `node`'s own tracked state changed. Unlike `markDirty()`, this does
    /// not force every other composite node's body to run again this frame
    /// — only `node`'s, once `consumeDirtyBodyNodes()` processes it.
    ///
    /// Routed by the node rather than by the ambient scope, because the write
    /// that triggered this can come from any window (or none).
    public static func markBodyDirty(_ node: some BodyRecomputable) {
        let scope = node.invalidationScope ?? WindowScope.currentOrMain
        scope.dirtyBodyNodes[ObjectIdentifier(node)] = node
        scope.raise(.body)
    }

    /// Raises `level` on the current window, or on every window when there is
    /// no current one.
    private static func raise(_ level: InvalidationLevel) {
        if let scope = WindowScope.current {
            scope.raise(level)
            return
        }
        for scope in WindowScope.broadcastTargets { scope.raise(level) }
    }

    private static func raiseCoarse() {
        if let scope = WindowScope.current {
            scope.coarseBodyDirty = true
            scope.raise(.body)
            return
        }
        for scope in WindowScope.broadcastTargets {
            scope.coarseBodyDirty = true
            scope.raise(.body)
        }
    }

    /// Returns the work required for the current window, clearing its flag.
    public static func consume() -> InvalidationLevel {
        let scope = WindowScope.currentOrMain
        defer { scope.pending = .none }
        return scope.pending
    }

    /// Drains the set of nodes to recompute individually. `nil` means the
    /// caller should rebuild the whole tree from the root instead — either
    /// nothing has been targeted yet (first frame) or `.body` was raised by
    /// something that could not name the node responsible.
    public static func consumeDirtyBodyNodes() -> [any BodyRecomputable]? {
        let scope = WindowScope.currentOrMain
        defer {
            scope.coarseBodyDirty = false
            scope.dirtyBodyNodes.removeAll()
        }
        guard !scope.coarseBodyDirty else { return nil }
        return Array(scope.dirtyBodyNodes.values)
    }

    public static var isDirty: Bool { WindowScope.currentOrMain.pending != .none }
    public static var level: InvalidationLevel { WindowScope.currentOrMain.pending }
}

/// When the frame loop should next wake up.
///
/// Replaces the caret's special case in the run loop. A `Bool` cannot express
/// this: two things animating at once, and whichever finishes first clears the
/// flag for both. Storing the *earliest requested instant* composes — a spring
/// asks for ~16ms, a caret for 500ms, a delayed tooltip for 800ms, and the loop
/// sleeps until the soonest of them.
public enum FrameScheduler {
    nonisolated(unsafe) private static var deadline: Double?

    public static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// Requests a wake no later than `seconds` from now. Earliest wins.
    public static func requestWake(in seconds: Double) {
        let at = now() + max(0, seconds)
        if let existing = deadline, existing <= at { return }
        deadline = at
    }

    /// Seconds the loop may block for: negative means "until input arrives".
    /// Consumes the request, so a repeating animation must ask again each frame.
    public static func timeoutUntilNextWake() -> Double {
        guard let at = deadline else { return -1 }
        deadline = nil
        return max(0, at - now())
    }

    public static var hasPendingWake: Bool { deadline != nil }
}

/// Work deferred until the current frame is on screen.
///
/// Exists for the one thing a synchronous UI thread cannot otherwise express:
/// a visible "before". A click handler about to spend seconds reading and
/// parsing a large file can set its status text, hand the actual work to
/// `after`, and return — the loop paints "Loading…", presents it, *then* runs
/// the work. Doing both inline instead puts the state change and the stall in
/// the same frame, so the status is never drawn and the window simply freezes
/// with stale content, which is indistinguishable from nothing happening.
///
/// Not a thread pool and not a substitute for one: the work still runs on the
/// main thread and still blocks it. What it buys is that the user is told what
/// is blocking, and which file, before it starts.
public enum FrameTasks {
    nonisolated(unsafe) private static var queue: [() -> Void] = []

    public static func after(_ work: @escaping () -> Void) {
        queue.append(work)
        // The loop may be about to block forever in `pumpEvents`; without this
        // the deferred work would wait for unrelated input to wake it.
        FrameScheduler.requestWake(in: 0)
    }

    /// Drained by `LavaApp.run` right after present. Swaps the queue out first,
    /// so work that enqueues more work lands on the *next* frame rather than
    /// extending this stall.
    public static func drain() {
        guard !queue.isEmpty else { return }
        let pending = queue
        queue.removeAll()
        for work in pending { work() }
    }

    public static var hasPending: Bool { !queue.isEmpty }
}

/// Work handed *to* the main thread from another one.
///
/// The reason this has to exist, rather than a worker simply writing `@State`
/// when it finishes: `StateStorage` is `@Observable`, and
/// `withObservationTracking`'s `onChange` fires synchronously on whichever
/// thread performed the write. A background write would therefore run
/// `ViewInvalidation.markBodyDirty` on that thread — and `ViewInvalidation`,
/// `FrameScheduler` and `FrameTasks` are all single-threaded statics the run
/// loop reads every iteration. The race is real, not theoretical.
///
/// So the division is: a worker computes pure `Sendable` values and posts the
/// *application* of them here. `async` is the only member safe to call from
/// another thread, and everything it enqueues runs on the main thread.
///
/// `AgentServer` already had the shape of this — watcher thread, lock, wake
/// the loop, do the work on the main thread — but kept it private and
/// specific to its socket.
public enum MainQueue {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [@Sendable () -> Void] = []
    nonisolated(unsafe) private static var wake: (@Sendable () -> Void)?

    /// Installed once by `LavaApp.run`. Without it posts still arrive, but
    /// cannot unblock a loop parked in `pumpEvents` — they would wait for
    /// unrelated input, which for an idle window can be arbitrarily long.
    public static func install(wake: @escaping @Sendable () -> Void) {
        lock.lock()
        Self.wake = wake
        lock.unlock()
    }

    /// Safe from any thread.
    public static func async(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        pending.append(work)
        let wake = Self.wake
        lock.unlock()
        // Outside the lock: the wake reaches into GLFW, and holding a lock
        // across it would let a worker block on whatever the main thread is
        // doing with the same lock.
        wake?()
    }

    /// Drained by `LavaApp.run` before invalidation is consumed, so a result
    /// a worker delivered while the loop was parked lands in *this* frame
    /// rather than the next one.
    public static func drain() {
        lock.lock()
        let work = pending
        pending.removeAll()
        lock.unlock()
        for item in work { item() }
    }

    /// Work posted before the loop installed its wake, or between drain and
    /// the next `pumpEvents`. The loop must not park while this is true —
    /// that is the switcher opening on an already-queued `SubscribeWindows`
    /// snapshot and sitting on "no windows" until the pointer moves.
    public static var hasPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pending.isEmpty
    }
}
