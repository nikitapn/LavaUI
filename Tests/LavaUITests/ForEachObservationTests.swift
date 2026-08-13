import Observation
import XCTest

@testable import LavaUI

/// Where a `body` reads an observable decides whether it re-runs.
///
/// `ViewNode.computeBody` evaluates `view.body` inside
/// `withObservationTracking`, so only the reads that happen *while that call
/// runs* register a dependency. `ForEach` stores its content as an `@escaping`
/// closure and calls it later, when the fragment mounts or reconciles its
/// children — outside that scope. So a comparison written inside a `ForEach`
/// closure subscribes to nothing, and the view keeps drawing the old answer
/// until something else forces its body to run.
///
/// This is not hypothetical: LavaSettings' Background page picked its fit mode
/// that way, and the setting applied to the desktop while the radio button
/// stayed on the previous row. The page switcher in `SettingsChrome` carries a
/// comment about the same trap, which is reason enough to pin it down here.
final class ForEachObservationTests: XCTestCase {
    @Observable
    final class Store {
        var choice = "a"
    }

    private static let options = ["a", "b", "c"]

    /// The fix: the observable is read in `body`, and the closure only sees a
    /// captured local.
    private struct ReadsInBody: View {
        let store: Store

        var body: some View {
            let choice = store.choice
            return VStack {
                ForEach(ForEachObservationTests.options, id: \.self) { option in
                    Text(choice == option ? "[\(option)]" : option)
                }
            }
        }
    }

    /// The bug, kept so the difference is a test rather than a claim.
    private struct ReadsInClosure: View {
        let store: Store

        var body: some View {
            VStack {
                ForEach(ForEachObservationTests.options, id: \.self) { option in
                    Text(store.choice == option ? "[\(option)]" : option)
                }
            }
        }
    }

    /// Renders once, mutates the store, and reports whether the change asked
    /// for another body pass.
    private func recomputesAfterMutation<V: View>(_ make: (Store) -> V) -> Bool {
        let scope = WindowScope(label: "test")
        return WindowScope.withCurrent(scope) {
            let store = Store()
            let host = LayoutHost()
            host.setRoot(make(store))
            _ = host.calculateLayout(width: 200, height: 200)

            // Whatever the first frame raised is not what is being measured.
            scope.pending = .none
            scope.coarseBodyDirty = false
            scope.dirtyBodyNodes.removeAll()

            store.choice = "b"

            // Either signal counts: a node-targeted mark, or the coarse
            // "rebuild from the root" one. Both end in bodies running again.
            return !scope.dirtyBodyNodes.isEmpty || scope.coarseBodyDirty
                || scope.pending >= .body
        }
    }

    func testReadingInBodyRecomputesWhenTheObservableChanges() {
        XCTAssertTrue(
            recomputesAfterMutation { ReadsInBody(store: $0) },
            "A body that reads the observable itself must be told when it changes"
        )
    }

    func testReadingOnlyInsideForEachDoesNotRecompute() {
        XCTAssertFalse(
            recomputesAfterMutation { ReadsInClosure(store: $0) },
            "If this starts passing, ForEach content now runs inside the "
            + "tracking scope and the hoisting in LavaSettings is redundant "
            + "rather than load-bearing"
        )
    }
}
