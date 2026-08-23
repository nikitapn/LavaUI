import XCTest

@testable import LavaUI

/// Dragging a scrollbar: `Scrollbar`, `ScrollNode.scrollbarPress`, and the
/// editor's own bars.
final class ScrollbarDragTests: XCTestCase {
    private var host: LayoutHost!

    override func setUp() {
        super.setUp()
        host = LayoutHost()
    }

    override func tearDown() {
        PointerCapture.release()
        ScrollbarDrag.end()
        host = nil
        super.tearDown()
    }

    private func scrollNode(_ node: any AnyViewNode) -> ScrollNode? {
        if let s = node as? ScrollNode { return s }
        for child in node.childNodes {
            if let s = scrollNode(child) { return s }
        }
        return nil
    }

    /// Twelve rows of 40pt in a 200pt box: 480 of content, 280 to scroll.
    private func mountOverflowing() throws -> ScrollNode {
        host.setRoot(
            VStack(width: .pt(300), height: .pt(200)) {
                ScrollView(.vertical) {
                    VStack {
                        ForEach(Array(0..<12), id: \.self) { n in
                            Text("row \(n)").frame(height: .pt(40))
                        }
                    }
                }
            }
        )
        _ = host.calculateLayout(width: 300, height: 200)
        let scroll = try XCTUnwrap(scrollNode(try XCTUnwrap(host.rootNode)))
        // Emit fills in what the box actually got; the bar is measured from it.
        scroll.viewportLength = 200
        scroll.contentLength = 480
        return scroll
    }

    // MARK: Geometry

    func testNoThumbWhenTheContentFits() {
        XCTAssertNil(
            Scrollbar.metrics(track: 200, content: 150, offset: 0, maxOffset: 0)
        )
    }

    func testThumbIsProportionalAndTravelsTheWholeTrack() throws {
        let top = try XCTUnwrap(
            Scrollbar.metrics(track: 200, content: 400, offset: 0, maxOffset: 200)
        )
        XCTAssertEqual(top.thumb, 100, accuracy: 0.01, "half the content is visible")
        XCTAssertEqual(top.along, 0, accuracy: 0.01)

        let bottom = try XCTUnwrap(
            Scrollbar.metrics(track: 200, content: 400, offset: 200, maxOffset: 200)
        )
        XCTAssertEqual(
            bottom.along + bottom.thumb, 200, accuracy: 0.01,
            "at the end the thumb has to reach the end of the track"
        )
    }

    /// A thumb has a floor, or a long document leaves nothing to aim at.
    func testAVeryLongDocumentStillHasAGrabbableThumb() throws {
        let m = try XCTUnwrap(
            Scrollbar.metrics(track: 200, content: 400_000, offset: 0, maxOffset: 399_800)
        )
        XCTAssertEqual(m.thumb, Scrollbar.minimumThumb)
    }

    /// `offset` and `metrics` are inverses. A drag reads the pointer through
    /// one and the next frame draws through the other; any disagreement is a
    /// thumb that lags the finger holding it.
    func testOffsetAndMetricsRoundTrip() throws {
        for progress in stride(from: Float(0), through: 1, by: 0.1) {
            let maxOffset: Float = 1_000
            let offset = maxOffset * progress
            let m = try XCTUnwrap(
                Scrollbar.metrics(
                    track: 200, content: 1_200, offset: offset, maxOffset: maxOffset
                )
            )
            XCTAssertEqual(
                Scrollbar.offset(forAlong: m.along, travel: m.travel, maxOffset: maxOffset),
                offset, accuracy: 0.01
            )
        }
    }

    // MARK: A container's bar

    /// The bar is painted over the content, so the pointer has to reach it
    /// before the rows underneath — `hitWalk` is otherwise children-first.
    func testAPressOnTheBarBeatsTheRowUnderIt() throws {
        let scroll = try mountOverflowing()
        let onBar = try XCTUnwrap(
            host.hitTestClick(x: 300 - 2, y: 30),
            "nothing took a press on the scrollbar"
        )
        onBar()
        XCTAssertTrue(PointerCapture.isActive, "the press did not start a drag")
        XCTAssertTrue(ScrollbarDrag.isDragging(scroll.id, axis: .vertical))
    }

    func testAPressInsideTheContentIsNotADrag() throws {
        _ = try mountOverflowing()
        // Well clear of the right edge.
        _ = host.hitTestClick(x: 40, y: 30)
        XCTAssertFalse(PointerCapture.isActive)
    }

    /// Dragging asks the renderer to move, rather than assigning the offset:
    /// the transform is renderer-owned, and writing the field here would move
    /// the thumb and leave the content where it was.
    func testDraggingRequestsAnOffsetFromTheRenderer() throws {
        let scroll = try mountOverflowing()
        try XCTUnwrap(host.hitTestClick(x: 300 - 2, y: 30))()

        // Half way down the track. Thumb is 200/480 of 200 ≈ 83pt, so travel
        // is ~117 and the grab offset was taken from the press.
        PointerCapture.move(x: 298, y: 120)
        let request = try XCTUnwrap(scroll.revealRequest, "no scroll was requested")
        XCTAssertGreaterThan(request.offset, 0)
        XCTAssertLessThanOrEqual(request.offset, scroll.maxOffset)
    }

