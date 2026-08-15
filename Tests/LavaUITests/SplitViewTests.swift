import XCTest

@testable import LavaUI

final class SplitViewTests: XCTestCase {
    /// Frames of the two pane wrappers, in tree order.
    private func panes(_ frames: [LayoutFrame]) -> [LayoutFrame] {
        frames.filter { $0.label == "SplitTop" || $0.label == "SplitBottom" }
    }

    func testPanesDivideTheSpanLeftByTheDivider() throws {
        let host = LayoutHost()
        host.setRoot(
            VSplitView(initialFraction: 0.25, style: SplitStyle(thickness: 10)) {
                EmptyView()
            } bottom: {
                EmptyView()
            }
        )

        let frames = panes(host.calculateLayout(width: 200, height: 410))
        XCTAssertEqual(frames.count, 2)
        // 410 minus the 10pt divider, split one quarter / three quarters.
        XCTAssertEqual(frames[0].h, 100, accuracy: 0.01)
        XCTAssertEqual(frames[1].h, 300, accuracy: 0.01)
        XCTAssertEqual(frames[1].y - frames[0].h, 10, accuracy: 0.01)
    }

    func testFractionSurvivesAResize() throws {
        let host = LayoutHost()
        host.setRoot(
            VSplitView(initialFraction: 0.4, style: SplitStyle(thickness: 10)) {
                EmptyView()
            } bottom: {
                EmptyView()
            }
        )

        _ = host.calculateLayout(width: 200, height: 210)
        let frames = panes(host.calculateLayout(width: 200, height: 410))
        XCTAssertEqual(frames[0].h, 160, accuracy: 0.01)
        XCTAssertEqual(frames[1].h, 240, accuracy: 0.01)
    }

    func testDraggingTheDividerMovesTheSplitAndCommitsOnRelease() throws {
        var stored: Float = 0.5
        let binding = Binding(get: { stored }, set: { stored = $0 })
        let host = LayoutHost()
        host.setRoot(
            VSplitView(
                fraction: binding, minTop: 20, minBottom: 20,
                style: SplitStyle(thickness: 10)
            ) {
                EmptyView()
            } bottom: {
                EmptyView()
            }
        )

        _ = host.calculateLayout(width: 200, height: 410)
        // The divider sits between the panes: 200pt down, 10pt tall.
        let press = try XCTUnwrap(host.hitTestClick(x: 100, y: 205))
        press()
        XCTAssertTrue(PointerCapture.isActive)

        // 80pt down the window is 80/400 of the pane span.
        PointerCapture.move(x: 100, y: 285)
        var frames = panes(host.calculateLayout(width: 200, height: 410))
        XCTAssertEqual(frames[0].h, 280, accuracy: 0.01)
        XCTAssertEqual(frames[1].h, 120, accuracy: 0.01)
        // Nothing is written to app state until the pointer comes up.
        XCTAssertEqual(stored, 0.5, accuracy: 0.001)

        PointerCapture.release()
        XCTAssertEqual(stored, 0.7, accuracy: 0.001)

        // And the committed value is what the next body lays out with.
        frames = panes(host.calculateLayout(width: 200, height: 410))
        XCTAssertEqual(frames[0].h, 280, accuracy: 0.01)
    }

    func testDragStopsAtTheMinimums() throws {
        var stored: Float = 0.5
        let binding = Binding(get: { stored }, set: { stored = $0 })
        let host = LayoutHost()
        host.setRoot(
            VSplitView(
                fraction: binding, minTop: 50, minBottom: 80,
                style: SplitStyle(thickness: 10)
            ) {
                EmptyView()
            } bottom: {
                EmptyView()
            }
        )

        _ = host.calculateLayout(width: 200, height: 410)
        let press = try XCTUnwrap(host.hitTestClick(x: 100, y: 205))
        press()

        // Far past the bottom edge: the bottom pane keeps its 80pt floor.
        PointerCapture.move(x: 100, y: 4000)
        var frames = panes(host.calculateLayout(width: 200, height: 410))
        XCTAssertEqual(frames[0].h, 320, accuracy: 0.01)
        XCTAssertEqual(frames[1].h, 80, accuracy: 0.01)

        // And past the top edge, the top pane keeps its 50pt floor.
        PointerCapture.move(x: 100, y: -4000)
        frames = panes(host.calculateLayout(width: 200, height: 410))
        XCTAssertEqual(frames[0].h, 50, accuracy: 0.01)
        XCTAssertEqual(frames[1].h, 350, accuracy: 0.01)
        PointerCapture.release()
    }

