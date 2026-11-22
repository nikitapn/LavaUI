import CxxCanvas
@testable import LavaUI
import XCTest

final class DrawListWireValueTests: XCTestCase {
    func testDrawCommandKindWireValues() {
        typealias SwiftKind = LavaUI.DrawCommandKind
        typealias CxxKind = lava.draw.DrawCommandKind

        XCTAssertEqual(SwiftKind.rect.rawValue, CxxKind.rect.rawValue)
        XCTAssertEqual(SwiftKind.roundedRect.rawValue, CxxKind.roundedRect.rawValue)
        XCTAssertEqual(SwiftKind.text.rawValue, CxxKind.text.rawValue)
        XCTAssertEqual(SwiftKind.circle.rawValue, CxxKind.circle.rawValue)
        XCTAssertEqual(SwiftKind.line.rawValue, CxxKind.line.rawValue)
        XCTAssertEqual(SwiftKind.pushClip.rawValue, CxxKind.pushClip.rawValue)
        XCTAssertEqual(SwiftKind.popClip.rawValue, CxxKind.popClip.rawValue)
        XCTAssertEqual(SwiftKind.image.rawValue, CxxKind.image.rawValue)
        XCTAssertEqual(SwiftKind.beginBackdropBlur.rawValue, CxxKind.beginBackdropBlur.rawValue)
        XCTAssertEqual(SwiftKind.endBackdropBlur.rawValue, CxxKind.endBackdropBlur.rawValue)
        XCTAssertEqual(SwiftKind.beginContentBlur.rawValue, CxxKind.beginContentBlur.rawValue)
        XCTAssertEqual(SwiftKind.endContentBlur.rawValue, CxxKind.endContentBlur.rawValue)
        XCTAssertEqual(SwiftKind.mesh.rawValue, CxxKind.mesh.rawValue)
        XCTAssertEqual(SwiftKind.polyline.rawValue, CxxKind.polyline.rawValue)
        XCTAssertEqual(SwiftKind.spatialTriangles.rawValue, CxxKind.spatialTriangles.rawValue)
        XCTAssertEqual(SwiftKind.spatialBegin.rawValue, CxxKind.spatialBegin.rawValue)
        XCTAssertEqual(SwiftKind.beginNode.rawValue, CxxKind.beginNode.rawValue)
        XCTAssertEqual(SwiftKind.endNode.rawValue, CxxKind.endNode.rawValue)
        XCTAssertEqual(SwiftKind.nodeAnimate.rawValue, CxxKind.nodeAnimate.rawValue)
        XCTAssertEqual(SwiftKind.nodeScrollTo.rawValue, CxxKind.nodeScrollTo.rawValue)
        XCTAssertEqual(SwiftKind.shadow.rawValue, CxxKind.shadow.rawValue)
        XCTAssertEqual(SwiftKind.linearGradientRect.rawValue, CxxKind.linearGradientRect.rawValue)
        XCTAssertEqual(SwiftKind.opaqueBounds.rawValue, CxxKind.opaqueBounds.rawValue)
        XCTAssertEqual(SwiftKind.imageSurface.rawValue, CxxKind.imageSurface.rawValue)
        XCTAssertEqual(SwiftKind.strokedRect.rawValue, CxxKind.strokedRect.rawValue)
        XCTAssertEqual(SwiftKind.glass.rawValue, CxxKind.glass.rawValue)
        XCTAssertEqual(SwiftKind.imageClip.rawValue, CxxKind.imageClip.rawValue)
    }

