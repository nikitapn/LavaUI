import CxxCanvas
import XCTest

@testable import LavaUI

/// `.frame(…, alignment:)` — a box of a stated size with content placed inside
/// it, rather than content stretched to fill.
///
/// The gap this closes was visible as a calendar: a day number in a 34pt cell
/// sat 4pt left of the highlight drawn around it, because `Text` paints its
/// glyphs at its box's leading edge and `.frame` made the text's box the whole
/// cell. There was nowhere for the number to be centred *in*.
final class FrameAlignmentTests: XCTestCase {
    private typealias Cmd = (
        kind: DrawKind?, x: Float, y: Float, w: Float, h: Float,
        aux: Float, param: UInt32, color: UInt32
    )

    private func emit(
        _ view: some View, width: Float = 200, height: Float = 60
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

    /// Draws a tree that has already been mounted (and possibly reconciled).
    private func emit(
        host: LayoutHost, width: Float = 200, height: Float = 60
    ) throws -> [Cmd] {
        let editor = try XCTUnwrap(Editor.openClient(width: width, height: height))
        XCTAssertNotNil(
            FontStore.bootstrap(
                assetsRoot: LavaResources.root, pixelSize: 16, into: editor
            )
        )
        _ = host.calculateLayout(width: width, height: height)
        let root = try XCTUnwrap(host.rootNode)
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: width, viewportH: height)
        return (0..<list.commandCount).compactMap { list.emitted(at: $0) }
    }

    /// The cell, as the calendar draws it.
    private func dayCell(alignment: Alignment?) -> some View {
        Text("24", color: Color(r: 1, g: 1, b: 1))
            .frame(width: .pt(34), height: .pt(28), alignment: alignment)
            .background(Color(r: 0.2, g: 0.4, b: 0.9))
    }

    /// `text()` insets the pen by 4pt, and `measureForYoga` reserves 4pt on
    /// each side to match. Where the glyphs actually land, therefore.
    private func inkCentre(_ commands: [Cmd]) throws -> Float {
        let text = try XCTUnwrap(
            commands.first { $0.kind == .text }, "no glyphs emitted"
        )
        let font = try XCTUnwrap(FontStore.default)
        return text.x + 4 + font.shapedRun("24").width / 2
    }

    private func boxCentre(_ commands: [Cmd]) throws -> Float {
        let fill = try XCTUnwrap(
            commands.first { $0.kind == .rect && $0.w == 34 },
            "no cell background emitted"
        )
        return fill.x + fill.w / 2
    }

    // MARK: The bug

    /// Without an alignment the glyphs sit at the box's leading edge, which is
    /// the historical behaviour and stays that way — every existing caller
    /// gives a view a size expecting the view to *be* that size.
    func testWithoutAnAlignmentTheContentStillStartsAtTheLeadingEdge() throws {
        let commands = try emit(dayCell(alignment: nil))
        let text = try XCTUnwrap(commands.first { $0.kind == .text })
        let fill = try XCTUnwrap(commands.first { $0.kind == .rect && $0.w == 34 })
        XCTAssertEqual(text.x, fill.x, accuracy: 0.01)
    }

    func testCentringPutsTheGlyphsInTheMiddleOfTheBox() throws {
        let commands = try emit(dayCell(alignment: .center))
        // Within a pixel: 15.7pt of slack cannot be split evenly onto whole
        // pixels, and Yoga rounds positions to the pixel grid.
        XCTAssertEqual(
            try inkCentre(commands), try boxCentre(commands), accuracy: 1,
            "the number is not centred in the cell drawn around it"
        )
    }

    /// The whole point of the fix, stated as the thing that was wrong: the
    /// unaligned cell is off by enough to see.
    func testCentringActuallyMovesTheGlyphs() throws {
        let before = try inkCentre(try emit(dayCell(alignment: nil)))
        let after = try inkCentre(try emit(dayCell(alignment: .center)))
        XCTAssertGreaterThan(after - before, 2)
    }

    // MARK: The box keeps its size

    /// Placement must not change what the frame occupies — a grid of cells
    /// stays a grid.
    func testTheFrameKeepsItsStatedSizeWhicheverWayContentIsPlaced() throws {
        for alignment: Alignment in [
            .topLeading, .center, .bottomTrailing, .leading, .bottom,
        ] {
            let commands = try emit(dayCell(alignment: alignment))
            let fill = try XCTUnwrap(
                commands.first { $0.kind == .rect && $0.h == 28 },
                "no cell background for \(alignment)"
            )
            XCTAssertEqual(fill.w, 34, accuracy: 0.01)
            XCTAssertEqual(fill.h, 28, accuracy: 0.01)
        }
    }

    // MARK: Both axes

