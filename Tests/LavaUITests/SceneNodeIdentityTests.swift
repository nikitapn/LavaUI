import XCTest

@testable import LavaUI

/// Identity tests for the numbers the scene graph addresses nodes by.
///
/// Here for the same reason `WindowScopeTests` is: pure Swift that cannot move
/// out of `LavaUI`, and subtle enough that the failure mode is silent. Nothing
/// opens a window or touches the engine.
///
/// The property under test is not "ids are unique" — a counter gives that. It
/// is that an id is never reissued while a renderer could still be holding
/// state against it, because the symptom of getting that wrong is a fresh list
/// that opens already scrolled, appearing only after a specific amount of
/// churn.
final class SceneNodeIdentityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SceneNodeIdentity.resetForTesting()
    }

    override func tearDown() {
        SceneNodeIdentity.resetForTesting()
        super.tearDown()
    }

    /// Advances `count` emit passes that draw something, but not `nodes` —
    /// what a node scrolled out of a list, or unmounted, looks like from here.
    private func idle(_ count: UInt64) {
        for _ in 0..<count {
            SceneNodeIdentity.noteEmitPass()
            SceneNodeIdentity.advanceFrame()
        }
    }

    /// Advances `count` emit passes, asking about `nodes` in each — what a
    /// view that stays on screen looks like from here.
    private func drawing(_ nodes: [NodeID], for count: UInt64) {
        for _ in 0..<count {
            SceneNodeIdentity.noteEmitPass()
            SceneNodeIdentity.advanceFrame()
            for node in nodes { _ = SceneNodeIdentity.id(for: node) }
        }
    }

    /// Advances `count` loop iterations that draw nothing at all — the app
    /// woken by input, an animation tick, a D-Bus pump or agent traffic, with
    /// its windows on screen and unchanged.
    private func parked(_ count: UInt64) {
        for _ in 0..<count { SceneNodeIdentity.advanceFrame() }
    }

    func testSameNodeKeepsItsIdAcrossFrames() {
        let node = NodeID.generate()
        let first = SceneNodeIdentity.id(for: node)
        drawing([node], for: 50)
        XCTAssertEqual(SceneNodeIdentity.id(for: node), first)
    }

    func testRendererReadbackResolvesToTheOriginalNode() {
        let node = NodeID.generate()
        let sceneID = SceneNodeIdentity.id(for: node)
        XCTAssertEqual(SceneNodeIdentity.node(for: sceneID), node)
        XCTAssertNil(SceneNodeIdentity.node(for: 0))
    }

    func testDifferentNodesNeverShareAnId() {
        let nodes = (0..<500).map { _ in NodeID.generate() }
        let ids = nodes.map { SceneNodeIdentity.id(for: $0) }
        XCTAssertEqual(Set(ids).count, nodes.count)
    }

    func testZeroIsNeverIssued() {
        // The renderer reads 0 as "no node" — see `hoveredNode_`.
        let ids = (0..<200).map { _ in SceneNodeIdentity.id(for: NodeID.generate()) }
        XCTAssertFalse(ids.contains(0))
    }

    /// A node that survives an insert above it keeps its id, because `NodeID`
    /// is what reconciliation preserves and this only follows it.
    func testIdFollowsNodeIdentityNotPosition() {
        let rows = (0..<5).map { _ in NodeID.generate() }
        let before = rows.map { SceneNodeIdentity.id(for: $0) }

        // An insert at the front: a new node, the old ones re-emitted at
        // different positions.
        let inserted = NodeID.generate()
        SceneNodeIdentity.advanceFrame()
        let insertedID = SceneNodeIdentity.id(for: inserted)
        let after = rows.map { SceneNodeIdentity.id(for: $0) }

        XCTAssertEqual(after, before)
        XCTAssertFalse(before.contains(insertedID))
    }

    func testIdIsNotReusedWhileTheRendererCouldStillHoldState() {
        let gone = NodeID.generate()
        let releasedID = SceneNodeIdentity.id(for: gone)

        // Past retention — so the mapping is gone and the id is in
        // quarantine — but short of the quarantine expiring. This is the
        // window the whole scheme exists for, so it is the window to probe:
        // stopping at exactly `retentionFrames` would leave the entry still
        // mapped and pass however the quarantine behaved.
        idle(SceneNodeIdentity.retentionFrames + 1)
        XCTAssertEqual(SceneNodeIdentity.census.assigned, 0, "still mapped")
        XCTAssertGreaterThan(
            SceneNodeIdentity.census.quarantined, 0, "not released yet")
        XCTAssertEqual(
            SceneNodeIdentity.census.free, 0, "reusable before quarantine ran")

        let fresh = (0..<20).map { _ in
            SceneNodeIdentity.id(for: NodeID.generate())
        }
        XCTAssertFalse(
            fresh.contains(releasedID),
            "an id was reissued while the renderer could still hold state for it"
        )
    }

    func testIdIsReusedOnceQuarantineHasPassed() {
        let gone = NodeID.generate()
        let releasedID = SceneNodeIdentity.id(for: gone)

        idle(SceneNodeIdentity.retentionFrames
             + SceneNodeIdentity.quarantineFrames + 2)

        XCTAssertGreaterThan(SceneNodeIdentity.census.free, 0)
        XCTAssertEqual(SceneNodeIdentity.id(for: NodeID.generate()), releasedID)
    }

    /// An app that is awake but drawing nothing must not age anything.
    ///
    /// The loop wakes far more often than it draws — input, animation ticks,
    /// D-Bus pumps, agent traffic — and on those wakes no draw list is built,
    /// so nothing asks about any node. Ageing on them made a window sitting on
    /// screen unchanged indistinguishable from one whose nodes were all
    /// unmounted: every live id expired at once and came back re-minted,
    /// orphaning the renderer's scroll offsets and fades against ids nothing
    /// referred to any more.
    func testParkedIterationsDoNotAgeWhatIsStillOnScreen() {
        let onScreen = NodeID.generate()
        let issued = SceneNodeIdentity.id(for: onScreen)

        // Far past every deadline, so this fails on the *rule* rather than on
        // a margin being a few frames short.
        parked(
            (SceneNodeIdentity.retentionFrames
             + SceneNodeIdentity.quarantineFrames) * 3
        )

        XCTAssertEqual(SceneNodeIdentity.census.assigned, 1, "expired while idle")
        XCTAssertEqual(SceneNodeIdentity.census.quarantined, 0)
        XCTAssertEqual(SceneNodeIdentity.census.free, 0)
        XCTAssertEqual(
            SceneNodeIdentity.id(for: onScreen), issued,
            "a node that never left the screen was handed a different id"
        )
    }

    /// The flip side: passes that *do* draw still age a node they leave out,
    /// so the gate cannot be satisfied by simply never ageing anything.
    func testDrawingPassesStillAgeANodeTheyOmit() {
        let gone = NodeID.generate()
        _ = SceneNodeIdentity.id(for: gone)
        idle(SceneNodeIdentity.retentionFrames + 1)
        XCTAssertEqual(SceneNodeIdentity.census.assigned, 0)
        XCTAssertGreaterThan(SceneNodeIdentity.census.quarantined, 0)
    }

    /// A node still being drawn is never released, however long it lives.
    func testDrawnNodeIsNeverReleased() {
        let kept = NodeID.generate()
        let keptID = SceneNodeIdentity.id(for: kept)

        drawing([kept], for: SceneNodeIdentity.retentionFrames
                          + SceneNodeIdentity.quarantineFrames + 100)

        XCTAssertEqual(SceneNodeIdentity.census.free, 0)
        XCTAssertEqual(SceneNodeIdentity.id(for: kept), keptID)
    }

    /// The reason this is a recycling pool and not a counter: a long-running
    /// process that churns nodes must not climb forever.
    func testChurnDoesNotGrowWithoutBound() {
        // Ten generations of a hundred nodes, each living a short while.
        for _ in 0..<10 {
            let generation = (0..<100).map { _ in NodeID.generate() }
            drawing(generation, for: 30)
            idle(SceneNodeIdentity.retentionFrames
                 + SceneNodeIdentity.quarantineFrames + 2)
        }
        let census = SceneNodeIdentity.census
        XCTAssertEqual(census.assigned, 0, "nothing is still mapped")
        // A thousand nodes passed through; if ids were never recycled the
        // pool would hold a thousand.
        XCTAssertLessThanOrEqual(
            census.free, 100,
            "ids are not being recycled — the pool grew with total churn"
        )
    }

    /// Reuse must not resurrect the old node's mapping.
    func testReusedIdBelongsOnlyToItsNewNode() {
        let old = NodeID.generate()
        let recycled = SceneNodeIdentity.id(for: old)
        idle(SceneNodeIdentity.retentionFrames
             + SceneNodeIdentity.quarantineFrames + 2)

        let new = NodeID.generate()
        XCTAssertEqual(SceneNodeIdentity.id(for: new), recycled)
        // The old node coming back is a stranger now, and must not be handed
        // the id its successor is using.
        XCTAssertNotEqual(SceneNodeIdentity.id(for: old), recycled)
    }
}
