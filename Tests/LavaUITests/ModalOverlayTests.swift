import XCTest

@testable import LavaUI

/// `OverlayStyle.modal`: while a dialog is up, the window behind it takes no
/// pointer at all — the explorer's dialogs let clicks through to the files,
/// tabs and sidebar under the scrim before this.
final class ModalOverlayTests: XCTestCase {
    private var clicks = 0

    func testAModalOverlaySwallowsEverythingOutsideIt() {
        var presented = true
        let host = LayoutHost()
        host.setRoot(
            Text("Behind", onClick: { [weak self] in self?.clicks += 1 })
                .frame(width: .pt(400), height: .pt(300))
                .overlay(
                    isPresented: Binding(get: { presented }, set: { presented = $0 }),
                    placement: OverlayPlacement { _ in
                        OverlayFrame(x: 150, y: 100, width: 100, height: 50)
                    },
                    style: OverlayStyle(modal: true)
                ) {
                    Text("Dialog")
                }
        )
        _ = host.calculateLayout(width: 400, height: 300)
        // Far from the dialog, on the text behind it.
        host.hitTestClick(x: 20, y: 20)?()
        XCTAssertEqual(clicks, 0, "a click went through to the window behind")
        XCTAssertTrue(presented, "an outside click dismissed the dialog")
        XCTAssertNil(host.hitTestHover(x: 20, y: 20), "the window behind lit up")
        XCTAssertNil(host.hitTestSceneHover(x: 20, y: 20))
        XCTAssertTrue(host.hitTestScrollChain(x: 20, y: 20).isEmpty,
                      "a wheel, drop or drag could still reach the window behind")
    }

    func testOutsidePressDismissesPopupBeforeReachingAnUnderlyingControl() throws {
        var presented = true
        var panelClicks = 0
        let host = LayoutHost()
        host.setRoot(
            Text("Behind", onClick: { self.clicks += 1 })
                .frame(width: .pt(400), height: .pt(300))
                .overlay(
                    isPresented: Binding(get: { presented }, set: { presented = $0 }),
                    placement: OverlayPlacement { _ in
                        OverlayFrame(x: 150, y: 100, width: 100, height: 50)
                    },
                    style: OverlayStyle(padding: 0)
                ) {
                    Text("Popup", onClick: { panelClicks += 1 })
                        .frame(width: .pt(100), height: .pt(50))
                }
        )
        _ = host.calculateLayout(width: 400, height: 300)
        let root = try XCTUnwrap(host.rootNode)
        let popup = try XCTUnwrap(OverlayScan.presented(in: root).first)
        popup.layoutAndPlace(anchorX: 0, anchorY: 0, anchorW: 0, anchorH: 0,
                             viewportW: 400, viewportH: 300)

        let overlays = host.presentedOverlaysForPress()
        XCTAssertNil(host.outsideOverlayPress(in: overlays, x: 160, y: 110, originX: 0, originY: 0))
        try XCTUnwrap(host.hitTestClick(x: 160, y: 110))()
        XCTAssertEqual(panelClicks, 1)
        XCTAssertTrue(presented)

        try XCTUnwrap(host.hitTestClick(x: 20, y: 20))()
        XCTAssertFalse(presented)
        XCTAssertEqual(clicks, 0)

        presented = true
        try XCTUnwrap(host.outsideOverlayPress(in: overlays, x: 20, y: 20, originX: 0, originY: 0))()
        XCTAssertFalse(presented)
        try XCTUnwrap(host.hitTestClick(x: 20, y: 20))()
        XCTAssertEqual(clicks, 1)
    }

    func testPlacedOverlayMountsOnlyTheLazyRowsAtItsScrollPosition() throws {
        let position = ScrollPosition(offset: 6_000)
        let host = LayoutHost()
        var lastClick: Int?
        host.setRoot(
            Text("Behind").overlay(
                isPresented: .constant(true),
                placement: OverlayPlacement { _ in
                    OverlayFrame(x: 50, y: 40, width: 200, height: 200)
                },
                style: OverlayStyle(padding: 0, modal: true)
            ) {
                ScrollView(.vertical, position: position) {
                    LazyVStack(Array(0..<500), rowHeight: 30) { row in
                        Text("Row \(row)", onClick: { lastClick = row })
                            .frame(height: .pt(30))
                    }
                }
            }
        )
        _ = host.calculateLayout(width: 400, height: 300)
        let root = try XCTUnwrap(host.rootNode)
        let overlay = try XCTUnwrap(OverlayScan.presented(in: root).first)
        overlay.layoutAndPlace(anchorX: 0, anchorY: 0, anchorW: 0, anchorH: 0,
                               viewportW: 400, viewportH: 300)
        let panel = try XCTUnwrap(overlay.root)
        let grid = try XCTUnwrap(LazyGrid.nodes(in: panel).first)
        XCTAssertEqual(position.offset, 6_000)
        XCTAssertGreaterThan(grid.mountedCount, 0)
        XCTAssertLessThan(grid.mountedCount, 40)
        host.hitTestClick(x: 65, y: 55)?()
        XCTAssertEqual(lastClick, 200)
    }
}
