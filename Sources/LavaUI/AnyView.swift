import Foundation

/// A view whose type is decided at run time.
///
/// For the trees Swift cannot spell. A split holding a split holding a pane is
/// a type that contains itself, and an opaque `some View` cannot recurse, so
/// the recursion is erased here and nowhere else.
///
/// It costs what erasure costs everywhere: when the underlying type changes
/// between two rebuilds — a pane turning into a split — the old subtree is
/// unmounted and a new one mounted, and whatever state lived on its nodes (a
/// scroll offset, a text field's caret) starts over. While the type stays the
/// same, reconcile goes straight through to the view's own and is as cheap as
/// it would be without the wrapper.
public struct AnyView: PrimitiveView {
    private let mountImpl: () -> any AnyViewNode
    private let reconcileImpl: (any AnyViewNode) -> any AnyViewNode
    private let linesImpl: (Int) -> [String]
    private let typeName: String

    public init<V: View>(_ view: V) {
        // Erasing an erased view would stack wrappers for nothing.
        if let erased = view as? AnyView {
            self = erased
            return
        }
        mountImpl = { ViewGraph.mount(view) }
        reconcileImpl = { ViewGraph.reconcile($0, with: view) }
        linesImpl = { view.structureLines(indent: $0) }
        typeName = "\(V.self)"
    }

    public var dumpDetail: String { typeName }

    public func structureLines(indent: Int = 0) -> [String] { linesImpl(indent) }

    public func mountPrimitive() -> any AnyViewNode { mountImpl() }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        // `ViewGraph.reconcile` already remounts when the node was built from
        // a different type, which is exactly the case erasure introduces.
        reconcileImpl(node)
    }
}
