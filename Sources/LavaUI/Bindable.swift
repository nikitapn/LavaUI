import Foundation

extension Binding {
    /// Binds one property of a reference-type model.
    ///
    /// Replaces the hand-written pair, which named the property three times and
    /// gave three chances to name a different one by mistake:
    ///
    /// ```swift
    /// Binding(get: { session.rules }, set: { session.rules = $0 })
    /// Binding(session, \.rules)
    /// ```
    ///
    /// The read on the first line is deliberate, and is the reason this is not
    /// purely cosmetic. Observation registers a dependency only on properties
    /// some `body` actually *read* while it was recording. A binding that is
    /// merely constructed and handed to a control that never reads it during
    /// body — `overlay(isPresented:)` keeps a live closure and reads it at emit
    /// time — registers nothing, so a write to the model invalidates nothing.
    /// That is exactly how opening a settings panel from a menu could change
    /// the model and paint no frame until an unrelated hover happened to
    /// repaint. Touching the value here, while this initialiser runs inside
    /// `body`, registers the dependency for whatever the binding is passed to.
    ///
    /// Cheap regardless of `Value`: this is one property read, and for a large
    /// `String` it is a retain, not a copy.
    public init<Root: AnyObject>(
        _ root: Root,
        _ keyPath: ReferenceWritableKeyPath<Root, Value>
    ) {
        _ = root[keyPath: keyPath]
        self.init(
            get: { root[keyPath: keyPath] },
            set: { root[keyPath: keyPath] = $0 }
        )
    }
}

/// Projects bindings out of a reference-type model: `$model.property`.
///
/// `@State` owns view-local storage and cannot be reached from outside the view
/// tree, which is why state shared with a menubar (`LavaApp.run(menu:)`) has to
/// live in an `@Observable` class instead. This is what gives that class the
/// same `$value` ergonomics `@State` has:
///
/// ```swift
/// @Bindable var session: TraceLoomSession
/// …
/// EditorView(text: $session.rules)
/// Toggle("Show log", isOn: $session.showLog)
/// ```
///
/// Read `session.property` directly for a value; use `$session.property` where
/// a `Binding` is wanted. Each projection goes through `Binding(_:_:)` above,
/// so it registers its Observation dependency as it is built.
///
/// Only a wrapper, deliberately: it owns no storage and adopts none, so
/// `StateTransfer` skips it — the model outlives the view struct on its own,
/// which is the entire point of putting it in a class.
@propertyWrapper
@dynamicMemberLookup
public struct Bindable<Value: AnyObject> {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    public var projectedValue: Bindable<Value> { self }

    public subscript<Subject>(
        dynamicMember keyPath: ReferenceWritableKeyPath<Value, Subject>
    ) -> Binding<Subject> {
        Binding(wrappedValue, keyPath)
    }
}
