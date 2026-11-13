import CxxCanvas
import XCTest

@testable import LavaUI

/// `overlay(alignment:style:)` — the panel a composed overlay draws.
///
/// Asserts on the emitted command stream rather than on the node graph,
/// because the question the style is supposed to answer is a question about
/// pixels: whether the backdrop scope opens *before* the panel's own chrome.
/// A node carrying the right radius and an emit that opens the scope in the
/// wrong place look identical from the tree.
final class ComposedOverlayStyleTests: XCTestCase {
    func testIndependentInsetsPlacePanelAwayFromRightEdge() throws {
        let commands = try emit(
            Canvas(width: .pt(400), height: .pt(300)) { _, _ in }
                .overlay(alignment: .topTrailing,
                         insets: EdgeInsets(top: 12, trailing: 32)) {
                    Canvas(width: .pt(80), height: .pt(40)) { list, frame in
                        list.rect(x: frame.x, y: frame.y, w: frame.w, h: frame.h,
                                  color: .white)
                    }
                }
        )
        let panel = try XCTUnwrap(commands.first { $0.kind == .rect })
        XCTAssertEqual(panel.x, 288, accuracy: 0.01)
        XCTAssertEqual(panel.y, 12, accuracy: 0.01)
        XCTAssertEqual(panel.w, 80, accuracy: 0.01)
        XCTAssertEqual(panel.h, 40, accuracy: 0.01)
    }

    func testChangingTrailingInsetPreservesTopAndBaseGeometry() throws {
        func tree(_ trailing: Float) -> some View {
            Canvas(label: "base", width: .pt(400), height: .pt(300)) { _, _ in }
                .overlay(alignment: .topTrailing,
                         insets: EdgeInsets(top: 12, trailing: trailing)) {
                    Canvas(label: "floating", width: .pt(80), height: .pt(40)) { _, _ in }
                }
        }
        let host = LayoutHost()
        for trailing: Float in [12, 48] {
            host.setRoot(tree(trailing))
            let frames = host.calculateLayout(width: 400, height: 300)
            let base = try XCTUnwrap(frames.first { $0.label == "base" })
            let panel = try XCTUnwrap(frames.first { $0.label == "floating" })
            XCTAssertEqual(base.w, 400, accuracy: 0.01)
            XCTAssertEqual(base.h, 300, accuracy: 0.01)
            XCTAssertEqual(panel.x, 400 - trailing - 80, accuracy: 0.01)
            XCTAssertEqual(panel.y, 12, accuracy: 0.01)
        }
    }

    /// A panel wider than the base narrows to it, and a shrinkable field in
    /// it takes the difference, instead of spilling past the base's edge.
    func testPanelWiderThanBaseShrinksToFit() throws {
        func frames(width: Float) throws -> (panel: LayoutFrame, field: LayoutFrame) {
            let host = LayoutHost()
            host.setRoot(
                Canvas(label: "base", width: .pct(100), height: .pt(300)) { _, _ in }
                    .overlay(alignment: .topTrailing,
                             insets: EdgeInsets(top: 12, trailing: 32),
                             style: OverlayStyle(cornerRadius: 8, padding: 0)) {
                        HStack(spacing: 0) {
                            Canvas(label: "field", width: .pt(200), height: .pt(20)) { _, _ in }
                                .flexShrink(1)
                            Canvas(label: "steps", width: .pt(100), height: .pt(20)) { _, _ in }
                        }
                    }
            )
            let all = host.calculateLayout(width: width, height: 300)
            let field = try XCTUnwrap(all.first { $0.label == "field" })
            let steps = try XCTUnwrap(all.first { $0.label == "steps" })
            let panel = LayoutFrame(label: "panel", x: field.x, y: field.y,
                                    w: steps.x + steps.w - field.x, h: field.h)
            return (panel, field)
        }
        let wide = try frames(width: 800)
        XCTAssertEqual(wide.field.w, 200, accuracy: 0.01)
        XCTAssertEqual(wide.panel.x + wide.panel.w, 768, accuracy: 1.01)

        let narrow = try frames(width: 250)
        XCTAssertGreaterThanOrEqual(narrow.panel.x, -0.01)
        XCTAssertEqual(narrow.panel.x + narrow.panel.w, 218, accuracy: 1.01)
        XCTAssertLessThan(narrow.field.w, 200)
    }

    private struct Base: View {
        let style: OverlayStyle?

        var body: some View {
            VStack(width: .pt(400), height: .pt(300)) {
                Text("behind")
            }
            .overlay(alignment: .top, inset: 10, style: style) {
                Text("panel")
            }
        }
    }

    /// The emitted stream, as (kind, x, y, w, h), in order.
    private func emit(
        _ view: some View, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [
        (
            kind: DrawKind, x: Float, y: Float, w: Float, h: Float,
            aux: Float, param: UInt32, color: UInt32
        )
    ] {
        let editor = try XCTUnwrap(
            Editor.openClient(width: 400, height: 300),
            "client engine failed to open", file: file, line: line
        )
        XCTAssertNotNil(
            FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editor),
            "default face failed to load", file: file, line: line
        )
        let host = LayoutHost()
        host.setRoot(view)
        _ = host.calculateLayout(width: 400, height: 300)
        let root = try XCTUnwrap(host.rootNode, file: file, line: line)

        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: 400, viewportH: 300)

