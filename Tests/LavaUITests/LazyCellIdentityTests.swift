import XCTest

@testable import LavaUI

/// A visible lazy cell lives on through a data change while it shows the
/// same element — so a field typed into in a row keeps its focus and caret —
/// and is rebuilt when a different element takes its index.
final class LazyCellIdentityTests: XCTestCase {
    private struct Item: Identifiable {
        var id: String
        var label: String
    }

    private func list(_ items: [Item]) -> some View {
        VStack(width: .pt(200), height: .pt(200), spacing: 0) {
            ScrollView(.vertical) {
                LazyVStack(items, rowHeight: 28, spacing: 0) { item in
                    Text(item.label)
                }
            }
        }
    }

    private func cells(_ node: (any AnyViewNode)?) -> [LazyCellNode] {
        guard let node else { return [] }
        if let cell = node as? LazyCellNode { return [cell] }
        return node.childNodes.flatMap(cells)
    }

    func testTheSameElementKeepsItsCellAndADifferentOneGetsANewOne() throws {
        let host = LayoutHost()
        host.setRoot(list([Item(id: "a", label: "a"), Item(id: "b", label: "b")]))
        _ = host.calculateLayout(width: 200, height: 200)
        let before = cells(host.rootNode).sorted { $0.index < $1.index }
        XCTAssertEqual(before.count, 2)

        // "a" is edited in place; index 1 now holds "c" instead of "b".
        host.setRoot(list([Item(id: "a", label: "a, renamed"), Item(id: "c", label: "c")]))
        _ = host.calculateLayout(width: 200, height: 200)
        let after = cells(host.rootNode).sorted { $0.index < $1.index }

        XCTAssertTrue(after[0] === before[0], "same id: reconciled, not rebuilt")
        XCTAssertTrue(after[0].item === before[0].item)
        XCTAssertFalse(after[1] === before[1], "different id: a new cell")
        let label = try XCTUnwrap(after[0].item as? LeafNode)
        XCTAssertEqual(label.text, "a, renamed")
    }
}