    func testInputEventKindWireValues() {
        typealias SwiftKind = LavaUI.InputEventKind
        typealias CxxKind = lava.draw.InputEventKind

        XCTAssertEqual(SwiftKind.none.rawValue, CxxKind.none.rawValue)
        XCTAssertEqual(SwiftKind.mouseDown.rawValue, CxxKind.mouseDown.rawValue)
        XCTAssertEqual(SwiftKind.mouseUp.rawValue, CxxKind.mouseUp.rawValue)
        XCTAssertEqual(SwiftKind.mouseMove.rawValue, CxxKind.mouseMove.rawValue)
        XCTAssertEqual(SwiftKind.resize.rawValue, CxxKind.resize.rawValue)
        XCTAssertEqual(SwiftKind.key.rawValue, CxxKind.key.rawValue)
        XCTAssertEqual(SwiftKind.text.rawValue, CxxKind.text.rawValue)
        XCTAssertEqual(SwiftKind.scroll.rawValue, CxxKind.scroll.rawValue)
        XCTAssertEqual(SwiftKind.refresh.rawValue, CxxKind.refresh.rawValue)
        XCTAssertEqual(SwiftKind.fileDrop.rawValue, CxxKind.fileDrop.rawValue)
        XCTAssertEqual(SwiftKind.nodeScroll.rawValue, CxxKind.nodeScroll.rawValue)
        XCTAssertEqual(SwiftKind.nodeAnimationDone.rawValue, CxxKind.nodeAnimationDone.rawValue)
        XCTAssertEqual(SwiftKind.nodeHover.rawValue, CxxKind.nodeHover.rawValue)
        XCTAssertEqual(SwiftKind.pointerLeave.rawValue, CxxKind.pointerLeave.rawValue)
        XCTAssertEqual(SwiftKind.windowState.rawValue, CxxKind.windowState.rawValue)
        XCTAssertEqual(SwiftKind.dragOver.rawValue, CxxKind.dragOver.rawValue)
        XCTAssertEqual(SwiftKind.dragLeave.rawValue, CxxKind.dragLeave.rawValue)
        XCTAssertEqual(SwiftKind.scale.rawValue, CxxKind.scale.rawValue)
    }

    func testSceneNodeFlagWireValues() {
        typealias SwiftKind = LavaUI.SceneNodeFlag
        typealias CxxKind = lava.draw.SceneNodeFlag

        XCTAssertEqual(SwiftKind.clip.rawValue, CxxKind.clip.rawValue)
        XCTAssertEqual(SwiftKind.scrollY.rawValue, CxxKind.scrollY.rawValue)
        XCTAssertEqual(SwiftKind.scrollX.rawValue, CxxKind.scrollX.rawValue)
        XCTAssertEqual(SwiftKind.hitTest.rawValue, CxxKind.hitTest.rawValue)
        XCTAssertEqual(SwiftKind.absoluteCoordinates.rawValue, CxxKind.absoluteCoordinates.rawValue)
        XCTAssertEqual(SwiftKind.wheel.rawValue, CxxKind.wheel.rawValue)
        XCTAssertEqual(SwiftKind.hoverSnap.rawValue, CxxKind.hoverSnap.rawValue)
    }
}

extension DrawListWireValueTests {
    func testDetachedViewEmitsSurfaceLocalCommands() throws {
        let editor = try XCTUnwrap(Editor.openClient(width: 320, height: 180))
        var bounds: CanvasFrame?
        let view = VStack(spacing: 0) {
            Canvas(width: .pct(100), height: .pct(100)) { list, box in
                bounds = box
                list.rect(x: box.x, y: box.y, w: box.w, h: box.h, color: .blue)
            }
        }
        let font = try XCTUnwrap(UIFont.loadUI(assetsRoot: LavaResources.root))
        let payload = DrawList.captureEmbedded(editor: editor, width: 320, height: 180, scale: 1.5, font: font, view: view)
        XCTAssertEqual(bounds, CanvasFrame(x: 0, y: 0, w: 320, h: 180))
        XCTAssertFalse(payload.commands.isEmpty)
        XCTAssertNotNil(EmbeddedDrawFrame(commands: payload.commands, glyphs: payload.glyphs, imageIDs: []))
    }

