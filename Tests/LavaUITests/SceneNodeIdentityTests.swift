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

    /// Advances `count` frames, drawing nothing.
    private func idle(_ count: UInt64) {
        for _ in 0..<count { SceneNodeIdentity.advanceFrame() }
    }

    /// Advances `count` frames, asking about `nodes` in each — what a view
    /// that stays on screen looks like from here.
    private func drawing(_ nodes: [NodeID], for count: UInt64) {
        for _ in 0..<count {
            SceneNodeIdentity.advanceFrame()
            for node in nodes { _ = SceneNodeIdentity.id(for: node) }
        }
    }

    func testSameNodeKeepsItsIdAcrossFrames() {
        let node = NodeID.generate()
        let first = SceneNodeIdentity.id(for: node)
        drawing([node], for: 50)
        XCTAssertEqual(SceneNodeIdentity.id(for: node), first)
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
