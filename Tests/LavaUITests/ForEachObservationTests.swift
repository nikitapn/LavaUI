import Observation
import XCTest

@testable import LavaUI

/// A `ForEach` row must react to an observable however the read is spelled.
///
/// `ViewNode.computeBody` evaluates `view.body` inside
/// `withObservationTracking`, so a read registers a dependency only if it
/// happens while that call runs. `ForEach` used to store its content as an
/// `@escaping` closure and call it at mount time, outside that scope — so a
/// comparison written inside the closure subscribed to nothing and the row
/// kept drawing the old answer. LavaSettings shipped that on its Background
/// page: the wallpaper changed and the radio button stayed put.
///
/// `ForEach` now builds its children in `init`, which runs during the parent's
/// body, so both spellings register. Both cases below are kept deliberately:
/// the second is the one that used to fail, and it is the reason the type is
/// eager rather than lazy. If it ever regresses, that is the signal.
final class ForEachObservationTests: XCTestCase {
    @Observable
    final class Store {
        var choice = "a"
    }

    private static let options = ["a", "b", "c"]

    /// The read hoisted into `body`; the closure sees a captured local.
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

    /// The read left inside the closure — the spelling that used to subscribe
    /// to nothing, and the one a person writes without thinking about it.
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

    func testReadingInsideForEachAlsoRecomputes() {
        XCTAssertTrue(
            recomputesAfterMutation { ReadsInClosure(store: $0) },
            "ForEach builds its children in `init`, during the parent body, so "
            + "a read inside the closure registers there too. If this fails, "
            + "ForEach has gone back to deferring its content and every list "
            + "row that compares against observable state is silently stale."
        )
    }
}