    func testTrailingPushesContentToTheFarEdge() throws {
        let leadingX = try XCTUnwrap(
            try emit(dayCell(alignment: .topLeading)).first { $0.kind == .text }
        ).x
        let trailingX = try XCTUnwrap(
            try emit(dayCell(alignment: .topTrailing)).first { $0.kind == .text }
        ).x
        XCTAssertGreaterThan(trailingX, leadingX)
    }

    func testBottomPushesContentDown() throws {
        let topY = try XCTUnwrap(
            try emit(dayCell(alignment: .topLeading)).first { $0.kind == .text }
        ).y
        let bottomY = try XCTUnwrap(
            try emit(dayCell(alignment: .bottomLeading)).first { $0.kind == .text }
        ).y
        XCTAssertGreaterThan(bottomY, topY)
    }

    /// The two axes are independent, which is the reason `Alignment` is a pair
    /// rather than nine cases.
    func testTheAxesAreIndependent() throws {
        let topTrailing = try emit(dayCell(alignment: .topTrailing))
        let bottomTrailing = try emit(dayCell(alignment: .bottomTrailing))
        let a = try XCTUnwrap(topTrailing.first { $0.kind == .text })
        let b = try XCTUnwrap(bottomTrailing.first { $0.kind == .text })
        XCTAssertEqual(a.x, b.x, accuracy: 0.01, "changing the vertical moved the horizontal")
        XCTAssertGreaterThan(b.y, a.y)
    }

    // MARK: Composition

    /// `Alignment` is what `OverlayAnchor` used to be, so a corner still names
    /// the same place for both.
    func testOverlayAnchorIsTheSameVocabulary() {
        XCTAssertEqual(OverlayAnchor.topTrailing, Alignment.topTrailing)
        XCTAssertEqual(Alignment.center.horizontal, .center)
        XCTAssertEqual(Alignment.bottomLeading.vertical, .bottom)
        XCTAssertEqual(
            Alignment(horizontal: .trailing, vertical: .top), .topTrailing
        )
    }

    // MARK: Reconcile

    /// The wrapper is created by the modifier and claimed back by identity on
    /// the next pass — `ModifiedView.ownsWrapper`. Getting that wrong wraps an
    /// already-parented node a second time, which is a Yoga fatal rather than
    /// a wrong pixel, so it is worth a pass that actually reconciles.
    private func cellHost(alignment: Alignment?) -> LayoutHost {
        let host = LayoutHost()
        host.setRoot(
            VStack(width: .pt(200), height: .pt(60), alignment: .start) {
                dayCell(alignment: alignment)
            }
        )
        return host
    }

    func testReconcilingAnAlignedFrameKeepsOneWrapper() throws {
        let host = cellHost(alignment: .center)
        _ = host.calculateLayout(width: 200, height: 60)
        let first = try XCTUnwrap(host.rootNode)

        host.setRoot(
            VStack(width: .pt(200), height: .pt(60), alignment: .start) {
                dayCell(alignment: .center)
            }
        )
        let frames = host.calculateLayout(width: 200, height: 60)
        XCTAssertTrue(host.rootNode === first, "the tree was rebuilt, not reconciled")
        XCTAssertTrue(
            frames.contains { $0.w == 34 && $0.h == 28 },
            "the cell lost its stated size across a reconcile"
        )
    }

    /// Dropping the alignment has to give the stretch back rather than leave a
    /// row container behind placing content that is meant to fill.
    func testDroppingTheAlignmentRestoresTheStretch() throws {
        let host = cellHost(alignment: .center)
        _ = host.calculateLayout(width: 200, height: 60)

        host.setRoot(
            VStack(width: .pt(200), height: .pt(60), alignment: .start) {
                dayCell(alignment: nil)
            }
        )
        let commands = try emit(host: host)
        let text = try XCTUnwrap(commands.first { $0.kind == .text })
        let fill = try XCTUnwrap(commands.first { $0.kind == .rect && $0.w == 34 })
        XCTAssertEqual(text.x, fill.x, accuracy: 0.01)
    }

    /// A later frame in the chain must not lose the placement an earlier one
    /// asked for — the wrapper has to survive `.background()` and friends.
    func testPlacementSurvivesLaterModifiers() throws {
        let commands = try emit(
            Text("24", color: Color(r: 1, g: 1, b: 1))
                .frame(width: .pt(34), height: .pt(28), alignment: .center)
                .background(Color(r: 0.2, g: 0.4, b: 0.9))
                .cornerRadius(6)
        )
        let fill = try XCTUnwrap(
            commands.first { $0.kind == .roundedRect && $0.w == 34 },
            "the rounded cell background went missing"
        )
        XCTAssertEqual(fill.h, 28, accuracy: 0.01)
        let text = try XCTUnwrap(commands.first { $0.kind == .text })
        XCTAssertGreaterThan(text.x, fill.x, "content was not placed inside")
    }
}