    /// Grabbing the thumb keeps the grab offset, so the content does not jump
    /// to put the thumb's top under the finger.
    func testGrabbingTheThumbDoesNotJump() throws {
        let scroll = try mountOverflowing()
        // The thumb starts at the top; press in its middle.
        try XCTUnwrap(host.hitTestClick(x: 300 - 2, y: 40))()
        XCTAssertNil(
            scroll.revealRequest,
            "pressing the thumb where it already is must not move anything"
        )
    }

    /// A press on bare track jumps there — the usual meaning everywhere else.
    func testPressingTheTrackJumps() throws {
        let scroll = try mountOverflowing()
        try XCTUnwrap(host.hitTestClick(x: 300 - 2, y: 180))()
        let request = try XCTUnwrap(scroll.revealRequest)
        XCTAssertGreaterThan(request.offset, 0)
    }

    func testReleaseEndsTheDrag() throws {
        let scroll = try mountOverflowing()
        try XCTUnwrap(host.hitTestClick(x: 300 - 2, y: 30))()
        XCTAssertTrue(ScrollbarDrag.isDragging(scroll.id, axis: .vertical))
        PointerCapture.release()
        XCTAssertFalse(ScrollbarDrag.isDragging(scroll.id, axis: .vertical))
    }

    /// The horizontal case, which is the one a tab strip is.
    func testAHorizontalBarDragsToo() throws {
        host.setRoot(
            VStack(width: .pt(300), height: .pt(40)) {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(0..<12), id: \.self) { n in
                            Text("tab \(n)").frame(width: .pt(80))
                        }
                    }
                }
            }
        )
        _ = host.calculateLayout(width: 300, height: 40)
        let scroll = try XCTUnwrap(scrollNode(try XCTUnwrap(host.rootNode)))
        scroll.viewportLength = 300
        scroll.contentLength = 960

        let onBar = try XCTUnwrap(
            host.hitTestClick(x: 150, y: 40 - 2),
            "nothing took a press on the horizontal bar"
        )
        onBar()
        XCTAssertTrue(ScrollbarDrag.isDragging(scroll.id, axis: .horizontal))
        PointerCapture.move(x: 250, y: 38)
        let request = try XCTUnwrap(scroll.revealRequest)
        XCTAssertGreaterThan(request.offset, 0)
    }

    // MARK: What reaches the renderer

    /// The renderer takes a scroll target for *both* components of the
    /// command. Filling only `y` told it a horizontal container should go to
    /// zero on the axis it actually scrolls, so every programmatic scroll of
    /// one was a snap back to the start — reveal included, silently, for as
    /// long as horizontal containers have existed.
    private func scrollTargets(axis: ScrollAxis, offset: Float) throws -> (x: Float, y: Float) {
        let editor = try XCTUnwrap(
            Editor.openClient(width: 300, height: 200),
            "client engine failed to open"
        )
        XCTAssertNotNil(
            FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editor),
            "default face failed to load"
        )
        let host = LayoutHost()
        host.setRoot(
            VStack(width: .pt(300), height: .pt(200)) {
                ScrollView(axis) {
                    VStack {
                        ForEach(Array(0..<12), id: \.self) { n in
                            Text("row \(n)").frame(width: .pt(200), height: .pt(40))
                        }
                    }
                }
            }
        )
        _ = host.calculateLayout(width: 300, height: 200)
        let root = try XCTUnwrap(host.rootNode)
        let scroll = try XCTUnwrap(scrollNode(root))
        scroll.viewportLength = axis == .vertical ? 200 : 300
        scroll.contentLength = 900
        scroll.requestOffset(offset)

        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: 300, viewportH: 200)
        for index in 0..<list.commandCount {
            guard let cmd = list.emitted(at: index),
                  cmd.kind == .nodeScrollTo else { continue }
            return (cmd.x, cmd.y)
        }
        XCTFail("no scroll-to command was emitted")
        return (0, 0)
    }

    func testAVerticalScrollTargetsY() throws {
        let target = try scrollTargets(axis: .vertical, offset: 120)
        XCTAssertEqual(target.y, 120, accuracy: 0.01)
        XCTAssertEqual(target.x, 0, accuracy: 0.01)
    }

    func testAHorizontalScrollTargetsX() throws {
        let target = try scrollTargets(axis: .horizontal, offset: 120)
        XCTAssertEqual(target.x, 120, accuracy: 0.01, "a horizontal scroll went nowhere")
        XCTAssertEqual(target.y, 0, accuracy: 0.01)
    }
}

