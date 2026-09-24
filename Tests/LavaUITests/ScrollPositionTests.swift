import XCTest

@testable import LavaUI

/// `ScrollPosition`: an app putting a list back where it was.
final class ScrollPositionTests: XCTestCase {
    private func list(_ rows: Int, position: ScrollPosition) -> some View {
        VStack(width: .pt(200), height: .pt(280), spacing: 0) {
            ScrollView(.vertical, position: position) {
                LazyVStack(Array(0..<rows), rowHeight: 28, spacing: 0) { row in
                    Text("row \(row)")
                }
            }
        }
    }

    private func scrollNode(_ node: (any AnyViewNode)?) -> ScrollNode? {
        guard let node else { return nil }
        if let scroll = node as? ScrollNode { return scroll }
        for child in node.childNodes {
            if let hit = scrollNode(child) { return hit }
        }
        return nil
    }

    func testAPositionIsAppliedAfterLayoutAndMountsThoseRows() throws {
        let position = ScrollPosition()
        let host = LayoutHost()
        host.setRoot(list(500, position: position))
        _ = host.calculateLayout(width: 200, height: 280)

        position.scroll(to: 28 * 300)
        _ = host.calculateLayout(width: 200, height: 280)

        let scroll = try XCTUnwrap(scrollNode(host.rootNode))
        XCTAssertEqual(scroll.scrollOffset, 28 * 300)
        XCTAssertEqual(position.offset, 28 * 300)
        XCTAssertEqual(scroll.revealRequest?.offset, 28 * 300)
        XCTAssertEqual(scroll.revealRequest?.immediate, true, "a jump, not a glide")
        // The rows for there, on the same pass — not those for the top.
        let texts = host.agentFind(query: "row 300", originY: 0, limit: 1)
        XCTAssertFalse(texts.isEmpty, "row 300 is mounted")
    }

    func testAnOffsetFromALongerListIsClampedToThisOne() throws {
        let position = ScrollPosition()
        let host = LayoutHost()
        host.setRoot(list(20, position: position))
        _ = host.calculateLayout(width: 200, height: 280)
        position.scroll(to: 5_000)
        _ = host.calculateLayout(width: 200, height: 280)
        XCTAssertEqual(position.offset, 20 * 28 - 280)
    }

    func testAnotherPositionPutsTheViewWhereThatOneWas() throws {
        let first = ScrollPosition()
        let second = ScrollPosition(offset: 280)
        let host = LayoutHost()
        host.setRoot(list(100, position: first))
        _ = host.calculateLayout(width: 200, height: 280)
        first.scroll(to: 1_000)
        _ = host.calculateLayout(width: 200, height: 280)

        host.setRoot(list(100, position: second))
        _ = host.calculateLayout(width: 200, height: 280)
        let scroll = try XCTUnwrap(scrollNode(host.rootNode))
        XCTAssertEqual(scroll.scrollOffset, 280)

        host.setRoot(list(100, position: first))
        _ = host.calculateLayout(width: 200, height: 280)
        XCTAssertEqual(scroll.scrollOffset, 1_000, "and back to the first tab's place")
    }

    func testTheRendererReportingAPositionUpdatesIt() throws {
        let position = ScrollPosition()
        let host = LayoutHost()
        host.setRoot(list(100, position: position))
        _ = host.calculateLayout(width: 200, height: 280)
        let scroll = try XCTUnwrap(scrollNode(host.rootNode))
        scroll.contentLength = 2800
        scroll.viewportLength = 280
        scroll.adoptRendererOffset(x: 0, y: 420)
        XCTAssertEqual(position.offset, 420)
    }
}
