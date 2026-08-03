import XCTest

@testable import LavaUI

/// Routing tests for the state that became per window.
///
/// Deliberately the only thing this target tests. LavaUI's rule is that
/// anything testable headlessly lives in `LavaText`/`LavaMenu`/`TraceLoomCore`
/// so the build graph enforces it — but the scope routing is pure Swift that
/// cannot move out of `LavaUI` (it is what `ViewInvalidation` and
/// `FocusManager` *are*), and it is subtle enough that "one window happened to
/// work" would hide a break for a long time. Nothing here opens a window,
/// loads a font or touches the engine.
final class WindowScopeTests: XCTestCase {
    private var a: WindowScope!
    private var b: WindowScope!

    override func setUp() {
        super.setUp()
        a = WindowScope(label: "a")
        b = WindowScope(label: "b")
        WindowScope.register(a)
        WindowScope.register(b)
        // A fresh scope starts owing a full `.body` pass, the way a window
        // does on its first frame. Drain that here so each test starts from
        // the steady state it is actually about.
        for scope in [a!, b!] {
            WindowScope.withCurrent(scope) {
                _ = ViewInvalidation.consumeDirtyBodyNodes()
                _ = ViewInvalidation.consume()
            }
        }
    }

    override func tearDown() {
        WindowScope.unregister(a)
        WindowScope.unregister(b)
        a = nil
        b = nil
        super.tearDown()
    }

    private func level(_ scope: WindowScope) -> InvalidationLevel {
        WindowScope.withCurrent(scope) { ViewInvalidation.level }
    }

    // ─── Invalidation routing ────────────────────────────────────────────

    func testCoarseInvalidationInsideAWindowStaysInThatWindow() {
        WindowScope.withCurrent(a) { ViewInvalidation.markNeedsRedraw() }

        XCTAssertEqual(level(a), .redraw)
        XCTAssertEqual(level(b), .none, "b was not the window being processed")
    }

    func testCoarseInvalidationOutsideAnyWindowReachesEveryWindow() {
        // A worker result or a deferred FrameTask: nothing says which window
        // cared, so over-invalidating is the only answer that is never wrong.
        ViewInvalidation.markNeedsRedraw()

        XCTAssertEqual(level(a), .redraw)
        XCTAssertEqual(level(b), .redraw)
    }

    func testConsumeClearsOnlyTheCurrentWindow() {
        ViewInvalidation.markNeedsLayout()

        let drained = WindowScope.withCurrent(a) { ViewInvalidation.consume() }

        XCTAssertEqual(drained, .layout)
        XCTAssertEqual(level(a), .none)
        XCTAssertEqual(level(b), .layout, "b's frame has not run yet")
    }

    func testLevelsRaiseButDoNotFall() {
        WindowScope.withCurrent(a) {
            ViewInvalidation.markNeedsBody()
            ViewInvalidation.markNeedsRedraw()
        }

        XCTAssertEqual(level(a), .body, "a redraw must not downgrade a body pass")
    }

    // ─── Node-targeted invalidation ──────────────────────────────────────

    /// The routing that cannot use the ambient scope: an `@Observable` model
    /// mutated by a handler in one window can be read by a node in another,
    /// and it is the reader that has to recompute.
    func testBodyDirtyRoutesToTheNodesWindowNotTheWritersWindow() {
        let nodeInB = FakeNode(scope: b)

        WindowScope.withCurrent(a) { ViewInvalidation.markBodyDirty(nodeInB) }

        XCTAssertEqual(level(b), .body, "the node's window must rebuild")
        XCTAssertEqual(level(a), .none, "the writer's window read nothing new")

        let drainedByB = WindowScope.withCurrent(b) {
            ViewInvalidation.consumeDirtyBodyNodes()
        }
        XCTAssertEqual(drainedByB?.count, 1)
        XCTAssertTrue(drainedByB?.first === nodeInB)
    }

    func testTheSameNodeMarkedTwiceIsOneEntry() {
        let node = FakeNode(scope: a)

        ViewInvalidation.markBodyDirty(node)
        ViewInvalidation.markBodyDirty(node)

        let drained = WindowScope.withCurrent(a) {
            ViewInvalidation.consumeDirtyBodyNodes()
        }
        XCTAssertEqual(drained?.count, 1)
    }

    func testCoarseInvalidationForcesAFullRebuildRatherThanNamedNodes() {
        let node = FakeNode(scope: a)
        WindowScope.withCurrent(a) {
            ViewInvalidation.markBodyDirty(node)
            // No node identity: the whole tree has to run again, and the
            // targeted list must not be handed out as if it were complete.
            ViewInvalidation.markNeedsBody()
        }

        let drained = WindowScope.withCurrent(a) {
            ViewInvalidation.consumeDirtyBodyNodes()
        }
        XCTAssertNil(drained, "nil means rebuild from the root")
    }

