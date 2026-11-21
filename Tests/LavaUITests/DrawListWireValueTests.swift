import CxxCanvas
import LavaUI
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
