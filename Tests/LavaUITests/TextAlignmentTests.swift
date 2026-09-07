import CYoga
import CxxCanvas
import XCTest

@testable import LavaUI

/// `Text(align:)` — glyphs placed inside the text's *own* node.
///
/// The sibling of `FrameAlignmentTests`, and the distinction between them is
/// the whole reason this exists. `.frame(…, alignment:)` centres by wrapping
/// the text in a box it does not own; everything stated after that modifier
/// lands on the wrapper while `onClick` stays on the text, so a mode button
/// measured 44×39 to look at and hover and 27×27 to click. This centres
/// without adding a node, so the click target is whatever the frame said.
final class TextAlignmentTests: XCTestCase {
    private typealias Cmd = (
        kind: DrawKind?, x: Float, y: Float, w: Float, h: Float,
        aux: Float, param: UInt32, color: UInt32
    )

    private func host(
        _ view: some View, width: Float = 200, height: Float = 60
    ) throws -> LayoutHost {
        let host = LayoutHost()
        host.setRoot(
            VStack(width: .pt(width), height: .pt(height), alignment: .start) {
                view
            }
        )
        return host
    }

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
        let host = try host(view, width: width, height: height)
        _ = host.calculateLayout(width: width, height: height)
        let root = try XCTUnwrap(host.rootNode)
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: width, viewportH: height)
        return (0..<list.commandCount).compactMap { list.emitted(at: $0) }
    }

    /// A mode button, as the viewer's control bar draws one.
    private func modeButton(align: Alignment) -> some View {
        Text("Fit", color: Color(r: 1, g: 1, b: 1), align: align, onClick: {})
            .padding(6)
            .frame(width: .pt(44))
            .background(Color(r: 0.2, g: 0.4, b: 0.9))
    }

    /// `text()` insets the pen by 4pt, so this is where the ink starts.
    private func inkCentre(_ commands: [Cmd], _ string: String) throws -> Float {
        let text = try XCTUnwrap(
            commands.first { $0.kind == .text }, "no glyphs emitted"
        )
        let font = try XCTUnwrap(FontStore.default)
        return text.x + 4 + font.shapedRun(string).width / 2
    }

    private func boxCentre(_ commands: [Cmd]) throws -> Float {
        let fill = try XCTUnwrap(
            commands.first { $0.kind == .rect && $0.w == 44 },
            "no button background emitted"
        )
        return fill.x + fill.w / 2
    }

    // MARK: Placement

    /// The default is unchanged, because every existing caller depends on it.
    func testTopLeadingIsTheDefaultAndStillHugsTheEdge() throws {
        let plain = try emit(
            Text("Fit", color: Color(r: 1, g: 1, b: 1))
                .padding(6)
                .frame(width: .pt(44))
                .background(Color(r: 0.2, g: 0.4, b: 0.9))
        )
        let explicit = try emit(modeButton(align: .topLeading))
        let a = try XCTUnwrap(plain.first { $0.kind == .text })
        let b = try XCTUnwrap(explicit.first { $0.kind == .text })
        XCTAssertEqual(a.x, b.x, accuracy: 0.01)
    }

    func testCentringPutsTheGlyphsInTheMiddleOfTheBox() throws {
        let commands = try emit(modeButton(align: .center))
        XCTAssertEqual(
            try inkCentre(commands, "Fit"), try boxCentre(commands),
            accuracy: 1,
            "the label is not centred in the button drawn around it"
        )
    }

    func testTrailingPutsThemAgainstTheFarEdge() throws {
        let commands = try emit(modeButton(align: .trailing))
        let text = try XCTUnwrap(commands.first { $0.kind == .text })
        let fill = try XCTUnwrap(commands.first { $0.kind == .rect && $0.w == 44 })
        let font = try XCTUnwrap(FontStore.default)
        let inkEnd = text.x + 4 + font.shapedRun("Fit").width
        XCTAssertEqual(inkEnd, fill.x + fill.w - 6 - 4, accuracy: 1)
    }

    func testCentringActuallyMovesTheGlyphs() throws {
        let before = try inkCentre(try emit(modeButton(align: .topLeading)), "Fit")
        let after = try inkCentre(try emit(modeButton(align: .center)), "Fit")
        XCTAssertGreaterThan(after - before, 2)
    }

    /// A box that is exactly its text has nothing to distribute, so every
    /// alignment agrees — and a shrink-wrapped label is the common case.
    func testAlignmentIsANoOpWhenThereIsNoSlack() throws {
        var positions: [Float] = []
        for align: Alignment in [.leading, .center, .trailing] {
            let commands = try emit(
                Text("Fit", color: Color(r: 1, g: 1, b: 1), align: align)
            )
            positions.append(try XCTUnwrap(commands.first { $0.kind == .text }).x)
        }
        XCTAssertEqual(positions[0], positions[1], accuracy: 0.01)
        XCTAssertEqual(positions[1], positions[2], accuracy: 0.01)
    }

    // MARK: What it must not change

    /// The reason to prefer this over `.frame(alignment:)`: no extra node, so
    /// the clickable leaf is still the one the frame sized. This is the
    /// regression — the framed-and-aligned version made the button 44pt wide
    /// and 27pt clickable.
    func testCentringAddsNoNodeSoTheWholeFrameStaysClickable() throws {
        let host = try host(modeButton(align: .center))
        _ = host.calculateLayout(width: 200, height: 60)
        let root = try XCTUnwrap(host.rootNode)

        var clickable: [(w: Float, h: Float)] = []
        func walk(_ node: any AnyViewNode) {
            if let leaf = node as? LeafNode, leaf.kind == .text,
               leaf.onClick != nil, let yoga = leaf.yoga
            {
                clickable.append(
                    (YGNodeLayoutGetWidth(yoga), YGNodeLayoutGetHeight(yoga))
                )
            }
            for child in node.childNodes { walk(child) }
        }
        walk(root)

        XCTAssertEqual(clickable.count, 1, "expected exactly one clickable leaf")
        XCTAssertEqual(
            try XCTUnwrap(clickable.first).w, 44, accuracy: 0.01,
            "the clickable leaf is narrower than the button drawn around it"
        )
    }

    /// Placement must not feed back into measurement, or a centred label in an
    /// auto-width box would size itself differently from a leading one.
    func testAlignmentDoesNotChangeTheMeasuredWidth() throws {
        var widths: [Float] = []
        for align: Alignment in [.leading, .center, .trailing] {
            let host = try host(
                Text("Fit", color: Color(r: 1, g: 1, b: 1), align: align)
            )
            _ = host.calculateLayout(width: 200, height: 60)
            let root = try XCTUnwrap(host.rootNode)
            var found: Float?
            func walk(_ node: any AnyViewNode) {
                if let leaf = node as? LeafNode, leaf.kind == .text,
                   let yoga = leaf.yoga
                {
                    found = YGNodeLayoutGetWidth(yoga)
                }
                for child in node.childNodes { walk(child) }
            }
            walk(root)
            widths.append(try XCTUnwrap(found))
        }
        XCTAssertEqual(widths[0], widths[1], accuracy: 0.01)
        XCTAssertEqual(widths[1], widths[2], accuracy: 0.01)
    }
}

