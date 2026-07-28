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
        nonmutating set { set(newValue) }
    }

    public var projectedValue: Binding<Value> { self }
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

/// "Something a body read has changed; render again."
///
/// Deliberately just a flag. The frame loop decides *when* to act on it, which
/// is what keeps the design frame-driven rather than event-driven — a state
/// change never synchronously walks the graph.
///
/// Single-window assumption: one global flag. Per-window hosts would need this
/// scoped to a `LayoutHost`.
public enum ViewInvalidation {
    nonisolated(unsafe) private static var dirty = true

    /// Called from `withObservationTracking`'s `onChange`, i.e. *before* the
    /// new value is written. Setting a flag is safe there; reading state is not.
    public static func markDirty() { dirty = true }

    /// Returns whether a re-render is needed, clearing the flag.
    public static func consume() -> Bool {
        defer { dirty = false }
        return dirty
    }

    public static var isDirty: Bool { dirty }
}
