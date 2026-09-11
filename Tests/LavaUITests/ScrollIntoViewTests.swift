import XCTest

@testable import LavaUI

/// `.scrollIntoView(when:)` asks the enclosing scroll container for the view,
/// once per change.
final class ScrollIntoViewTests: XCTestCase {
    private func scrollNode(in node: any AnyViewNode) -> ScrollNode? {
        if let scroll = node as? ScrollNode { return scroll }
        for child in node.childNodes {
            if let found = scrollNode(in: child) { return found }
        }
        return nil
    }

    private func strip(selected: Int) -> some View {
        HStack(width: .pt(300), height: .pt(40), alignment: .start, spacing: 0) {
            ScrollView(.horizontal, showsIndicator: false) {
                HStack(height: .pt(40), alignment: .start, spacing: 0) {
                    ForEach(Array(0..<10), id: \.self) { index in
                        Text("tab \(index)")
                            .frame(width: .pt(100), height: .pt(30))
                            .scrollIntoView(when: index == selected)
                    }
                }
            }
        }
    }

    func testAViewPastTheEdgeScrollsTheStripJustFarEnough() throws {
        let host = LayoutHost()
        host.setRoot(strip(selected: 7))
        _ = host.calculateLayout(width: 300, height: 40)
        let scroll = try XCTUnwrap(host.rootNode.flatMap(scrollNode(in:)))
        let request = try XCTUnwrap(scroll.revealRequest, "no reveal was asked for")
        // Tab 7 spans 700…800 in a 300-wide viewport: its right edge at the
        // viewport's right edge.
        XCTAssertEqual(request.offset, 500, accuracy: 0.5)
    }

    func testAViewAlreadyInSightMovesNothing() throws {
        let host = LayoutHost()
        host.setRoot(strip(selected: 1))
        _ = host.calculateLayout(width: 300, height: 40)
        let scroll = try XCTUnwrap(host.rootNode.flatMap(scrollNode(in:)))
        XCTAssertNil(scroll.revealRequest)
    }

    func testItAsksOnceNotOnEveryRebuild() throws {
        let host = LayoutHost()
        host.setRoot(strip(selected: 7))
        _ = host.calculateLayout(width: 300, height: 40)
        let scroll = try XCTUnwrap(host.rootNode.flatMap(scrollNode(in:)))
        let first = try XCTUnwrap(scroll.revealRequest)

        // Same selection again — a rebuild for some unrelated reason.
        host.setRoot(strip(selected: 7))
        _ = host.calculateLayout(width: 300, height: 40)
        XCTAssertEqual(scroll.revealRequest?.serial, first.serial)

        // A different selection is a new ask.
        host.setRoot(strip(selected: 9))
        _ = host.calculateLayout(width: 300, height: 40)
        XCTAssertNotEqual(scroll.revealRequest?.serial, first.serial)
    }
}
