import XCTest
@testable import LavaUI

final class ScrollRevealTests: XCTestCase {
    private func scroll(offset: Float = 100) -> ScrollNode {
        let node = ScrollNode(
            axis: .vertical, content: ViewGraph.mount(EmptyView())
        )
        node.scrollOffset = offset
        return node
    }

    func testVisibleTargetDoesNotDisturbScroll() {
        let node = scroll()
        node.reveal(top: 120, bottom: 180, viewport: 200)
        XCTAssertNil(node.revealRequest)
    }

    func testTargetAboveViewportAlignsItsTop() {
        let node = scroll()
        node.reveal(top: 40, bottom: 90, viewport: 200)
        XCTAssertEqual(node.revealRequest?.offset, 40)
    }

    func testTargetBelowViewportAlignsItsBottom() {
        let node = scroll()
        node.reveal(top: 330, bottom: 380, viewport: 200)
        XCTAssertEqual(node.revealRequest?.offset, 180)
    }

    func testEachChangedTargetGetsANewSerial() {
        let node = scroll()
        node.reveal(top: 330, bottom: 380, viewport: 200)
        let first = node.revealRequest?.serial
        node.reveal(top: 350, bottom: 400, viewport: 200)
        XCTAssertNotEqual(node.revealRequest?.serial, first)
    }
}