    func testEmbeddedTextAndClickTargetUseViewportFont() throws {
        let editor = try XCTUnwrap(Editor.openClient())
        let font = try XCTUnwrap(UIFont.loadUI(assetsRoot: LavaResources.root))
        let previous = FontStore.default
        FontStore.default = nil
        defer { FontStore.default = previous }
        let view = VStack {
            Text("hello")
            Text("click", onClick: { XCTFail("Capture must not trigger the action") })
                .border(.blue, width: 1.5)
        }
        let payload = DrawList.captureEmbedded(editor: editor, width: 160, height: 80, scale: 1,
                                               font: font, view: view)
        let frame = try XCTUnwrap(EmbeddedDrawFrame(commands: payload.commands, glyphs: payload.glyphs, imageIDs: []))
        XCTAssertEqual(frame.commands.filter { $0.kind == DrawKind.text.rawValue }.count, 2)
        XCTAssertFalse(frame.glyphs.isEmpty)
        XCTAssertEqual(frame.commands.first { $0.kind == DrawKind.strokedRect.rawValue }?.param, 384)
        XCTAssertNil(FontStore.default)
    }

    func testEmbeddedScrollClipsAndTranslatesVisibleContent() throws {
        let editor = try XCTUnwrap(Editor.openClient())
        let font = try XCTUnwrap(UIFont.loadUI(assetsRoot: LavaResources.root))
        let position = ScrollPosition(offset: 45)
        let view = ScrollView(.vertical, showsIndicator: false, position: position) {
            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { i in
                    Canvas(width: .pct(100), height: .pt(20)) { list, box in
                        list.rect(x: box.x, y: box.y, w: box.w, h: box.h, color: i == 2 ? .red : .blue)
                    }.flexShrink(0)
                }
            }
        }
        let payload = DrawList.captureEmbedded(editor: editor, width: 100, height: 30, scale: 1,
                                               font: font, view: view)
        let frame = try XCTUnwrap(EmbeddedDrawFrame(commands: payload.commands, glyphs: payload.glyphs, imageIDs: []))
        XCTAssertEqual(frame.commands.first?.kind, DrawKind.pushClip.rawValue)
        XCTAssertEqual(frame.commands.first?.h, 30)
        let rows = frame.commands.filter { $0.kind == DrawKind.rect.rawValue }
        XCTAssertEqual(rows.map(\.y), [-5, 15])
        XCTAssertEqual(rows.first?.color, Color.red.rgba8)
        XCTAssertEqual(frame.commands.last?.kind, DrawKind.popClip.rawValue)
    }

    func testEmbeddedFramesValidateBeforeReplay() {
        func command(_ kind: LavaUI.DrawKind, width: Float = 0, resource: UInt32 = 0) -> [UInt8] {
            var item = canvas.DrawCommand()
            item.kind = kind.rawValue
            item.h = 16
            item.w = width
            item.param = resource
            return withUnsafeBytes(of: &item) { Array($0) }
        }
        func accepts(_ commands: [UInt8], glyphs: [UInt8] = [], images: Set<UInt32> = []) -> Bool {
            EmbeddedDrawFrame(commands: commands, glyphs: glyphs, imageIDs: images) != nil
        }
        let glyph = Array(repeating: UInt8(0), count: 16)
        let text = command(.text, width: 1)
        let image = command(.image, resource: 17)
        XCTAssertTrue(accepts(command(.pushClip, width: 16) + text + image + command(.popClip), glyphs: glyph, images: [17]))
        XCTAssertFalse(accepts(text))
        XCTAssertFalse(accepts(text + text, glyphs: glyph))
        XCTAssertFalse(accepts(image))
        XCTAssertFalse(accepts(command(.imageSurface)))
        XCTAssertFalse(accepts(command(.beginNode) + command(.endNode)))
        XCTAssertFalse(accepts(command(.strokedRect, width: 16, resource: 0)))
        XCTAssertFalse(accepts(command(.strokedRect, width: 16, resource: 0x0100_0000)))
        XCTAssertFalse(accepts(command(.popClip)))
        XCTAssertFalse(accepts(command(.pushClip, width: 16)))
        XCTAssertFalse(accepts(command(.pushClip) + command(.popClip)))
        XCTAssertFalse(accepts(command(.rect, width: .nan)))
        XCTAssertFalse(accepts([0]))
    }
}
