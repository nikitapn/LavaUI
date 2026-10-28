import Foundation

// `.focusable(onKey:)`: keyboard focus for a container.
//
// Focus used to belong only to the leaves that edit text — `TextField` and
// `EditorView` take it in their own click handlers — so a list, a combo box
// or a grid of cards had no way to hear an arrow key except through the
// window's raw key hook. This puts the same thing on any view: a press
// anywhere inside it focuses it, and from then on keys go to `onKey` until
// something else takes focus.
//
// Resolved through the hit chain outwards, like `.onAnyPress`, so the row
// under the pointer keeps its own click and the list around it still gets
// the focus. A text field inside a focusable view still wins: its click runs
// after the press and focuses the field.

/// What a focusable view does with keys. Replaced on every reconcile, so the
/// handlers it installs with `FocusManager` look it up rather than capture
/// it — the data a list's `onKey` moves through changes while it is focused.
struct FocusableEntry {
    let onKey: (KeyEvent) -> Bool
    let onChar: ((Character) -> Bool)?
}

/// `.focusable` registrations.
enum FocusableRouter {
    nonisolated(unsafe) private static var entries: [NodeID: FocusableEntry] = [:]

    static func register(_ id: NodeID, _ entry: FocusableEntry) {
        entries[id] = entry
    }

    static func unregister(_ id: NodeID) { entries[id] = nil }

    static func unregisterAll(ids: Set<NodeID>) {
        for id in ids { entries[id] = nil }
    }

    static func has(_ id: NodeID) -> Bool { entries[id] != nil }

    /// Gives `id` the keyboard. A no-op when it already has it, so a press
    /// inside a focused list costs nothing.
    static func focus(_ id: NodeID) {
        guard has(id), !FocusManager.isFocused(id) else { return }
        FocusManager.focus(
            id,
            onKey: { entries[id]?.onKey($0) ?? false },
            onChar: { entries[id]?.onChar?($0) ?? false }
        )
    }
}

extension LayoutHost {
    /// The nearest `.focusable` view at this point, walking outwards.
    public func focusTarget(
        x: Float, y: Float, originX: Float = 0, originY: Float = 0
    ) -> NodeID? {
        hitTestScrollChain(x: x, y: y, originX: originX, originY: originY)
            .first { FocusableRouter.has($0) }
    }
}

extension View {
    /// Takes keyboard focus when pressed anywhere inside, and sends keys to
    /// `onKey` — and typed characters to `onChar` — while it holds it. Each
    /// returns whether it used the input; what it does not use falls through
    /// to the window's shortcuts.
    ///
    /// Focus stays until something else takes it — a text field, another
    /// focusable view — or the view leaves the tree.
    ///
    /// `enabled: false` is a view that never takes focus, and a press in it
    /// leaves focus where it was — a results list under a search field, whose
    /// field keeps the keyboard. Prefer it to applying the modifier
    /// conditionally, which remounts the view whenever the condition changes.
    public func focusable(
        enabled: Bool = true,
        onKey: @escaping (KeyEvent) -> Bool,
        onChar: ((Character) -> Bool)? = nil
    ) -> BoxRegistrationView<Self> {
        BoxRegistrationView(
            label: "Focusable",
            register: { box in
                let id = box.id
                guard enabled else {
                    FocusableRouter.unregister(id)
                    FocusTargets.unregister(id)
                    return
                }
                FocusableRouter.register(
                    id, FocusableEntry(onKey: onKey, onChar: onChar)
                )
                FocusTargets.register(id) { FocusableRouter.focus(id) }
            },
            content: self
        )
    }
}

// MARK: - Moving focus from code

/// Everything that can take focus, and how: a text field focuses itself with
/// its own binding and submit, a `.focusable` view through its router. What
/// `.focused($flag)` calls when the flag is set — it knows a node id, not
/// what kind of thing is there.
enum FocusTargets {
    nonisolated(unsafe) private static var targets: [NodeID: () -> Void] = [:]

