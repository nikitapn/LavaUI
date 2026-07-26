import SwiftCrossUI

/// A view that displays hierarchical data as an indented, collapsible outline
/// (similar to a file browser's folder tree).
///
/// `Data.Element` must be `Identifiable` so that each node's expanded/collapsed
/// state can be preserved across view updates. Provide a key path to an
/// optional collection of the same element type to describe the hierarchy —
/// `nil` (or an empty collection) marks a leaf node:
///
/// ```swift
/// struct FileNode: Identifiable {
///     let id = UUID()
///     var name: String
///     var children: [FileNode]?
/// }
///
/// TreeView(rootNodes, children: \.children) { node in
///     Text(node.name)
/// }
/// ```
public struct TreeView<Data: RandomAccessCollection, RowContent: View>: View
where Data.Element: Identifiable {
    public typealias Item = Data.Element

    var data: Data
    var childrenKeyPath: KeyPath<Item, Data?>
    var indent: Int
    var rowContent: (Item) -> RowContent

    /// Creates a tree view.
    ///
    /// - Parameters:
    ///   - data: The root elements of the tree.
    ///   - childrenKeyPath: A key path to each element's children, or `nil`
    ///     for leaf nodes.
    ///   - indent: The amount, in points, that each level of the tree is
    ///     indented relative to its parent.
    ///   - rowContent: A view builder that renders the content of a single
    ///     node. `TreeView` takes care of the expand/collapse arrow and
    ///     indentation, so `rowContent` only needs to render the node itself.
    public init(
        _ data: Data,
        children childrenKeyPath: KeyPath<Item, Data?>,
        indent: Int = 20,
        @ViewBuilder rowContent: @escaping (Item) -> RowContent
    ) {
        self.data = data
        self.childrenKeyPath = childrenKeyPath
        self.indent = indent
        self.rowContent = rowContent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(data) { item in
                TreeViewNode(
                    item: item,
                    depth: 0,
                    childrenKeyPath: childrenKeyPath,
                    indent: indent,
                    rowContent: rowContent
                )
            }
        }
    }
}

/// A single row of a ``TreeView``, plus its (recursively rendered) children.
///
/// Kept separate from `TreeView` so that every node gets its own `@State`
/// (keyed by `item`'s identity via the enclosing `ForEach`) to remember
/// whether it's expanded, independent of its siblings and ancestors.
private struct TreeViewNode<
    Item: Identifiable, Data: RandomAccessCollection, RowContent: View
>: View where Data.Element == Item {
    var item: Item
    var depth: Int
    var childrenKeyPath: KeyPath<Item, Data?>
    var indent: Int
    var rowContent: (Item) -> RowContent

    @State private var isExpanded = true

    var body: some View {
        let children = item[keyPath: childrenKeyPath]
        let hasChildren = !(children?.isEmpty ?? true)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if hasChildren {
                    Text(isExpanded ? "▼" : "▶")
                        .frame(width: 16, alignment: .leading)
                        .onTapGesture {
                            isExpanded.toggle()
                        }
                } else {
                    Text("")
                        .frame(width: 16, alignment: .leading)
                }

                rowContent(item)
            }
            .padding(.leading, depth * indent)

            if isExpanded, let children {
                ForEach(children) { child in
                    AnyView(
                        TreeViewNode(
                            item: child,
                            depth: depth + 1,
                            childrenKeyPath: childrenKeyPath,
                            indent: indent,
                            rowContent: rowContent
                        )
                    )
                }
            }
        }
    }
}
