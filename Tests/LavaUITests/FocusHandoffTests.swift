import XCTest

@testable import LavaUI

/// Focus moving between a container and a field inside it — the shape of a
/// rename in place in a focusable list.
final class FocusHandoffTests: XCTestCase {
    override func tearDown() {
        FocusManager.clear()
        super.tearDown()
    }

    private final class Flag: @unchecked Sendable { var value = false }

    /// One change that sets one flag to `false` and another to `true` moves
    /// the keyboard to the second, whatever order the flags are stored in.
    func testAHandoffBetweenTwoFlagsLandsOnTheOneThatAsked() {
        // Fresh ids each round, so the registry's order varies.
        for _ in 0..<32 {
            let field = NodeID.generate(), list = NodeID.generate()
            let fieldFlag = Flag(), listFlag = Flag()
            for id in [field, list] {
                FocusTargets.register(id) {
                    FocusManager.focus(id, onKey: { _ in false }, onChar: { _ in false })
                }
            }
            FocusBindings.register(field, Binding(get: { fieldFlag.value }, set: { fieldFlag.value = $0 }))
            FocusBindings.register(list, Binding(get: { listFlag.value }, set: { listFlag.value = $0 }))
            defer {
                FocusTargets.unregisterAll(ids: [field, list])
                FocusBindings.unregisterAll(ids: [field, list])
            }

            fieldFlag.value = true
            FocusBindings.sync(in: WindowScope.currentOrMain)
            XCTAssertEqual(FocusManager.focusedID, field)

            fieldFlag.value = false
            listFlag.value = true
            FocusBindings.sync(in: WindowScope.currentOrMain)
            XCTAssertEqual(FocusManager.focusedID, list)
            XCTAssertTrue(listFlag.value)
            XCTAssertFalse(fieldFlag.value)
        }
    }

    /// A press on a field inside a focusable view is the field's: the view
    /// does not take focus in between. A press beside the field is the view's.
    func testAPressOnAFieldInsideAFocusableViewIsLeftToTheField() throws {
        var text = "name"
        let host = LayoutHost()
        host.setRoot(
            VStack(spacing: 0) {
                TextField(text: Binding(get: { text }, set: { text = $0 }))
                    .frame(width: .pt(200), height: .pt(30))
                Spacer().frame(height: .pt(100))
            }
            .focusable(onKey: { _ in false })
        )
        _ = host.calculateLayout(width: 300, height: 200)

        XCTAssertNil(host.focusTarget(x: 50, y: 15))
        XCTAssertNotNil(host.focusTarget(x: 50, y: 120))
    }
}
