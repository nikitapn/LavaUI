import CxxCanvas
import XCTest

@testable import LavaUI

/// `.clipped()` scissors this view's own paint, not only its children.
///
/// A `Text` in a narrower `.frame` is the case that showed the gap: stacks
/// already clipped descendants, but a leaf has none, so the glyphs ignored
/// the box and walked over whatever sat to the right of it.
final class ClipTests: XCTestCase {
    private static let long = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"

    private func emit(_ view: some View) throws -> [(kind: DrawKind, w: Float, h: Float)] {
        let editor = try XCTUnwrap(
            Editor.openClient(width: 400, height: 80),
            "client engine failed to open"
        )
        XCTAssertNotNil(
            FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editor),
            "default face failed to load"
        )
        let host = LayoutHost()
        host.setRoot(
            VStack(width: .pt(400), height: .pt(80), alignment: .start) {
                view
            }
        )
        _ = host.calculateLayout(width: 400, height: 80)
        let root = try XCTUnwrap(host.rootNode)
        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: 400, viewportH: 80)
        return (0..<list.commandCount).compactMap { index in
            guard let cmd = list.emitted(at: index), let kind = cmd.kind else {
                return nil
            }
            return (kind, cmd.w, cmd.h)
        }
    }

    func testClippedTextEmitsAScissorTheSizeOfTheFrame() throws {
        let commands = try emit(
            Text(Self.long)
                .frame(width: .pt(40), height: .pt(22))
                .clipped()
        )
        let clips = commands.filter { $0.kind == .pushClip }
        XCTAssertEqual(clips.count, 1, "clipped text should scissor its own glyphs")
        XCTAssertEqual(clips[0].w, 40, accuracy: 0.5)
        XCTAssertEqual(clips[0].h, 22, accuracy: 0.5)
        XCTAssertTrue(commands.contains { $0.kind == .popClip })
        if let clipAt = commands.firstIndex(where: { $0.kind == .pushClip }),
           let textAt = commands.firstIndex(where: { $0.kind == .text }),
           let popAt = commands.firstIndex(where: { $0.kind == .popClip })
        {
            XCTAssertLessThan(clipAt, textAt)
            XCTAssertLessThan(textAt, popAt)
        } else {
            XCTFail("expected pushClip, text, popClip in that order")
        }
    }

    func testUnclippedTextDoesNotScissor() throws {
        let commands = try emit(
            Text(Self.long).frame(width: .pt(40), height: .pt(22))
        )
        XCTAssertFalse(commands.contains { $0.kind == .pushClip })
    }

    /// `lineLimit(1)` in a short frame used to keep the whole string:
    /// Yoga skips measure when width *and* height are set, so the
    /// ellipsis never ran and the glyphs painted past the box.
    func testLineLimitEllipsizesASingleOverflowingLine() throws {
        let full = "Give Life Back to Music"
        let commands = try emit(
            Text(full, lineLimit: 1)
                .frame(width: .pt(80), height: .pt(22))
        )
        let texts = commands.filter { $0.kind == .text }
        XCTAssertEqual(texts.count, 1)
        // `w` on a text command is the glyph count, not the box.
        XCTAssertLessThan(texts[0].w, Float(full.count))
        XCTAssertGreaterThan(texts[0].w, 2)
    }
}
