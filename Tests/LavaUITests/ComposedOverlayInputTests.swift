import XCTest

@testable import LavaUI

final class ComposedOverlayInputTests: XCTestCase {
    private var notches: [Float] = []
    private var clicks = 0

    private func view(showsPanel: Bool) -> some View {
        Canvas(
            width: .pt(400), height: .pt(300),
            onWheel: { [weak self] _, dy, _, _ in self?.notches.append(dy) },
            paint: { _, _ in }
        )
        .overlay(alignment: .topTrailing, inset: 10) {
            if showsPanel {
                Text("Find", onClick: { [weak self] in self?.clicks += 1 })
                    .frame(width: .pt(100), height: .pt(40))
            }
        }
    }

    func testWheelReachesBaseOutsidePanelBeforeAndAfterPresentation() {
        let host = LayoutHost()
        for showsPanel in [false, true, false] {
            host.setRoot(view(showsPanel: showsPanel))
            _ = host.calculateLayout(width: 400, height: 300)
            XCTAssertTrue(ScrollRouter.deliver(
                to: host.hitTestScrollChain(x: 100, y: 200), dx: 0, dy: 1
            ))
        }
        XCTAssertEqual(notches, [1, 1, 1])
    }

    func testPanelKeepsItsInputWithoutScrollingBase() throws {
        let host = LayoutHost()
        host.setRoot(view(showsPanel: true))
        _ = host.calculateLayout(width: 400, height: 300)
        XCTAssertFalse(ScrollRouter.deliver(
            to: host.hitTestScrollChain(x: 340, y: 30), dx: 0, dy: 1
        ))
        XCTAssertTrue(notches.isEmpty)
        let click = try XCTUnwrap(host.hitTestClick(x: 340, y: 30))
        click()
        XCTAssertEqual(clicks, 1)
    }

    /// A styled panel's padding is part of the panel: a press there must not
    /// start a gesture on the canvas it floats over, nor its cursor show.
    func testStyledPanelSwallowsPressAndHoverInItsPadding() throws {
        var began = 0
        var moves = 0
        let host = LayoutHost()
        host.setRoot(
            Canvas(
                width: .pt(400), height: .pt(300),
                onGesture: { if $0.phase == .began { began += 1 } },
                onPointerMove: { _, _ in moves += 1; return nil },
                paint: { _, _ in }
            )
            .overlay(alignment: .topTrailing, inset: 10,
                     style: OverlayStyle(cornerRadius: 8, padding: 20)) {
                Text("Find").frame(width: .pt(60), height: .pt(20))
            }
        )
        _ = host.calculateLayout(width: 400, height: 300)
        // Panel spans x 290…390, y 10…70; the text sits at 310…370, 30…50.
        let press = try XCTUnwrap(host.hitTestClick(x: 300, y: 15))
        press()
        XCTAssertEqual(began, 0)
        XCTAssertNotNil(host.hitTestHover(x: 300, y: 15))
        XCTAssertEqual(moves, 0)
        // Outside the panel the canvas still has both.
        try XCTUnwrap(host.hitTestClick(x: 100, y: 200))()
        XCTAssertEqual(began, 1)
        _ = host.hitTestHover(x: 100, y: 200)
        XCTAssertEqual(moves, 1)
    }

    /// An unstyled badge is only its content: its surroundings stay the base's.
    func testUnstyledOverlayGapsStillReachTheBase() throws {
        var began = 0
        let host = LayoutHost()
        host.setRoot(
            Canvas(
                width: .pt(400), height: .pt(300),
                onGesture: { if $0.phase == .began { began += 1 } },
                paint: { _, _ in }
            )
            .overlay(alignment: .topTrailing, inset: 10) {
                Text("Find").frame(width: .pt(60), height: .pt(20))
            }
        )
        _ = host.calculateLayout(width: 400, height: 300)
        try XCTUnwrap(host.hitTestClick(x: 320, y: 5))()
        XCTAssertEqual(began, 1)
    }
}
