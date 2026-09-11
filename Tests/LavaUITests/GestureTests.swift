import XCTest

@testable import LavaUI

/// The pieces a tab dragged between panes is built from: a gesture on an
/// ordinary view, a press a container hears without taking it, a layer over
/// content that stays out of the way, a frame an app can aim at, and a view
/// whose type is only known at run time.
final class GestureTests: XCTestCase {
    private func laidOut<V: View>(_ view: V, width: Float = 300, height: Float = 200) -> LayoutHost {
        let host = LayoutHost()
        host.setRoot(
            VStack(width: .pt(width), height: .pt(height), alignment: .start, spacing: 0) {
                view
            }
        )
        _ = host.calculateLayout(width: width, height: height)
        return host
    }

    // MARK: Drag gesture

    func testAPressBecomesADragOnlyPastTheThreshold() {
        var phases: [DragGesturePhase] = []
        let id = NodeID.generate()
        DragGestureRouter.register(
            id, DragGestureEntry(minimumDistance: 6) { phases.append($0.phase) }
        )
        defer { DragGestureRouter.unregisterAll(ids: [id]) }

        DragGestureRouter.press(source: id, x: 10, y: 10)
        XCTAssertFalse(DragGestureRouter.move(x: 13, y: 12, captured: false))
        XCTAssertTrue(phases.isEmpty, "a wobble is still a click")
        XCTAssertTrue(DragGestureRouter.move(x: 20, y: 10, captured: false))
        XCTAssertTrue(DragGestureRouter.move(x: 30, y: 10, captured: false))
        XCTAssertTrue(DragGestureRouter.release(x: 30, y: 10))
        XCTAssertEqual(phases, [.began, .changed, .ended])
    }

    func testAPressSomethingElseCapturedNeverDrags() {
        var phases: [DragGesturePhase] = []
        let id = NodeID.generate()
        DragGestureRouter.register(
            id, DragGestureEntry(minimumDistance: 6) { phases.append($0.phase) }
        )
        defer { DragGestureRouter.unregisterAll(ids: [id]) }

        DragGestureRouter.press(source: id, x: 0, y: 0)
        // A slider inside the view took the press; its drag is its own.
        XCTAssertFalse(DragGestureRouter.move(x: 40, y: 0, captured: true))
        XCTAssertFalse(DragGestureRouter.move(x: 80, y: 0, captured: false))
        XCTAssertFalse(DragGestureRouter.release(x: 80, y: 0))
        XCTAssertTrue(phases.isEmpty)
    }

    func testTheValueCarriesWhereThePressStarted() {
        var last: DragGestureValue?
        let id = NodeID.generate()
        DragGestureRouter.register(id, DragGestureEntry(minimumDistance: 1) { last = $0 })
        defer { DragGestureRouter.unregisterAll(ids: [id]) }

        DragGestureRouter.press(source: id, x: 5, y: 7)
        _ = DragGestureRouter.move(x: 30, y: 17, captured: false)
        _ = DragGestureRouter.release(x: 30, y: 17)
        XCTAssertEqual(last?.phase, .ended)
        XCTAssertEqual(last?.translationX, 25)
        XCTAssertEqual(last?.translationY, 10)
    }

    // MARK: Found through the chain

    func testGesturesAreFoundThroughTheLabelAndLeaveThePressItsHandler() {
        let host = laidOut(
            HStack(width: .pt(120), height: .pt(30), onClick: {}) {
                Text("tab").frame(width: .pt(60), height: .pt(20))
            }
            .onDragGesture { _ in }
            .onAnyPress { _ in }
        )
        XCTAssertNotNil(host.dragGestureSource(x: 10, y: 10))
        XCTAssertEqual(host.pressObservers(x: 10, y: 10).count, 1)
        XCTAssertNotNil(host.hitTestClick(x: 10, y: 10), "the press still reaches the tab")
        XCTAssertNil(host.dragGestureSource(x: 200, y: 150), "nothing drags outside it")
    }

    func testAnOverlayLayerTakesNoInputFromWhatItCovers() {
        let host = laidOut(
            VStack(width: .pt(200), height: .pt(100), onClick: {}) {
                Text("x").frame(width: .pt(50), height: .pt(20))
            }
            .onDrop { _ in }
            .overlayLayer {
                Canvas(width: .pct(100), height: .pct(100)) { _, _ in }
            }
        )
        XCTAssertNotNil(host.dropTarget(x: 20, y: 20))
        XCTAssertNotNil(host.hitTestClick(x: 20, y: 20))
    }

    // MARK: Frames

    func testOnFrameReportsWhereLayoutPutTheView() {
        var reported: CanvasFrame?
        let host = LayoutHost()
        host.setRoot(
            HStack(width: .pt(300), height: .pt(100), alignment: .start, spacing: 0) {
                Text("a").frame(width: .pt(40), height: .pt(20))
                Text("b").frame(width: .pt(50), height: .pt(20))
                    .onFrame { reported = $0 }
            }
        )
        _ = host.calculateLayout(width: 300, height: 100)
        XCTAssertEqual(reported, CanvasFrame(x: 40, y: 0, w: 50, h: 20))
    }

    // MARK: AnyView

    func testAnyViewRemountsWhenTheTypeUnderItChanges() {
        let host = LayoutHost()
        host.setRoot(
            VStack(width: .pt(200), height: .pt(100), alignment: .start) {
                AnyView(Text("a").frame(width: .pt(20), height: .pt(20)))
            }
        )
        var frames = host.calculateLayout(width: 200, height: 100)
        XCTAssertTrue(frames.contains { abs($0.w - 20) < 0.5 && abs($0.h - 20) < 0.5 })

        host.setRoot(
            VStack(width: .pt(200), height: .pt(100), alignment: .start) {
                AnyView(
                    HStack(width: .pt(80), height: .pt(30)) {
                        Text("b").frame(width: .pt(10), height: .pt(10))
                    }
                )
            }
        )
        frames = host.calculateLayout(width: 200, height: 100)
        XCTAssertTrue(frames.contains { abs($0.w - 80) < 0.5 && abs($0.h - 30) < 0.5 })
        XCTAssertFalse(
            frames.contains { abs($0.w - 20) < 0.5 && abs($0.h - 20) < 0.5 },
            "the old subtree is gone, not laid out beside the new one"
        )
    }

    func testAnyViewOfTheSameTypeKeepsItsNode() {
        let host = LayoutHost()
        host.setRoot(AnyView(VStack(width: .pt(50), height: .pt(50)) { Text("a") }))
        let first = host.rootID
        host.setRoot(AnyView(VStack(width: .pt(50), height: .pt(50)) { Text("b") }))
        XCTAssertEqual(host.rootID, first)
    }
}