    static func register(_ id: NodeID, take: @escaping () -> Void) {
        targets[id] = take
    }

    static func unregister(_ id: NodeID) { targets[id] = nil }

    static func unregisterAll(ids: Set<NodeID>) {
        for id in ids { targets[id] = nil }
    }

    static func has(_ id: NodeID) -> Bool { targets[id] != nil }

    static func take(_ id: NodeID) { targets[id]?() }

    /// The first thing in `node`'s subtree that can take focus — `node`
    /// itself when it can. A `.focused` on a padded field lands on the
    /// wrapper, and the field is inside it.
    static func first(in node: any AnyViewNode) -> NodeID? {
        if has(node.id) { return node.id }
        for child in node.childNodes {
            if let found = first(in: child) { return found }
        }
        return nil
    }
}

/// `.focused($flag)` registrations: which flag mirrors which focus target.
///
/// Two directions, and they meet in one rule — **a flag is written back the
/// moment focus changes**, so between changes every flag is true exactly when
/// its target holds focus. A flag that is true while its target does not hold
/// focus can then only be the app asking, and `sync` hands it the keyboard.
/// Without the write-back a click into another field would leave the flag
/// saying true, and the next sync would snatch focus back from where the user
/// just put it.
enum FocusBindings {
    private struct Entry {
        let binding: Binding<Bool>
        let scope: WindowScope
    }

    nonisolated(unsafe) private static var entries: [NodeID: Entry] = [:]

    static func register(_ target: NodeID, _ binding: Binding<Bool>) {
        let scope = WindowScope.currentOrMain
        // First sight of this target: a `false` flag on a field that took
        // focus by itself on mount (`autoFocus`) is a flag that has not been
        // told yet, not a request to let go. A `true` one is a request.
        if entries[target] == nil, !binding.wrappedValue, scope.focused == target {
            binding.wrappedValue = true
        }
        entries[target] = Entry(binding: binding, scope: scope)
    }

    static func unregisterAll(ids: Set<NodeID>) {
        for id in ids { entries[id] = nil }
    }

    /// Focus moved in `scope`: every flag there says where it went.
    static func focusChanged(in scope: WindowScope) {
        for (id, entry) in entries where entry.scope === scope {
            let holds = scope.focused == id
            if entry.binding.wrappedValue != holds { entry.binding.wrappedValue = holds }
        }
    }

    /// Acts on any flag changed since focus last moved: a `true` whose
    /// target lacks focus gets it, a `false` whose target holds it lets go.
    /// Once a loop turn, after input — a key handler that sets a flag has its
    /// answer before the frame is drawn.
    static func sync(in scope: WindowScope) {
        for (id, entry) in entries where entry.scope === scope {
            let wants = entry.binding.wrappedValue
            let holds = scope.focused == id
            if wants, !holds {
                WindowScope.withCurrent(scope) { FocusTargets.take(id) }
                // A target that could not take it must not be asked again
                // every turn.
                if scope.focused != id { entry.binding.wrappedValue = false }
            } else if !wants, holds {
                WindowScope.withCurrent(scope) { FocusManager.clear() }
            }
        }
    }
}

extension View {
    /// Mirrors whether this view — or the first field or `.focusable` view
    /// inside it — holds keyboard focus, both ways.
    ///
    /// Read it to know; set it to `true` to give the view the keyboard, and
    /// to `false` to take it away. It is set back to `false` when focus goes
    /// elsewhere — a click into another field, another `.focused` taking it —
    /// so it never claims focus the view has lost.
    ///
    /// ```swift
    /// TextField(text: $path).focused($session.editingPath)
    /// // Escape: session.editingPath = false — the caret goes, keys go back
    /// ```
    public func focused(_ isFocused: Binding<Bool>) -> BoxRegistrationView<Self> {
        BoxRegistrationView(
            label: "Focused",
            register: { box in
                guard let target = FocusTargets.first(in: box) else { return }
                FocusBindings.register(target, isFocused)
            },
            content: self
        )
    }
}