/// `Text(align:)` against `.frame(…, alignment:)` — the same picture, one
/// fewer node.
///
/// This is the test that lets the taskbar's calendar and media applet move
/// across without being run. Those cells state a *height* as well as a width,
/// so the frame was centring them on both axes; a horizontal-only replacement
/// would have quietly moved every day number to the top of its cell. Equality
/// here is what says the swap is a swap.
final class TextAlignmentEquivalenceTests: XCTestCase {
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
            )
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

    private func glyphOrigin(_ commands: [Cmd]) throws -> (x: Float, y: Float) {
        let text = try XCTUnwrap(
            commands.first { $0.kind == .text }, "no glyphs emitted"
        )
        return (text.x, text.y)
    }

    /// A calendar day cell, both ways round — at its real 34×28 and in a box
    /// tall enough that the vertical half of the claim is worth something.
    ///
    /// The tall case matters: a 28pt cell only has about a point of vertical
    /// slack in it, so agreeing "within a point" there would also be true of
    /// an implementation that ignored the vertical axis entirely.
    func testTheTwoSpellingsPutTheGlyphsInTheSamePlace() throws {
        for label in ["1", "24", "31"] {
            // 34×28 is the calendar's day cell and 34×22 its weekday strip —
            // the second is *shorter* than the line it holds, so the two
            // spellings have to agree about a box with no room in it as well
            // as one with plenty. 80×64 is the case with enough vertical
            // slack for the comparison to mean something.
            for (w, h) in [
                (Float(34), Float(28)), (Float(34), Float(22)),
                (Float(80), Float(64)),
            ] {
                let framed = try emit(
                    Text(label, color: Color(r: 1, g: 1, b: 1))
                        .frame(width: .pt(w), height: .pt(h), alignment: .center)
                )
                let aligned = try emit(
                    Text(label, color: Color(r: 1, g: 1, b: 1), align: .center)
                        .frame(width: .pt(w), height: .pt(h))
                )
                let a = try glyphOrigin(framed)
                let b = try glyphOrigin(aligned)
                XCTAssertEqual(
                    a.x, b.x, accuracy: 1,
                    "\"\(label)\" in \(w)×\(h) moved horizontally"
                )
                XCTAssertEqual(
                    a.y, b.y, accuracy: 1,
                    "\"\(label)\" in \(w)×\(h) moved vertically"
                )
            }
        }
    }

    /// And the tall box really does have somewhere to move to, so the test
    /// above is comparing two numbers that could have differed.
    func testTheTallCaseHasVerticalSlackWorthComparing() throws {
        let top = try glyphOrigin(try emit(
            Text("24", color: Color(r: 1, g: 1, b: 1), align: .topLeading)
                .frame(width: .pt(80), height: .pt(64))
        ))
        let middle = try glyphOrigin(try emit(
            Text("24", color: Color(r: 1, g: 1, b: 1), align: .center)
                .frame(width: .pt(80), height: .pt(64))
        ))
        XCTAssertGreaterThan(middle.y - top.y, 15)
    }

    /// The point of moving: the wrapper is gone.
    func testTheAlignedSpellingEmitsOneFewerNode() throws {
        func nodeCount(_ view: some View) throws -> Int {
            let host = LayoutHost()
            host.setRoot(
                VStack(width: .pt(200), height: .pt(60), alignment: .start) {
                    view
                }
            )
            _ = host.calculateLayout(width: 200, height: 60)
            let root = try XCTUnwrap(host.rootNode)
            var n = 0
            func walk(_ node: any AnyViewNode) {
                n += 1
                for child in node.childNodes { walk(child) }
            }
            walk(root)
            return n
        }

        let framed = try nodeCount(
            Text("24", color: Color(r: 1, g: 1, b: 1))
                .frame(width: .pt(34), height: .pt(28), alignment: .center)
        )
        let aligned = try nodeCount(
            Text("24", color: Color(r: 1, g: 1, b: 1), align: .center)
                .frame(width: .pt(34), height: .pt(28))
        )
        XCTAssertEqual(
            framed - aligned, 1,
            "expected the frame's alignment wrapper to be the only difference"
        )
    }

    /// Vertical placement is the half a horizontal-only fix would have missed
    /// — and the reason the taskbar's cells could not simply take
    /// `HorizontalAlignment`. Bottom too, so `.center` is not passing by
    /// being the only case wired up.
    func testVerticalPlacementMovesTheGlyphsDown() throws {
        func originY(_ align: Alignment) throws -> Float {
            try glyphOrigin(try emit(
                Text("24", color: Color(r: 1, g: 1, b: 1), align: align)
                    .frame(width: .pt(80), height: .pt(64))
            )).y
        }
        let top = try originY(.topLeading)
        let middle = try originY(.center)
        let bottom = try originY(.bottom)
        XCTAssertGreaterThan(middle - top, 15)
        XCTAssertGreaterThan(bottom - middle, 15)
    }
}
