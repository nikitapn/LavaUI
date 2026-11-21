import XCTest
@testable import LavaUI

/// The debug structure dump (`LAVAUI_DEBUG=1`) of a root view.
final class StructureDumpTests: XCTestCase {
    private struct Composite: View {
        var body: some View { Text("inside") }
    }

    /// Generic, as `LavaWindow` holds its root: the call must reach each
    /// view's own `structureLines(indent:)`, not the composite default that
    /// walks `body` — which traps on a primitive.
    private func dump<Root: View>(_ root: Root) -> [String] {
        root.rootStructureLines()
    }

    func testPrimitiveRootUsesItsOwnDump() {
        let lines = dump(Composite().theme(.paper))
        XCTAssertEqual(lines.first?.trimmingCharacters(in: .whitespaces), "Composite")
        XCTAssertTrue(lines.contains { $0.contains("Text") })
    }

    func testCompositeRootStillListsItsBody() {
        let lines = dump(Composite())
        XCTAssertEqual(lines.count, 2)
    }
}
