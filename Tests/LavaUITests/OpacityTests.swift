import CxxCanvas
import XCTest

@testable import LavaUI

final class OpacityTests: XCTestCase {
    private func canvas() -> some View {
        Canvas(width: .pt(80), height: .pt(40)) { list, frame in
            list.rect(x: frame.x, y: frame.y, w: frame.w, h: frame.h,
                      color: Color(r: 1, g: 0, b: 0, a: 0.8))
        }
    }

    private func emit(_ view: some View) throws -> [UInt32] {
        let editor = try XCTUnwrap(Editor.openClient(width: 300, height: 200))
        let host = LayoutHost()
        host.setRoot(view)
        _ = host.calculateLayout(width: 300, height: 200)
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(try XCTUnwrap(host.rootNode), viewportW: 300, viewportH: 200)
        return (0..<list.commandCount).compactMap {
            guard let cmd = list.emitted(at: $0), cmd.kind == .rect else { return nil }
            return cmd.color >> 24
        }
    }

    func testNestedOpacityMultipliesExistingAlphaAndRestoresForSibling() throws {
        let alphas = try emit(HStack(spacing: 0) {
            canvas().opacity(0.5).opacity(0.5)
            canvas()
        })
        XCTAssertEqual(alphas, [51, 204])
    }

    func testOpacityClampsToUnitInterval() throws {
        // Clamped to 0, which is not drawn at all.
        XCTAssertEqual(try emit(canvas().opacity(-1)), [])
        XCTAssertEqual(try emit(canvas().opacity(2)), [204])
    }

    func testChangingOpacityPreservesContentAndLayout() throws {
        let host = LayoutHost()
        host.setRoot(canvas().opacity(0.2))
        let before = host.calculateLayout(width: 300, height: 200)
        let root = try XCTUnwrap(host.rootNode as? OpacityNode)
        let contentID = root.contentNode.id
        host.setRoot(canvas().opacity(0.8))
        let after = host.calculateLayout(width: 300, height: 200)
        let updated = try XCTUnwrap(host.rootNode as? OpacityNode)
        XCTAssertEqual(updated.contentNode.id, contentID)
        XCTAssertEqual(updated.opacity, 0.8)
        XCTAssertEqual(before.map(\.w), after.map(\.w))
        XCTAssertEqual(before.map(\.h), after.map(\.h))
    }

    func testZeroOpacityKeepsClickTarget() throws {
        var clicks = 0
        let host = LayoutHost()
        host.setRoot(Text("click", onClick: { clicks += 1 })
            .frame(width: .pt(80), height: .pt(40)).opacity(0))
        _ = host.calculateLayout(width: 300, height: 200)
        let action = try XCTUnwrap(host.hitTestClick(x: 20, y: 20))
        action()
        XCTAssertEqual(clicks, 1)
    }

    func testGradientAndHoverColorsFadeWithoutChangingSceneFlags() throws {
        let editor = try XCTUnwrap(Editor.openClient(width: 300, height: 200))
        let host = LayoutHost()
        host.setRoot(Canvas(width: .pt(80), height: .pt(40)) { list, frame in
            list.linearGradientRect(x: frame.x, y: frame.y, w: frame.w, h: frame.h,
                                    from: .white, to: Color(r: 1, g: 0, b: 0, a: 0.5))
        }.hoverBackground(.white).opacity(0.5))
        _ = host.calculateLayout(width: 300, height: 200)
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(try XCTUnwrap(host.rootNode), viewportW: 300, viewportH: 200)
        let storage = editor.drawListStorage()
        XCTAssertEqual(storage.gradients[0].color0 >> 24, 128)
        XCTAssertEqual(storage.gradients[0].color1 >> 24, 64)
        let commands = (0..<list.commandCount).compactMap { list.emitted(at: $0) }
        let end = try XCTUnwrap(commands.first { $0.kind == .endNode && $0.color != 0 })
        // Hover washes are capped at 40% before the view's 50% fade.
        XCTAssertEqual(end.color >> 24, 51)
        let begin = try XCTUnwrap(commands.first { $0.kind == .beginNode })
        XCTAssertEqual(begin.color & SceneNodeFlags.hitTest.rawValue, SceneNodeFlags.hitTest.rawValue)
    }

    func testNaNOpacityIsNoFade() throws {
        XCTAssertEqual(try emit(canvas().opacity(.nan)), [204])
        var view = canvas().opacity(0.5)
        view.opacity = .nan
        XCTAssertEqual(view.opacity, 1)
    }

    /// A backdrop's alpha is its adaptation, so fading it would leave the
    /// frost on screen at full strength; a zero opacity draws nothing.
    func testZeroOpacityDrawsNoBackdropAndPartialKeepsAdaptation() throws {
        func kinds(_ opacity: Float) throws -> [(DrawKind?, UInt32)] {
            let editor = try XCTUnwrap(Editor.openClient(width: 300, height: 200))
            let host = LayoutHost()
            host.setRoot(canvas().backdropBlur(radius: 10).opacity(opacity))
            _ = host.calculateLayout(width: 300, height: 200)
            let list = DrawList(editor: editor)
            list.clear()
            list.emitTree(try XCTUnwrap(host.rootNode), viewportW: 300, viewportH: 200)
            return (0..<list.commandCount).compactMap {
                list.emitted(at: $0).map { ($0.kind, $0.color) }
            }
        }
        XCTAssertTrue(try kinds(0).isEmpty)
        let half = try kinds(0.5)
        let blur = try XCTUnwrap(half.first { $0.0 == .beginBackdropBlur })
        XCTAssertEqual(blur.1 >> 24, 255, "adaptation is not a visibility")
        let fill = try XCTUnwrap(half.first { $0.0 == .rect })
        XCTAssertEqual(fill.1 >> 24, 102, "the fill on top still fades")
    }
}
