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
    func testFollowingEndTracksGrowthAndViewportResize() {
        let node = ScrollNode(axis: .vertical, content: Text("output").mountPrimitive())
        node.setFollowsEnd(true)
        node.updateScrollMetrics(viewport: 200, content: 600)
        XCTAssertEqual(node.scrollOffset, 400)
        XCTAssertEqual(node.revealRequest?.offset, 400)
        XCTAssertEqual(node.revealRequest?.immediate, true)
        node.updateScrollMetrics(viewport: 200, content: 800)
        XCTAssertEqual(node.scrollOffset, 600)
        node.updateScrollMetrics(viewport: 300, content: 800)
        XCTAssertEqual(node.scrollOffset, 500)
        node.updateScrollMetrics(viewport: 300, content: 100)
        XCTAssertEqual(node.scrollOffset, 0)
        XCTAssertTrue(node.isFollowingEnd)
    }

    func testFollowingPausesOnScrollUpAndResumesAtTheEnd() {
        let node = ScrollNode(axis: .vertical, content: Text("output").mountPrimitive())
        node.setFollowsEnd(true)
        node.updateScrollMetrics(viewport: 200, content: 600)
        node.adoptRendererOffset(x: 0, y: 200)
        XCTAssertFalse(node.isFollowingEnd)
        node.setFollowsEnd(true) // A streamed body rebuild must not resume it.
        node.updateScrollMetrics(viewport: 200, content: 800)
        XCTAssertEqual(node.scrollOffset, 200)
        node.adoptRendererOffset(x: 0, y: 600)
        XCTAssertTrue(node.isFollowingEnd)
        node.updateScrollMetrics(viewport: 200, content: 1000)
        XCTAssertEqual(node.scrollOffset, 800)
    }

    func testScrollbarRequestPausesFollowingBeforeRendererFeedback() {
        let node = ScrollNode(axis: .vertical, content: Text("output").mountPrimitive())
        node.setFollowsEnd(true)
        node.updateScrollMetrics(viewport: 200, content: 600)
        node.requestOffset(100, immediate: true)
        XCTAssertFalse(node.isFollowingEnd)
        let serial = node.revealRequest?.serial
        node.updateScrollMetrics(viewport: 200, content: 800)
        XCTAssertEqual(node.revealRequest?.serial, serial)
        XCTAssertEqual(node.revealRequest?.offset, 100)
    }

    func testOrdinaryScrollViewsDoNotFollowGrowingContent() {
        let node = ScrollNode(axis: .vertical, content: Text("output").mountPrimitive())
        node.updateScrollMetrics(viewport: 200, content: 600)
        node.updateScrollMetrics(viewport: 200, content: 800)
        XCTAssertEqual(node.scrollOffset, 0)
        XCTAssertNil(node.revealRequest)
    }

    func testFollowingEndMountsLazyRowsAtTheBottomAfterReconcile() throws {
        func output(_ rows: Int) -> some View {
            VStack(width: .pt(200), height: .pt(280), spacing: 0) {
                ScrollView(followsEnd: true) {
                    LazyVStack(Array(0..<rows), rowHeight: 28, spacing: 0) { row in
                        Text("row \(row)")
                    }
                }
            }
        }
        let host = LayoutHost()
        host.setRoot(output(100))
        _ = host.calculateLayout(width: 200, height: 280)
        let scroll = try XCTUnwrap(scrollNode(host.rootNode))
        XCTAssertEqual(scroll.scrollOffset, 2520)
        host.setRoot(output(120))
        _ = host.calculateLayout(width: 200, height: 280)
        XCTAssertEqual(scroll.scrollOffset, 3080)
        XCTAssertFalse(host.agentFind(query: "row 119", originY: 0, limit: 1).isEmpty)
    }

}
