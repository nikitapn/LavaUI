import XCTest
@testable import LavaUI

final class TabStripTests: XCTestCase {
    private var editor: Editor!
    private var host: LayoutHost!
    private var selected = 0
    private var closed: [Int] = []

    override func setUpWithError() throws {
        editor = try XCTUnwrap(Editor.openClient(width: 800, height: 200))
        XCTAssertNotNil(FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 14, into: editor))
        host = LayoutHost()
    }

    override func tearDown() {
        PointerCapture.release()
        HoverState.clear()
        host = nil
        editor = nil
    }

    private func layout(count: Int, width: Float = 800) {
        host.setRoot(VStack(width: .pt(width), height: .pt(200), padding: 0, spacing: 0) {
            HStack(height: .pt(36), padding: 0, spacing: 0) {
                Spacer(flexGrow: 0).frame(width: .pt(72))
                TabStrip(showsBaseline: false, onNew: {}) {
                    ForEach(Array(0..<count), id: \.self) { i in
                        TabStripItem(i == 1 ? String(repeating: "long filename ", count: 10) : "Tab \(i)",
                                     selected: i == self.selected, modified: i == 1,
                                     closeID: "close-\(i)", onSelect: { self.selected = i },
                                     onClose: { self.closed.append(i) })
                            .agentId("tab-\(i)")
                    }
                }
                .overlayLayer { EmptyView() }
                .flexGrow(1)
                .flexShrink(1)
            }
        })
        _ = host.calculateLayout(width: width, height: 200)
    }

    func testCloseTargetIncludesItsPaddingAndWaitsForRelease() throws {
        layout(count: 3)
        let frame = try XCTUnwrap(host.agentFrame(sid: "close-1"))
        let x = frame.x + 1
        let y = frame.y + frame.h / 2
        HoverState.set(host.hitTestHover(x: x, y: y))
        try XCTUnwrap(host.hitTestClick(x: x, y: y))()
        XCTAssertTrue(PointerCapture.isActive)
        XCTAssertTrue(closed.isEmpty)
        XCTAssertEqual(selected, 0, "closing an inactive tab must not select it")
        PointerCapture.release()
        XCTAssertEqual(closed, [1])
    }

    func testDraggingOffCloseCancels() throws {
        layout(count: 2)
        let frame = try XCTUnwrap(host.agentFrame(sid: "close-0"))
        try XCTUnwrap(host.hitTestClick(x: frame.x + 2, y: frame.y + 2))()
        HoverState.clear()
        PointerCapture.release()
        XCTAssertTrue(closed.isEmpty)
    }

    func testLongNamesLeaveCloseVisibleAndPlusFollowsTabs() throws {
        layout(count: 2)
        let tab = try XCTUnwrap(host.agentFrame(sid: "tab-1"))
        let close = try XCTUnwrap(host.agentFrame(sid: "close-1"))
        let plus = try XCTUnwrap(host.agentFrame(sid: "new-tab"))
        XCTAssertLessThanOrEqual(tab.w, 260)
        XCTAssertLessThanOrEqual(close.x + close.w, tab.x + tab.w)
        XCTAssertGreaterThanOrEqual(close.y, 0)
        XCTAssertLessThanOrEqual(close.y + close.h, 36)
        XCTAssertEqual(plus.x - (tab.x + tab.w), 4, accuracy: 1)
    }

    func testOverflowRevealsSelectedTabAndKeepsNewButtonVisible() throws {
        selected = 12
        layout(count: 15, width: 400)
        let plus = try XCTUnwrap(host.agentFrame(sid: "new-tab"))
        XCTAssertGreaterThan(plus.x, 0)
        XCTAssertLessThanOrEqual(plus.x + plus.w, 400)
        func scroll(_ node: any AnyViewNode) -> ScrollNode? {
            if let node = node as? ScrollNode { return node }
            return node.childNodes.lazy.compactMap { scroll($0) }.first
        }
        let node = try XCTUnwrap(host.rootNode.flatMap { scroll($0) })
        XCTAssertGreaterThan(try XCTUnwrap(node.revealRequest).offset, 0)
    }
}
