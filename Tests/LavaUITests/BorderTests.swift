import CxxCanvas
import XCTest

@testable import LavaUI

/// `.border(_:width:)` — a stroke on a view's own edge.
///
/// The framework faked one four different ways before this existed, all of
/// them a filled plate with the content punched back on top: the focus ring,
/// the overlay outline, `Expand`'s nested fills and padding, and
/// `ComposedOverlay`'s plate box. Every one of them needs to know the colour
/// underneath, so none of them can frame a view whose background is an image,
/// a gradient, or nothing at all. A real stroke is a level set of the distance
/// field the fill already evaluates, so this asks the renderer for an outline
/// rather than arranging two fills to look like one.
final class BorderTests: XCTestCase {
    private typealias Cmd = (
        kind: DrawKind?, x: Float, y: Float, w: Float, h: Float,
        aux: Float, param: UInt32, color: UInt32
    )

    private func emit(
        _ view: some View, width: Float = 400, height: Float = 80
    ) throws -> [Cmd] {
        let editor = try XCTUnwrap(
            Editor.openClient(width: width, height: height),
            "client engine failed to open"
        )
        XCTAssertNotNil(
            FontStore.bootstrap(
                assetsRoot: LavaResources.root, pixelSize: 16, into: editor
            ),
            "default face failed to load"
        )
        let host = LayoutHost()
        host.setRoot(
            VStack(width: .pt(width), height: .pt(height), alignment: .start) {
                view
            }
        )
        _ = host.calculateLayout(width: width, height: height)
        let root = try XCTUnwrap(host.rootNode)
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: width, viewportH: height)
        return (0..<list.commandCount).compactMap { list.emitted(at: $0) }
    }

    private func strokes(_ commands: [Cmd]) -> [Cmd] {
        commands.filter { $0.kind == .strokedRect }
    }

    /// The purple 4pt border from the request, on a plain box.
    func testABorderEmitsOneStrokeTheSizeOfTheView() throws {
        let commands = try emit(
            Text("Hi")
                .frame(width: .pt(120), height: .pt(30))
                .border(Color(r: 0.5, g: 0, b: 0.5), width: 4)
        )
        let found = strokes(commands)
        XCTAssertEqual(found.count, 1, "expected exactly one stroke")
        let stroke = try XCTUnwrap(found.first)
        XCTAssertEqual(stroke.w, 120, accuracy: 0.5, "stroke width mismatch")
        XCTAssertEqual(stroke.h, 30, accuracy: 0.5, "stroke height mismatch")
        XCTAssertEqual(
            stroke.color, Color(r: 0.5, g: 0, b: 0.5).rgba8,
            "stroke drew in the wrong colour"
        )
    }

    /// The whole point of a border: it frames the content, so it is drawn
    /// after it. Painted first it would sit under the glyphs and under any
    /// child's own background.
    func testTheBorderIsDrawnOverTheContent() throws {
        let commands = try emit(
            Text("Hi")
                .frame(width: .pt(120), height: .pt(30))
                .border(Color(r: 1, g: 0, b: 0), width: 2)
        )
        let textAt = try XCTUnwrap(
            commands.firstIndex { $0.kind == .text }, "no glyphs emitted"
        )
        let strokeAt = try XCTUnwrap(
            commands.firstIndex { $0.kind == .strokedRect }, "no stroke emitted"
        )
        XCTAssertLessThan(
            textAt, strokeAt, "the border must be painted over the content"
        )
    }

    /// A background and a border compose: fill first, stroke last, one rect.
    func testABorderSitsOverItsOwnBackground() throws {
        let commands = try emit(
            Text("Hi")
                .frame(width: .pt(120), height: .pt(30))
                .background(Color(r: 0, g: 0, b: 1))
                .border(Color(r: 1, g: 0, b: 0), width: 2)
        )
        // By colour, not by kind: the enclosing VStack fills its own rect too,
        // and matching the first `.rect` finds that one instead.
        let blue = Color(r: 0, g: 0, b: 1).rgba8
        let fillAt = try XCTUnwrap(
            commands.firstIndex { $0.kind == .rect && $0.color == blue },
            "no background emitted"
        )
        let strokeAt = try XCTUnwrap(
            commands.firstIndex { $0.kind == .strokedRect }, "no stroke emitted"
        )
        XCTAssertLessThan(fillAt, strokeAt, "the border must sit over the fill")
        XCTAssertEqual(
            commands[fillAt].w, commands[strokeAt].w, accuracy: 0.5,
            "fill and border should describe the same rect"
        )
        XCTAssertEqual(commands[fillAt].h, commands[strokeAt].h, accuracy: 0.5)
    }

    /// `.cornerRadius()` and `.border()` describe one shape. The radius rides
    /// on `aux`, the same field the fill uses, so the two stay concentric.
    func testABorderFollowsTheCornerRadius() throws {
        let commands = try emit(
            Text("Hi")
                .frame(width: .pt(120), height: .pt(30))
                .cornerRadius(9)
                .border(Color(r: 1, g: 0, b: 0), width: 2)
        )
        let stroke = try XCTUnwrap(strokes(commands).first, "no stroke emitted")
        XCTAssertEqual(stroke.aux, 9, accuracy: 0.01, "border ignored the radius")
    }

    /// The width crosses as 24.8 fixed point because `DrawCommand` has no
    /// float field left for it. Whole pixels would round a hairline on a
    /// fractional-scale output to nothing, or to double what was asked for.
    func testAFractionalWidthSurvivesTheCrossing() throws {
        let commands = try emit(
            Text("Hi")
                .frame(width: .pt(120), height: .pt(30))
                .border(Color(r: 1, g: 0, b: 0), width: 1.5)
        )
        let stroke = try XCTUnwrap(strokes(commands).first, "no stroke emitted")
        XCTAssertEqual(
            Float(stroke.param) / 256, 1.5, accuracy: 0.01,
            "fractional border width did not survive the fixed-point encoding"
        )
    }

    /// A hairline must not round down to nothing, which is what an integer
    /// field would have done to every sub-pixel width.
    func testAHairlineIsNotRoundedAway() throws {
        let commands = try emit(
            Text("Hi")
                .frame(width: .pt(120), height: .pt(30))
                .border(Color(r: 1, g: 0, b: 0), width: 0.5)
        )
        let stroke = try XCTUnwrap(strokes(commands).first, "no stroke emitted")
        XCTAssertGreaterThan(stroke.param, 0, "a hairline border vanished")
        XCTAssertEqual(Float(stroke.param) / 256, 0.5, accuracy: 0.01)
    }

    /// The border is emitted outside this box's own scissor. Inside it, the
    /// scissor is the same rect the stroke sits on, so half of it — the outer
    /// half, which is all of it here — would be clipped away.
    func testAClippedViewStillDrawsItsBorder() throws {
        let commands = try emit(
            Text("XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX")
                .frame(width: .pt(60), height: .pt(24))
                .clipped()
                .border(Color(r: 1, g: 0, b: 0), width: 2)
        )
        let strokeAt = try XCTUnwrap(
            commands.firstIndex { $0.kind == .strokedRect }, "no stroke emitted"
        )
        let popAt = try XCTUnwrap(
            commands.lastIndex { $0.kind == .popClip }, "no scissor emitted"
        )
        XCTAssertGreaterThan(
            strokeAt, popAt, "the border was drawn inside its own scissor"
        )
    }

    /// Not every box can show a border, and the ones that cannot accept it
    /// silently — which is the failure `canPaint` exists to prevent, and the
    /// one that cost this file a gradient once already.
    ///
    /// A `ScrollNode` is the case: it is a `YogaBoxNode`, so the style applies
    /// to it without complaint, but the emitter takes its own early return
    /// before reaching any of the three branches that paint one. Listing
    /// `border` in `canPaint` is what forces the wrapper that can. Nothing
    /// else about the view would look wrong — the border would simply not be
    /// there.
    func testABorderOnAScrollViewStillPaints() throws {
        let commands = try emit(
            ScrollView {
                Text("Hi")
                Text("There")
            }
            .frame(width: .pt(120), height: .pt(40))
            .border(Color(r: 1, g: 0, b: 0), width: 3)
        )
        XCTAssertEqual(
            strokes(commands).count, 1,
            "a border on a scroll container was dropped"
        )
    }

    /// `applyViewStyle` replays over a baseline snapshot rather than over the
    /// node as it stands, so a field must be read *through* that baseline to
    /// come off when the style stops naming it.
    ///
    /// `fill` is deliberately set-if-present — a primitive may have painted
    /// its own background and a modifier that does not mention one must not
    /// erase it. A border has no such owner: it exists only because
    /// `.border()` asked, so it has to vanish when the ask does, the way
    /// `.blur()` and `.cursor()` already do. Read the wrong way it would be a
    /// stroke that could be turned on and never off.
    func testABorderIsClearedWhenTheStyleStopsNamingIt() throws {
        let host = LayoutHost()
        host.setRoot(VStack { Text("Hi") })
        _ = host.calculateLayout(width: 100, height: 40)
        let box = try XCTUnwrap(host.rootNode as? YogaBoxNode)

        var bordered = ViewStyle()
        bordered.border = BorderStyle(Color(r: 1, g: 0, b: 0), width: 2)
        box.applyViewStyle(bordered)
        XCTAssertNotNil(box.borderStyle, "the border never went on")

        // A later modifier in the chain re-applying without one.
        var framed = ViewStyle()
        framed.width = .pt(50)
        box.applyViewStyle(framed)
        XCTAssertNil(
            box.borderStyle, "the border outlived the style that asked for it"
        )
    }

    /// Nothing to draw is drawn as nothing, rather than as a zero-width
    /// command the renderer has to reject.
    func testAnInvisibleBorderEmitsNoCommand() throws {
        let transparent = try emit(
            Text("Hi").frame(width: .pt(80), height: .pt(20))
                .border(Color(r: 1, g: 0, b: 0, a: 0), width: 4)
        )
        XCTAssertTrue(strokes(transparent).isEmpty, "a clear border drew")

        let zeroWidth = try emit(
            Text("Hi").frame(width: .pt(80), height: .pt(20))
                .border(Color(r: 1, g: 0, b: 0), width: 0)
        )
        XCTAssertTrue(strokes(zeroWidth).isEmpty, "a 0pt border drew")
    }

    /// SwiftUI's ordering rule: `.border()` before `.padding()` frames the
    /// content, after it frames the padded box. They are different rects, and
    /// collapsing them onto one node would make the two spellings identical.
    func testBorderBeforeAndAfterPaddingFrameDifferentRects() throws {
        let inner = try emit(
            Text("Hi")
                .frame(width: .pt(60), height: .pt(20))
                .border(Color(r: 1, g: 0, b: 0), width: 2)
                .padding(10)
        )
        let outer = try emit(
            Text("Hi")
                .frame(width: .pt(60), height: .pt(20))
                .padding(10)
                .border(Color(r: 1, g: 0, b: 0), width: 2)
        )
        // Counts as well as sizes. Padding after a border materialises a
        // second box, and a style that leaked onto it would draw a second
        // stroke around the padding — with the first one still correct, so
        // checking only `first` would call that a pass.
        XCTAssertEqual(
            strokes(inner).count, 1, "one .border() should draw one stroke"
        )
        XCTAssertEqual(strokes(outer).count, 1)
        let a = try XCTUnwrap(strokes(inner).first, "no stroke before padding")
        let b = try XCTUnwrap(strokes(outer).first, "no stroke after padding")
        XCTAssertEqual(a.w, 60, accuracy: 0.5, "inner border should hug the frame")
        XCTAssertEqual(
            b.w, 80, accuracy: 0.5, "outer border should enclose the padding"
        )
    }
}
