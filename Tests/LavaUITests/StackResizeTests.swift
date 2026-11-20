import XCTest

@testable import LavaUI

/// A stack that states its own size and is told a different one later.
///
/// Modifiers replay their style over a snapshot of the node taken the first
/// time one applies (`applyViewStyle`), so a stack whose `width:` changed
/// between bodies got its mount-time width written back by the `.background`
/// on it. The panel's workspace dots are exactly this: the current one is 26
/// wide, the rest 8, and switching workspace moved the colour but not the
/// width.
final class StackResizeTests: XCTestCase {
    private func dot(_ wide: Bool) -> some View {
        HStack(padding: 0) {
            HStack(width: .pt(wide ? 26 : 8), height: .pt(8), padding: 0) {}
                .background(Color(r: 1, g: 0, b: 0))
                .cornerRadius(4)
                .agentId("dot")
            Spacer()
        }
    }

    func testAStacksOwnWidthFollowsItsBodyUnderAModifier() throws {
        let host = LayoutHost()
        host.setRoot(dot(false))
        _ = host.calculateLayout(width: 200, height: 40)
        XCTAssertEqual(try XCTUnwrap(host.agentFrame(sid: "dot")).w, 8)

        host.setRoot(dot(true))
        _ = host.calculateLayout(width: 200, height: 40)
        XCTAssertEqual(
            try XCTUnwrap(host.agentFrame(sid: "dot")).w, 26,
            "the stack kept the width it was mounted with"
        )

        host.setRoot(dot(false))
        _ = host.calculateLayout(width: 200, height: 40)
        XCTAssertEqual(try XCTUnwrap(host.agentFrame(sid: "dot")).w, 8)
    }
}
