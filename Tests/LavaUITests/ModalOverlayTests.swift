import XCTest

@testable import LavaUI

/// `OverlayStyle.modal`: while a dialog is up, the window behind it takes no
/// pointer at all — the explorer's dialogs let clicks through to the files,
/// tabs and sidebar under the scrim before this.
final class ModalOverlayTests: XCTestCase {
    private var clicks = 0

    private func host(modal: Bool) -> LayoutHost {
        let host = LayoutHost()
        host.setRoot(
            Text("Behind", onClick: { [weak self] in self?.clicks += 1 })
                .frame(width: .pt(400), height: .pt(300))
                .overlay(
                    isPresented: .constant(true),
                    placement: OverlayPlacement { _ in
                        OverlayFrame(x: 150, y: 100, width: 100, height: 50)
                    },
                    style: OverlayStyle(modal: modal)
                ) {
                    Text("Dialog")
                }
        )
        _ = host.calculateLayout(width: 400, height: 300)
        return host
    }

    func testAModalOverlaySwallowsEverythingOutsideIt() {
        let host = host(modal: true)
        // Far from the dialog, on the text behind it.
        host.hitTestClick(x: 20, y: 20)?()
        XCTAssertEqual(clicks, 0, "a click went through to the window behind")
        XCTAssertNil(host.hitTestHover(x: 20, y: 20), "the window behind lit up")
        XCTAssertNil(host.hitTestSceneHover(x: 20, y: 20))
        XCTAssertTrue(host.hitTestScrollChain(x: 20, y: 20).isEmpty,
                      "a wheel, drop or drag could still reach the window behind")
    }

    /// A menu's rule is the opposite, and must stay so: a click outside it may
    /// land on what is there — a menu bar's next title.
    func testAPlainOverlayStillLetsAClickThrough() {
        let host = host(modal: false)
        host.hitTestClick(x: 20, y: 20)?()
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
