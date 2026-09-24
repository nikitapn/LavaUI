import CxxCanvas
import XCTest

@testable import LavaUI

/// What a `lineLimit` text shows when its box is narrower than it — and,
/// more to the point, when it is not.
///
/// Two ways a label grew an ellipsis it had room for, both found by dragging
/// a column edge in LavaExplorer, which sweeps a text through every width:
/// `ellipsized` returned the *whole* text with "…" appended whenever that
/// fitted, and a box's lines were the last measure's rather than the box's.
final class EllipsisTests: XCTestCase {
    private var editor: Editor?

    private func font() throws -> UIFont {
        let editor = try XCTUnwrap(
            Editor.openClient(width: 200, height: 60), "client engine failed to open"
        )
        self.editor = editor
        XCTAssertNotNil(
            FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editor)
        )
        return try XCTUnwrap(FontStore.default)
    }

    private let samples = [
        "NIKITA PENNIE - odgovor banke.pdf", "2026-09-11 19:25", "21 bytes",
        "PER007787_Nikita_Pennie_202607PLATA.pdf", "a photo.jpg", ".bash_profile",
    ]

    func testAnEllipsisAlwaysReplacesSomething() throws {
        let font = try font()
        for text in samples {
            let natural = font.shapedRun(text).width
            var width = natural + 12
            while width >= font.shapedRun("…").width {
                let shown = font.ellipsized(text, availWidth: width)
                if shown.hasSuffix("…") {
                    XCTAssertNotEqual(
                        shown, text + "…",
                        "\(text) at \(width): the whole text and an ellipsis"
                    )
                    XCTAssertLessThanOrEqual(font.shapedRun(shown).width, width)
                } else {
                    XCTAssertEqual(shown, text)
                    XCTAssertLessThanOrEqual(natural, width)
                }
                width -= 0.5
            }
        }
    }

    /// A row laid out the way LavaExplorer's is — a growing name beside a
    /// column whose width changes — narrowed, then widened again.
    private func row(_ text: String, column: Float) -> some View {
        HStack(width: .pt(400), alignment: .center, spacing: 0) {
            Text(text, lineLimit: 1).flexGrow(1).flexShrink(1)
            Spacer(flexGrow: 0).frame(width: .pt(column), height: .pt(10))
        }
    }

    private func lines(of text: String, columns: [Float]) throws -> [String] {
        let host = LayoutHost()
        for column in columns {
            host.setRoot(row(text, column: column))
            _ = host.calculateLayout(width: 400, height: 40)
        }
        let leaf = try XCTUnwrap(firstText(host.rootNode))
        return leaf.linesForBox(
            contentWidth: leaf.boxWidth - leaf.padding.leading - leaf.padding.trailing
        )
    }

    func testABoxThatGrewShowsTheWholeText() throws {
        _ = try font()
        for text in samples {
            XCTAssertEqual(try lines(of: text, columns: [340, 40]), [text], text)
        }
    }

    func testABoxThatShrankIsCutToIt() throws {
        let font = try font()
        for text in samples where font.shapedRun(text).width > 60 {
            let shown = try lines(of: text, columns: [40, 340])
            XCTAssertEqual(shown.count, 1)
            XCTAssertTrue(shown[0].hasSuffix("…"), "\(text) → \(shown[0])")
            XCTAssertLessThanOrEqual(font.shapedRun(shown[0]).width, 60)
        }
    }

    func testAOneLineTextIsCutByCharacterNotByWord() throws {
        let font = try font()
        let text = "a photo.jpg"
        let room = font.shapedRun(text).width - 4
        let host = LayoutHost()
        host.setRoot(
            HStack(width: .pt(room + 8), alignment: .center, spacing: 0) {
                Text(text, lineLimit: 1).flexGrow(1).flexShrink(1)
            }
        )
        _ = host.calculateLayout(width: room + 8, height: 40)
        let leaf = try XCTUnwrap(firstText(host.rootNode))
        let shown = leaf.linesForBox(
            contentWidth: leaf.boxWidth - leaf.padding.leading - leaf.padding.trailing
        )
        XCTAssertEqual(shown.count, 1)
        XCTAssertGreaterThan(shown[0].count, "a photo".count, "cut at the space: \(shown)")
    }

    private func firstText(_ node: (any AnyViewNode)?) -> LeafNode? {
        guard let node else { return nil }
        if let leaf = node as? LeafNode, leaf.kind == .text { return leaf }
        for child in node.childNodes {
            if let hit = firstText(child) { return hit }
        }
        return nil
    }
}
