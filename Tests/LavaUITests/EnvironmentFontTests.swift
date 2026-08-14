import Observation
import XCTest

@testable import LavaUI
import LavaMenu

/// `.font()` / `.theme()` must survive a targeted body recompute.
///
/// `MenuBarStrip` observes `openMenu`. A click dirties that node and
/// `recomputeBody` used to run with an empty environment stack, so the
/// dropdown first painted `FontStore.default` and only later picked up
/// the override — a flash of system-size type.
final class EnvironmentFontTests: XCTestCase {
    @Observable
    final class Flag {
        var n = 0
    }

    private struct Inner: View {
        let flag: Flag
        var body: some View {
            Text("count \(flag.n)")
        }
    }

    private struct Outer: View {
        let flag: Flag
        let font: UIFont
        var body: some View {
            Inner(flag: flag).font(font)
        }
    }

    private func loadFace(pixelSize: Float) throws -> UIFont {
        try XCTUnwrap(
            UIFont.loadUI(assetsRoot: LavaResources.root, pixelSize: pixelSize),
            "no UI face at \(pixelSize)px"
        )
    }

    private func firstText(_ node: any AnyViewNode) -> LeafNode? {
        if let leaf = node as? LeafNode, leaf.kind == .text { return leaf }
        if let overlay = node as? OverlayBoxNode, let root = overlay.attachment.root {
            if let hit = firstText(root) { return hit }
        }
        for child in node.childNodes {
            if let hit = firstText(child) { return hit }
        }
        return nil
    }

    private func allText(_ node: any AnyViewNode) -> [LeafNode] {
        var out: [LeafNode] = []
        collectText(node, into: &out)
        return out
    }

    private func collectText(_ node: any AnyViewNode, into out: inout [LeafNode]) {
        if let leaf = node as? LeafNode, leaf.kind == .text { out.append(leaf) }
        if let overlay = node as? OverlayBoxNode, let root = overlay.attachment.root {
            collectText(root, into: &out)
        }
        for child in node.childNodes { collectText(child, into: &out) }
    }

    func testFontOverrideSurvivesIndependentBodyRecompute() throws {
        let defaultFace = try loadFace(pixelSize: 16)
        let custom = try loadFace(pixelSize: 32)
        FontStore.default = defaultFace

        let flag = Flag()
        let scope = WindowScope(label: "env-font")
        let host = LayoutHost()
        WindowScope.withCurrent(scope) {
            host.setRoot(Outer(flag: flag, font: custom))
        }
        _ = host.calculateLayout(width: 200, height: 80)

        let before = try XCTUnwrap(firstText(try XCTUnwrap(host.rootNode)))
        XCTAssertEqual(before.font?.identity, custom.identity)
        XCTAssertNotEqual(before.font?.identity, defaultFace.identity)

        scope.pending = .none
        scope.coarseBodyDirty = false
        scope.dirtyBodyNodes.removeAll()

        flag.n = 1

        let dirty = WindowScope.withCurrent(scope) {
            ViewInvalidation.consumeDirtyBodyNodes()
        }
        XCTAssertFalse(dirty?.isEmpty ?? true, "inner composite should have been targeted")
        XCTAssertFalse(scope.coarseBodyDirty, "must not fall back to a full rebuild")
        WindowScope.withCurrent(scope) {
            for node in dirty ?? [] { node.recomputeBody() }
        }

        let after = try XCTUnwrap(firstText(try XCTUnwrap(host.rootNode)))
        XCTAssertEqual(after.text, "count 1")
        XCTAssertEqual(
            after.font?.identity, custom.identity,
            "targeted recompute dropped .font() — dropdown would flash the default face"
        )
    }

    func testMenuDropdownInheritsStripFont() throws {
        let custom = try loadFace(pixelSize: 32)
        FontStore.default = try loadFace(pixelSize: 16)

        struct Host: View {
            @State var open: MenuID? = MenuID("root")
            let font: UIFont
            var body: some View {
                MenuBarStrip(
                    model: MenuModel(menus: [
                        MenuNode(
                            id: MenuID("root"),
                            title: "Lava",
                            items: [
                                .item(MenuItemModel(id: MenuID("s"), title: "Settings…")),
                            ]
                        ),
                    ]),
                    openMenuID: $open,
                    onActivate: { _ in },
                    style: .panel()
                )
                .font(font)
            }
        }

        let host = LayoutHost()
        host.setRoot(Host(font: custom))
        _ = host.calculateLayout(width: 400, height: 200)

        let texts = allText(try XCTUnwrap(host.rootNode))
        let item = try XCTUnwrap(
            texts.first(where: { $0.text.contains("Settings") }),
            texts.map(\.text).joined(separator: ", ")
        )
        XCTAssertEqual(item.font?.identity, custom.identity)
    }
}