    // ─── Focus ───────────────────────────────────────────────────────────

    func testFocusIsPerWindow() {
        let idA = NodeID.generate()
        let idB = NodeID.generate()

        WindowScope.withCurrent(a) {
            FocusManager.focus(idA, onKey: { _ in true }, onChar: { _ in true })
        }
        WindowScope.withCurrent(b) {
            FocusManager.focus(idB, onKey: { _ in true }, onChar: { _ in true })
        }

        // Focusing in b must not have stolen a's — clicking between windows and
        // back leaves the field you were editing still focused.
        XCTAssertEqual(WindowScope.withCurrent(a) { FocusManager.focusedID }, idA)
        XCTAssertEqual(WindowScope.withCurrent(b) { FocusManager.focusedID }, idB)
    }

    func testKeysReachOnlyTheFocusedNodeOfTheirOwnWindow() {
        var aSawKey = false
        var bSawKey = false
        WindowScope.withCurrent(a) {
            FocusManager.focus(
                .generate(), onKey: { _ in aSawKey = true; return true },
                onChar: { _ in true }
            )
        }
        WindowScope.withCurrent(b) {
            FocusManager.focus(
                .generate(), onKey: { _ in bSawKey = true; return true },
                onChar: { _ in true }
            )
        }

        WindowScope.withCurrent(b) {
            _ = FocusManager.handle(KeyEvent(key: 65, mods: 0))
        }

        XCTAssertFalse(aSawKey, "a key delivered to b must not reach a's field")
        XCTAssertTrue(bSawKey)
    }

    func testClearingFocusInOneWindowLeavesTheOther() {
        let idA = NodeID.generate()
        WindowScope.withCurrent(a) {
            FocusManager.focus(idA, onKey: { _ in true }, onChar: { _ in true })
        }
        WindowScope.withCurrent(b) { FocusManager.clear() }

        XCTAssertEqual(WindowScope.withCurrent(a) { FocusManager.focusedID }, idA)
    }

    // ─── Visibility ──────────────────────────────────────────────────────

    /// The set is rebuilt from scratch on every emit, so with one shared set
    /// whichever window drew last would have erased the other's — and every
    /// animation in the window that did not just draw would stop.
    func testEmittingOneWindowDoesNotForgetAnothersVisibleNodes() {
        let inA = NodeID.generate()
        let inB = NodeID.generate()

        WindowScope.withCurrent(a) {
            NodeVisibility.beginFrame()
            NodeVisibility.mark(inA)
        }
        WindowScope.withCurrent(b) {
            NodeVisibility.beginFrame()
            NodeVisibility.mark(inB)
        }

        XCTAssertTrue(NodeVisibility.isVisible(inA, in: a))
        XCTAssertTrue(NodeVisibility.isVisible(inB, in: b))
        XCTAssertFalse(NodeVisibility.isVisible(inB, in: a), "different trees")
    }

    // ─── Ambient scope ───────────────────────────────────────────────────

    func testCurrentIsRestoredAfterNesting() {
        XCTAssertNil(WindowScope.current)
        WindowScope.withCurrent(a) {
            XCTAssertTrue(WindowScope.current === a)
            WindowScope.withCurrent(b) {
                XCTAssertTrue(WindowScope.current === b)
            }
            XCTAssertTrue(WindowScope.current === a, "nesting must not leak b")
        }
        XCTAssertNil(WindowScope.current, "the loop is between windows again")
    }

    func testCurrentIsRestoredWhenTheBodyThrows() {
        struct Boom: Error {}
        XCTAssertThrowsError(
            try WindowScope.withCurrent(a) { throw Boom() }
        )
        XCTAssertNil(WindowScope.current, "a throwing frame must not pin a scope")
    }

    func testWithNoWindowsRegisteredEverythingResolvesToMain() {
        WindowScope.unregister(a)
        WindowScope.unregister(b)
        defer {
            WindowScope.register(a)
            WindowScope.register(b)
        }
        _ = ViewInvalidation.consume()  // clears main

        ViewInvalidation.markNeedsRedraw()

        XCTAssertEqual(ViewInvalidation.level, .redraw)
        XCTAssertEqual(ViewInvalidation.consume(), .redraw)
    }
}

/// A `BodyRecomputable` that belongs to a chosen window, standing in for the
/// `CompositeNode` that captures its scope at mount.
private final class FakeNode: BodyRecomputable {
    let invalidationScope: WindowScope?
    private(set) var recomputes = 0

    init(scope: WindowScope) { invalidationScope = scope }

    func recomputeBody() { recomputes += 1 }
}
