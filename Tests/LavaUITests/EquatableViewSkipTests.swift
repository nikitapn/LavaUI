import Observation
import XCTest

@testable import LavaUI

/// An `Equatable` view handed an equal value keeps the subtree it has and
/// runs no body — and still runs again whenever anything it depends on, or
/// anything below it depends on, has changed.
final class EquatableViewSkipTests: XCTestCase {
    @Observable
    final class Store {
        var rowNote = "r"
        var leafNote = "l"
    }

    nonisolated(unsafe) static var rowBodies = 0
    nonisolated(unsafe) static var leafBodies = 0

    /// Not `Equatable`: below a row, so it is reached only if the row runs.
    private struct Leaf: View {
        let store: Store
        var body: some View {
            EquatableViewSkipTests.leafBodies += 1
            return Text(store.leafNote)
        }
    }

    private struct Row: View, Equatable {
        static func == (a: Row, b: Row) -> Bool { a.store === b.store && a.value == b.value }
        let store: Store
        let value: Int
        var body: some View {
            EquatableViewSkipTests.rowBodies += 1
            return VStack {
                Text("\(value) \(store.rowNote)")
                Leaf(store: store)
            }
        }
    }

    private struct Root: View {
        let store: Store
        let values: [Int]
        var body: some View {
            VStack {
                ForEach(values, id: \.self) { Row(store: store, value: $0) }
            }
        }
    }

    private var scope: WindowScope!
    private var host: LayoutHost!
    private var store: Store!

    override func setUp() {
        scope = WindowScope(label: "test")
        host = LayoutHost()
        store = Store()
        Self.rowBodies = 0
        Self.leafBodies = 0
    }

    /// One frame's body work, the way `LavaWindow.renderFrame` does it: a
    /// coarse mark rebuilds from the root with `values`.
    private func frame(_ values: [Int]) {
        WindowScope.withCurrent(scope) {
            ViewInvalidation.runBodyWork { host.setRoot(Root(store: store, values: values)) }
        }
    }

    private func coarse() {
        WindowScope.withCurrent(scope) { ViewInvalidation.markDirty() }
    }

    private func counts() -> (rows: Int, leaves: Int) {
        defer { Self.rowBodies = 0; Self.leafBodies = 0 }
        return (Self.rowBodies, Self.leafBodies)
    }

    func testAnEqualValueRunsNoBody() {
        coarse(); frame([1, 2, 3])
        XCTAssertEqual(counts().rows, 3)

        coarse(); frame([1, 2, 3])
        XCTAssertEqual(counts().rows, 0, "every row was handed the value it already had")

        coarse(); frame([1, 2, 4])
        // 4 is a new row, mounted; 1 and 2 are unchanged.
        XCTAssertEqual(counts().rows, 1)
    }

    func testARowWhoseOwnReadChangedRunsAgain() {
        coarse(); frame([1, 2])
        _ = counts()

        WindowScope.withCurrent(scope) { store.rowNote = "changed" }
        // A coarse pass on top of the targeted marks: the rebuild reaches the
        // rows with equal values, and must not skip them.
        coarse(); frame([1, 2])
        XCTAssertEqual(counts().rows, 2)

        coarse(); frame([1, 2])
        XCTAssertEqual(counts().rows, 0, "and once it has run, it is clean again")
    }

    func testAChangeBelowASkippedRowIsNotLost() {
        coarse(); frame([1, 2])
        _ = counts()

        WindowScope.withCurrent(scope) { store.leafNote = "changed" }
        coarse(); frame([1, 2])
        let c = counts()
        XCTAssertEqual(c.rows, 0, "the rows' own inputs did not change")
        XCTAssertEqual(c.leaves, 2, "the leaves were named dirty and the rebuild did not reach them")
    }

    func testATargetedPassStillWorks() {
        coarse(); frame([1, 2])
        _ = counts()

        WindowScope.withCurrent(scope) { store.leafNote = "changed" }
        frame([1, 2])
        XCTAssertEqual(counts().leaves, 2)
    }

    func testAThemeChangeRunsEveryBody() {
        coarse(); frame([1, 2])
        _ = counts()

        let saved = Theme.current
        defer { Theme.current = saved }
        WindowScope.withCurrent(scope) {
            Theme.current = saved == .paper ? .dark : .paper
        }
        frame([1, 2])
        XCTAssertEqual(counts().rows, 2, "the look is a global no row observes")
    }

    func testAnEnvironmentOverrideChangeRunsTheBody() {
        let paper = Theme.paper, dark = Theme.dark
        func build(_ theme: Theme) {
            WindowScope.withCurrent(scope) {
                ViewInvalidation.markDirty()
                ViewInvalidation.runBodyWork {
                    host.setRoot(Root(store: store, values: [1]).theme(theme))
                }
            }
        }
        build(paper)
        _ = counts()
        build(paper)
        XCTAssertEqual(counts().rows, 0)
        build(dark)
        XCTAssertEqual(counts().rows, 1)
    }
}
