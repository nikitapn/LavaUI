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
/// Single-window assumption, like `FocusManager`. Per-window hosts would need
/// this scoped to a `LayoutHost`.
public enum ViewInvalidation {
    nonisolated(unsafe) private static var pending: InvalidationLevel = .body

    /// True until the first frame consumes it. Nothing has named a specific
    /// dirty node yet, and there is no root to reconcile a targeted change
    /// into, so the first `.body` pass must build the whole tree regardless
    /// — the same reason `pending` itself defaults to `.body`.
    nonisolated(unsafe) private static var coarseBodyDirty = true

    /// Composite nodes whose own body needs to run again, keyed by identity
    /// so the same node marking itself dirty twice in one frame is one
    /// entry, not two.
    nonisolated(unsafe) private static var dirtyBodyNodes:
        [ObjectIdentifier: any BodyRecomputable] = [:]

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
    public static func markBodyDirty(_ node: some BodyRecomputable) {
        dirtyBodyNodes[ObjectIdentifier(node)] = node
        raise(.body)
    }

    private static func raiseCoarse() {
        coarseBodyDirty = true
        raise(.body)
    }

    private static func raise(_ level: InvalidationLevel) {
        if level > pending { pending = level }
    }

    /// Returns the work required, clearing the flag.
    public static func consume() -> InvalidationLevel {
        defer { pending = .none }
        return pending
    }

    /// Drains the set of nodes to recompute individually. `nil` means the
    /// caller should rebuild the whole tree from the root instead — either
    /// nothing has been targeted yet (first frame) or `.body` was raised by
    /// something that could not name the node responsible.
    public static func consumeDirtyBodyNodes() -> [any BodyRecomputable]? {
        defer {
            coarseBodyDirty = false
            dirtyBodyNodes.removeAll()
        }
        guard !coarseBodyDirty else { return nil }
        return Array(dirtyBodyNodes.values)
    }

    public static var isDirty: Bool { pending != .none }
    public static var level: InvalidationLevel { pending }
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
