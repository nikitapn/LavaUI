import XCTest

@testable import LavaUI

/// A canvas that takes the wheel must not take the hover from the box it
/// sits in. It used to: `onWheel` installed an empty `onHover`, which made
/// the canvas a renderer hit-test node — the innermost one under the
/// pointer — so the panel's speaker, a canvas in a box with a hover fill,
/// never lit up once scrolling it changed the volume.
final class CanvasWheelHoverTests: XCTestCase {
    private var notches: [Float] = []

    private func host() -> LayoutHost {
        let host = LayoutHost()
        host.setRoot(
            HStack(padding: 0, alignment: .center) {
                Canvas(
                    label: "speaker", width: .pt(22), height: .pt(22),
                    onWheel: { [weak self] _, dy, _, _ in self?.notches.append(dy) },
                    paint: { _, _ in }
                )
            }
            .padding(4)
            .hoverBackground(Color(r: 1, g: 0, b: 0, a: 0.2))
        )
        _ = host.calculateLayout(width: 30, height: 30)
        return host
    }

    private func canvas(in node: any AnyViewNode) -> LeafNode? {
        if let leaf = node as? LeafNode, leaf.kind == .canvas { return leaf }
        for child in node.childNodes {
            if let found = canvas(in: child) { return found }
        }
        return nil
    }

    func testTheBoxAroundAWheelCanvasIsWhatIsHovered() throws {
        let host = host()
        let leaf = try XCTUnwrap(host.rootNode.flatMap { canvas(in: $0) })
        XCTAssertFalse(leaf.isRendererInteractive, "a wheel alone is no reason to be a hit-test node")
        let hovered = try XCTUnwrap(host.hitTestHover(x: 15, y: 15))
        XCTAssertNotEqual(hovered, leaf.id, "the canvas took the hover from its box")
    }

    func testTheWheelStillReachesTheCanvas() {
        let host = host()
        ScrollRouter.deliver(to: host.hitTestScrollChain(x: 15, y: 15), dx: 0, dy: 1)
        XCTAssertEqual(notches, [1])
    }
}