    private func columns(_ frames: [LayoutFrame]) -> [LayoutFrame] {
        frames.filter { $0.label == "SplitLeading" || $0.label == "SplitTrailing" }
    }

    func testHorizontalPanesDivideTheWidth() throws {
        let host = LayoutHost()
        host.setRoot(
            HSplitView(initialFraction: 0.3, style: SplitStyle(thickness: 10)) {
                EmptyView()
            } trailing: {
                EmptyView()
            }
        )

        let frames = columns(host.calculateLayout(width: 410, height: 200))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].w, 120, accuracy: 0.01)
        XCTAssertEqual(frames[1].w, 280, accuracy: 0.01)
        // Full height each, and the divider between them.
        XCTAssertEqual(frames[0].h, 200, accuracy: 0.01)
        XCTAssertEqual(frames[1].x - frames[0].w, 10, accuracy: 0.01)
    }

    func testDraggingAHorizontalDividerFollowsX() throws {
        var stored: Float = 0.5
        let binding = Binding(get: { stored }, set: { stored = $0 })
        let host = LayoutHost()
        host.setRoot(
            HSplitView(
                fraction: binding, minLeading: 20, minTrailing: 20,
                style: SplitStyle(thickness: 10)
            ) {
                EmptyView()
            } trailing: {
                EmptyView()
            }
        )

        _ = host.calculateLayout(width: 410, height: 200)
        // The divider sits at x = 200, 10pt wide.
        let press = try XCTUnwrap(host.hitTestClick(x: 205, y: 100))
        press()
        PointerCapture.move(x: 125, y: 100)
        let frames = columns(host.calculateLayout(width: 410, height: 200))
        XCTAssertEqual(frames[0].w, 120, accuracy: 0.01)
        XCTAssertEqual(frames[1].w, 280, accuracy: 0.01)
        PointerCapture.release()
        XCTAssertEqual(stored, 0.3, accuracy: 0.001)
    }

    /// The one built-in user of `.cursor(_:)`, and the reason the divider is a
    /// hit-testable node at all.
    func testDividersCarryAResizeCursor() throws {
        let host = LayoutHost()
        host.setRoot(
            VSplitView(initialFraction: 0.5) { EmptyView() } bottom: { EmptyView() }
        )
        _ = host.calculateLayout(width: 200, height: 400)
        var split = try XCTUnwrap(host.rootNode as? SplitNode)
        XCTAssertEqual(split.handle.cursor, .resizeUpDown)

        host.setRoot(
            HSplitView(initialFraction: 0.5) { EmptyView() } trailing: { EmptyView() }
        )
        _ = host.calculateLayout(width: 400, height: 200)
        split = try XCTUnwrap(host.rootNode as? SplitNode)
        XCTAssertEqual(split.handle.cursor, .resizeLeftRight)
    }

    func testPaneContentIsReconciledInPlace() throws {
        let host = LayoutHost()
        func tree(_ label: String) -> some View {
            VSplitView(initialFraction: 0.5) {
                Text(label)
            } bottom: {
                EmptyView()
            }
        }
        host.setRoot(tree("one"))
        _ = host.calculateLayout(width: 200, height: 400)
        host.setRoot(tree("two"))
        _ = host.calculateLayout(width: 200, height: 400)

        XCTAssertEqual(host.mountCount, 1)
        XCTAssertEqual(host.reconcileCount, 1)
    }
}
