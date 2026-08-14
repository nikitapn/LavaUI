import XCTest

@testable import LavaUI

/// `.background()` on a named view wraps in a `StyleBox`. A paint-less
/// modifier stacked on top (`.hidden()`, `.windowChrome()`) used to claim
/// that box on the next reconcile and insert a Yoga child that still had
/// an owner — fatal in `YGNodeInsertChild`. LavaTerm hit this on the
/// second body pass after `SubscribeSystemTheme` dirtied the tree.
final class ModifierReconcileTests: XCTestCase {
    private struct Named: View {
        var body: some View { Text("x") }
    }

    func testBackgroundThenHiddenSurvivesASecondSetRoot() {
        let host = LayoutHost()
        let tree = VStack {
            Named()
                .background(Color(r: 1, g: 0, b: 0))
                .hidden(false)
        }
        host.setRoot(tree)
        _ = host.calculateLayout(width: 80, height: 40)
        host.setRoot(tree)
        let frames = host.calculateLayout(width: 80, height: 40)
        XCTAssertFalse(frames.isEmpty)
    }

    /// An in-window menubar applies `.flexGrow(1)` to application content.
    /// Because a composite has no Yoga node that modifier creates a wrapper;
    /// the wrapper must remain owned by the same modifier on the next body
    /// pass or the whole application subtree — including focused editors —
    /// is remounted.
    func testPaintlessModifierKeepsCompositeContentIdentity() throws {
        let host = LayoutHost()
        let tree = Named().flexGrow(1)

        host.setRoot(tree)
        _ = host.calculateLayout(width: 80, height: 40)
        let firstText = try XCTUnwrap(findText(in: host.rootNode))

        host.setRoot(tree)
        _ = host.calculateLayout(width: 80, height: 40)
        let secondText = try XCTUnwrap(findText(in: host.rootNode))

        XCTAssertEqual(secondText.id, firstText.id)
    }

    private func findText(in node: (any AnyViewNode)?) -> (any AnyViewNode)? {
        guard let node else { return nil }
        if node.label.hasPrefix("Text") { return node }
        for child in node.childNodes {
            if let match = findText(in: child) { return match }
        }
        return nil
    }
}
