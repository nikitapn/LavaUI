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
}
