import XCTest
@testable import LavaUI

final class EditorZoomTests: XCTestCase {
    private var editor: Editor!
    private var host: LayoutHost!
    private var text = ""
    private var zoomNotches: Float = 0

    override func setUpWithError() throws {
        editor = try XCTUnwrap(Editor.openClient(width: 320, height: 240))
        XCTAssertNotNil(FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editor))
        host = LayoutHost()
    }

    override func tearDown() {
        ScrollRouter.deliver(to: [], dx: 0, dy: 0)
        host = nil
        editor = nil
    }

    private func font(_ size: Float) throws -> UIFont {
        let base = try XCTUnwrap(FontStore.default)
        let font = try XCTUnwrap(UIFont(path: base.path, pixelSize: size))
        XCTAssertTrue(font.registerWithEngine(editor))
        return font
    }

    @discardableResult
    private func layout(font: UIFont, wraps: Bool, zoom: Bool = true) throws -> LeafNode {
        let onZoom: ((Float) -> Void)? = zoom ? { self.zoomNotches += $0 } : nil
        host.setRoot(VStack(width: .pt(320), height: .pt(240), padding: 0, spacing: 0) {
            EditorView(text: Binding(get: { self.text }, set: { self.text = $0 }),
                       font: font, wraps: wraps, visibleLines: 8, onZoom: onZoom)
                .flexGrow(1)
        })
        _ = host.calculateLayout(width: 320, height: 240)
        let root = try XCTUnwrap(host.rootNode)
        let list = DrawList(editor: editor)
        list.emitTree(root, viewportW: 320, viewportH: 240)
        func find(_ node: any AnyViewNode) -> LeafNode? {
            if let leaf = node as? LeafNode, leaf.kind == .editor { return leaf }
            return node.childNodes.lazy.compactMap { find($0) }.first
        }
        return try XCTUnwrap(find(root))
    }

    func testControlWheelZoomsEvenWhenAnEmptyDocumentCannotScroll() throws {
        let leaf = try layout(font: font(16), wraps: true)
        XCTAssertTrue(ScrollRouter.deliver(to: leaf.id, dx: 0, dy: 0.5, mods: KeyMods.control))
        XCTAssertEqual(zoomNotches, 0.5)
        XCTAssertEqual(leaf.scrollY, 0)
        XCTAssertFalse(ScrollRouter.deliver(to: leaf.id, dx: 0, dy: -1))
        XCTAssertEqual(zoomNotches, 0.5)
    }

    func testOrdinaryWheelStillScrollsAndZoomDoesNotScroll() throws {
        text = (0..<100).map { "line \($0)" }.joined(separator: "\n")
        let leaf = try layout(font: font(16), wraps: false)
        XCTAssertTrue(ScrollRouter.deliver(to: leaf.id, dx: 0, dy: -1))
        XCTAssertGreaterThan(leaf.scrollY, 0)
        let before = leaf.scrollY
        XCTAssertTrue(ScrollRouter.deliver(to: leaf.id, dx: 0, dy: 2, mods: KeyMods.control))
        XCTAssertEqual(zoomNotches, 2)
        XCTAssertEqual(leaf.scrollY, before)
    }

    func testFontChangePreservesTopTextInsideOneLongWrappedLine() throws {
        text = String(repeating: "wrapped text ", count: 500)
        let small = try font(16)
        let leaf = try layout(font: small, wraps: true)
        let rowsBefore = leaf.editing.layout.rows
        let top = rowsBefore.count / 2
        leaf.scrollY = (Float(top) + 0.25) * small.lineHeight
        let offset = rowsBefore[top].lowerBound
        leaf.editing.setCursor(leaf.editing.index(atOffset: offset + 2))
        let selection = leaf.editorPosition()

        let large = try font(24)
        try layout(font: large, wraps: true)
        XCTAssertGreaterThan(leaf.editing.layout.count, rowsBefore.count,
                             "font changes must invalidate cached wrapping at the same width")
        let newTop = Int(leaf.scrollY / large.lineHeight)
        let range = leaf.editing.layout.rows[newTop]
        XCTAssertLessThanOrEqual(range.lowerBound, offset)
        XCTAssertGreaterThan(range.upperBound, offset)
        XCTAssertEqual(leaf.scrollY / large.lineHeight - Float(newTop), 0.25, accuracy: 0.001)
        XCTAssertEqual(leaf.editorPosition().focus, selection.focus)
        XCTAssertEqual(leaf.editorPosition().anchor, selection.anchor)
    }

    func testFontChangePreservesUnwrappedLineAndFraction() throws {
        text = (0..<200).map { "line \($0)" }.joined(separator: "\n")
        let small = try font(16)
        let leaf = try layout(font: small, wraps: false)
        leaf.scrollY = 100.5 * small.lineHeight
        let large = try font(24)
        try layout(font: large, wraps: false)
        XCTAssertEqual(leaf.scrollY / large.lineHeight, 100.5, accuracy: 0.001)
    }
}
