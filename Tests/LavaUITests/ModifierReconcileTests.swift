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
}
