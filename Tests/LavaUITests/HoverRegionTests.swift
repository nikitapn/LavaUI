import XCTest

@testable import LavaUI

/// `View.onHover`: a region is the view and everything inside it, resolved
/// from the one innermost node the renderer names.
final class HoverRegionTests: XCTestCase {
    private final class Log {
        var events: [String] = []
    }

    private func node(labelled label: String, in root: any AnyViewNode) -> (any AnyViewNode)? {
        if root.label.hasPrefix(label) { return root }
        for child in root.childNodes {
            if let found = node(labelled: label, in: child) { return found }
        }
        return nil
    }

    /// A bar with two buttons in it, and a label outside it.
    private func mount(_ log: Log) -> LayoutHost {
        let host = LayoutHost()
        host.setRoot(
            VStack {
                HStack {
                    Text("play", onClick: {})
                    Text("next", onClick: {})
                }
                .onHover { log.events.append($0 ? "bar in" : "bar out") }
                Text("outside", onClick: {})
            }
        )
        _ = host.calculateLayout(width: 300, height: 200)
        return host
    }

    override func tearDown() {
        // The set is process-wide, like the pointer; leave it empty for the
        // next test.
        HoverRegions.update(hovered: nil, in: nil)
        super.tearDown()
    }

    func testEnteringAChildEntersTheRegion() throws {
        let log = Log()
        let host = mount(log)
        let root = try XCTUnwrap(host.rootNode)
        let play = try XCTUnwrap(node(labelled: "Text \"play", in: root))

        HoverRegions.update(hovered: play.id, in: root)
        XCTAssertEqual(log.events, ["bar in"])
    }

    func testMovingBetweenChildrenIsNotLeaving() throws {
        let log = Log()
        let host = mount(log)
        let root = try XCTUnwrap(host.rootNode)
        let play = try XCTUnwrap(node(labelled: "Text \"play", in: root))
        let next = try XCTUnwrap(node(labelled: "Text \"next", in: root))

        HoverRegions.update(hovered: play.id, in: root)
        HoverRegions.update(hovered: next.id, in: root)
        XCTAssertEqual(log.events, ["bar in"])
    }

    func testTheRegionsOwnBackgroundCounts() throws {
        let log = Log()
        let host = mount(log)
        let root = try XCTUnwrap(host.rootNode)
        let bar = try XCTUnwrap(node(labelled: "HStack", in: root))

        HoverRegions.update(hovered: bar.id, in: root)
        XCTAssertEqual(log.events, ["bar in"])
    }

    func testLeavingForANodeOutsideLeaves() throws {
        let log = Log()
        let host = mount(log)
        let root = try XCTUnwrap(host.rootNode)
        let play = try XCTUnwrap(node(labelled: "Text \"play", in: root))
        let outside = try XCTUnwrap(node(labelled: "Text \"outside", in: root))

        HoverRegions.update(hovered: play.id, in: root)
        HoverRegions.update(hovered: outside.id, in: root)
        HoverRegions.update(hovered: nil, in: root)
        XCTAssertEqual(log.events, ["bar in", "bar out"])
    }

    /// The pointer leaving the window, which the window reports as nothing
    /// hovered at all.
    func testNothingHoveredLeavesEverything() throws {
        let log = Log()
        let host = mount(log)
        let root = try XCTUnwrap(host.rootNode)
        let play = try XCTUnwrap(node(labelled: "Text \"play", in: root))

        HoverRegions.update(hovered: play.id, in: root)
        HoverRegions.update(hovered: nil, in: root)
        XCTAssertEqual(log.events, ["bar in", "bar out"])
    }

    func testNestedRegionsEnterOuterFirstAndLeaveInnerFirst() throws {
        let log = Log()
        let host = LayoutHost()
        host.setRoot(
            VStack {
                HStack {
                    Text("inner", onClick: {})
                        .onHover { log.events.append($0 ? "inner in" : "inner out") }
                }
                .onHover { log.events.append($0 ? "outer in" : "outer out") }
            }
        )
        _ = host.calculateLayout(width: 300, height: 200)
        let root = try XCTUnwrap(host.rootNode)
        let inner = try XCTUnwrap(node(labelled: "Text \"inner", in: root))

        HoverRegions.update(hovered: inner.id, in: root)
        HoverRegions.update(hovered: nil, in: root)
        XCTAssertEqual(log.events, ["outer in", "inner in", "inner out", "outer out"])
    }

    /// Over its bare background, a region is the only thing the renderer can
    /// name — so it has to be something the renderer hit-tests.
    func testARegionIsHitTestable() throws {
        let host = LayoutHost()
        host.setRoot(VStack { HStack { Text("plain") }.onHover { _ in } })
        _ = host.calculateLayout(width: 300, height: 200)
        let root = try XCTUnwrap(host.rootNode)
        let bar = try XCTUnwrap(node(labelled: "HStack", in: root) as? StackNode)
        XCTAssertTrue(bar.isRendererInteractive)
    }

    /// The closure from the latest body pass is the one called, not the one
    /// from the first: a style that compared equal would have kept that.
    func testTheLatestClosureIsTheOneCalled() throws {
        let log = Log()
        let host = LayoutHost()
        host.setRoot(VStack { HStack { Text("a") }.onHover { _ in log.events.append("first") } })
        _ = host.calculateLayout(width: 300, height: 200)
        host.setRoot(VStack { HStack { Text("a") }.onHover { _ in log.events.append("second") } })
        _ = host.calculateLayout(width: 300, height: 200)
        let root = try XCTUnwrap(host.rootNode)
        let bar = try XCTUnwrap(node(labelled: "HStack", in: root))

        HoverRegions.update(hovered: bar.id, in: root)
        XCTAssertEqual(log.events, ["second"])
    }
}