        return (0..<list.commandCount).compactMap { index -> (
            kind: DrawKind, x: Float, y: Float, w: Float, h: Float,
            aux: Float, param: UInt32, color: UInt32
        )? in
            guard let cmd = list.emitted(at: index), let kind = cmd.kind
            else { return nil }
            return (kind, cmd.x, cmd.y, cmd.w, cmd.h, cmd.aux, cmd.param, cmd.color)
        }
    }

    /// No style is the old behaviour exactly: content and nothing under it.
    ///
    /// Asserted as "no rounded plate anywhere", not "no fills anywhere": the
    /// base view legitimately paints, and a test that forbade all fills would
    /// be testing the fixture.
    func testUnstyledOverlayDrawsNoPanel() throws {
        let commands = try emit(Base(style: nil))
        XCTAssertFalse(
            commands.contains { $0.kind == .roundedRect },
            "an unstyled composed overlay painted a surface it was not asked for"
        )
        XCTAssertFalse(commands.contains { $0.kind == .beginBackdropBlur })
    }

    /// Fill and outline, and the outline a pixel proud on every side.
    func testStyleDrawsOutlineOutsideFill() throws {
        let commands = try emit(
            Base(
                style: OverlayStyle(
                    background: Color(r: 0.1, g: 0.1, b: 0.1, a: 1),
                    border: Color(r: 1, g: 0, b: 0, a: 1),
                    cornerRadius: 8,
                    padding: 6
                )
            )
        )
        let plates = commands.filter { $0.kind == .roundedRect }
        XCTAssertEqual(plates.count, 2, "expected an outline and a fill")

        // Declaration order is paint order: outline first, fill over it.
        let outline = plates[0]
        let fill = plates[1]
        XCTAssertEqual(outline.x, fill.x - 1, accuracy: 0.01)
        XCTAssertEqual(outline.y, fill.y - 1, accuracy: 0.01)
        XCTAssertEqual(outline.w, fill.w + 2, accuracy: 0.01)
        XCTAssertEqual(outline.h, fill.h + 2, accuracy: 0.01)

        // Anchored top, inset 10, centred horizontally by `.top`.
        XCTAssertEqual(outline.y, 10, accuracy: 0.01)
    }

    /// Until rounded rectangles have a real stroke, their border is a filled
    /// plate underneath the panel. Keeping that plate under an alpha fill
    /// makes the complete panel opaque, because its middle shows through too.
    func testTranslucentStyleDoesNotPutOpaquePlateBehindFill() throws {
        let commands = try emit(
            Base(
                style: OverlayStyle(
                    background: Color(r: 0.1, g: 0.1, b: 0.1, a: 0.5),
                    border: Color(r: 1, g: 0, b: 0, a: 1),
                    cornerRadius: 8,
                    padding: 6
                )
            )
        )

        let plates = commands.filter { $0.kind == .roundedRect }
        XCTAssertEqual(plates.count, 1, "opaque border plate defeated panel alpha")
        XCTAssertEqual(plates[0].color >> 24, 128, "panel alpha was not emitted")
    }

    /// The one that matters: the scope opens before any of the panel's own
    /// paint, so what frosts is the base view and not the plate.
    func testBackdropBlurScopeOpensBeforePanelChrome() throws {
        let commands = try emit(
            Base(
                style: OverlayStyle(
                    background: Color(r: 0.1, g: 0.1, b: 0.1, a: 0.4),
                    cornerRadius: 8,
                    backdropBlurRadius: 10
                )
            )
        )
        let begin = try XCTUnwrap(
            commands.firstIndex { $0.kind == .beginBackdropBlur },
            "no backdrop scope was emitted for a styled composed overlay"
        )
        let end = try XCTUnwrap(commands.firstIndex { $0.kind == .endBackdropBlur })
        XCTAssertEqual(commands[begin].aux, 10, accuracy: 0.01)
        // The frost is cut to the panel's shape. Without this the composite is
        // a rectangle *under* a rounded fill, and its corners show as four
        // bright tabs the panel cannot cover. A translucent surface has no
        // outline plate, so the scope carries the fill's radius exactly.
        XCTAssertEqual(commands[begin].param, 8)

        // Everything the panel paints is inside the scope.
        let plates = commands.indices.filter { commands[$0].kind == .roundedRect }
        XCTAssertFalse(plates.isEmpty, "panel painted nothing to be sharp")
        for plate in plates {
            XCTAssertTrue(
                plate > begin && plate < end,
                "panel chrome fell outside the blur scope and would be frosted"
            )
        }

        // The frosted rect covers the panel, so the glass is the whole surface
        // rather than a band under part of it.
        let panel = commands[plates[0]]
        XCTAssertLessThanOrEqual(commands[begin].x, panel.x + 0.01)
        XCTAssertLessThanOrEqual(commands[begin].y, panel.y + 0.01)
        XCTAssertGreaterThanOrEqual(
            commands[begin].x + commands[begin].w, panel.x + panel.w - 0.01
        )
        XCTAssertGreaterThanOrEqual(
            commands[begin].y + commands[begin].h, panel.y + panel.h - 0.01
        )
    }

    /// A styled overlay still contributes no layout — the whole premise of the
    /// composition variant, and the thing a panel with padding could break.
    func testStyledOverlayStillTakesNoLayoutSpace() throws {
        let host = LayoutHost()
        host.setRoot(Base(style: OverlayStyle(padding: 16, minWidth: 200)))
        let frames = host.calculateLayout(width: 400, height: 300)
        // Labels carry the string, so match on the prefix.
        let behind = try XCTUnwrap(frames.first { $0.label.hasPrefix("Text \"behind\"") })
        // The base view's text sits where it would with no overlay at all.
        XCTAssertEqual(behind.x, 0, accuracy: 0.01)
        XCTAssertEqual(behind.y, 0, accuracy: 0.01)
    }
}
