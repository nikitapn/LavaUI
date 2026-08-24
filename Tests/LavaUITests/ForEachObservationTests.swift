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

/// Duplicate `ForEach` keys must not abort the process.
///
/// LavaSettings keyed display modes on `width×height@refresh`. DRM reports
/// 1024×768@60.004 twice, the first body pass stored both rows under that
/// id, and the second built `Dictionary(uniqueKeysWithValues:)` from it.
final class ForEachDuplicateKeyTests: XCTestCase {
    private struct List: View {
        var ids: [String]
        var titles: [String]

        var body: some View {
            VStack {
                ForEach(Array(zip(ids, titles)), id: \.0) { pair in
                    Text(pair.1)
                }
            }
        }
    }

    private func textNodes(in node: any AnyViewNode) -> [any AnyViewNode] {
        var out: [any AnyViewNode] = []
        if node.label.hasPrefix("Text") { out.append(node) }
        for child in node.childNodes {
            out.append(contentsOf: textNodes(in: child))
        }
        return out
    }

    /// The crash: mount with a repeated id, then reconcile the same list.
    func testDuplicateKeysSurviveASecondBodyPass() {
        let ids = ["1024x768@60004", "1024x768@60004"]
        let host = LayoutHost()
        host.setRoot(List(ids: ids, titles: ["a", "b"]))
        _ = host.calculateLayout(width: 200, height: 80)

        host.setRoot(List(ids: ids, titles: ["a", "b"]))
        let frames = host.calculateLayout(width: 200, height: 80)
        let texts = frames.filter { $0.label.hasPrefix("Text") }
        XCTAssertEqual(texts.count, 2, "both rows stay visible under a shared id")
    }

    /// Duplicate-id rows reuse nodes in encounter order, so a label change
    /// on the second row does not remount the first.
    func testDuplicateKeyRowsKeepIdentityInOrder() throws {
        let ids = ["1024x768@60004", "1024x768@60004"]
        let host = LayoutHost()
        host.setRoot(List(ids: ids, titles: ["a", "b"]))
        _ = host.calculateLayout(width: 200, height: 80)
        let first = textNodes(in: try XCTUnwrap(host.rootNode))
        XCTAssertEqual(first.count, 2)

        host.setRoot(List(ids: ids, titles: ["a", "c"]))
        _ = host.calculateLayout(width: 200, height: 80)
        let second = textNodes(in: try XCTUnwrap(host.rootNode))
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(first[0].id, second[0].id)
        XCTAssertEqual(first[1].id, second[1].id)
    }
}
