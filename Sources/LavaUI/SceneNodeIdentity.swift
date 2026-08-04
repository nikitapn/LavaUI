import Foundation

/// Hands each view node the compact id the scene graph addresses it by.
///
/// The renderer keeps state — a scroll offset, a tint's fade, an animation's
/// target — against a `uint32` the producer chooses, and it survives the
/// producer republishing its draw list. That only works if the number means
/// the same thing next frame, so what the producer needs is an id that is
/// **stable while a node lives, unique while it lives, and safe to reuse
/// after it dies**. This is that.
///
/// The first two come free: `NodeID` is already the identity reconciliation
/// preserves, so a keyed `ForEach` row keeps its `NodeID` across an insert
/// above it and a plain child keeps its across a body recompute. All this adds
/// is a dense `uint32` alongside — `NodeID` is a process-wide counter that only
/// climbs, and truncating it to 32 bits would eventually wrap onto a live node.
///
/// The third is the whole difficulty, and it is why this is not a dictionary.
///
/// ## Reuse is the hazard
///
/// An id released and immediately reissued would hand the new node whatever
/// the renderer still remembers about the old one: its scroll position, a
/// half-finished fade, a target it was still travelling toward. The symptom is
/// a fresh list that opens already scrolled, and it would be intermittent —
/// which is the kind of bug that costs a week.
///
/// So an id is not reissued until the renderer has certainly forgotten it.
/// `RenderWindow::sweepSceneState` drops a node's state after
/// `kRetainReplays` replays without drawing it; the numbers here are that
/// constant plus margin, and the two are a pair. **Changing one without the
/// other reintroduces the hazard**, which is why the relationship is written
/// down here rather than left to be noticed.
///
/// ## Emit passes, not seconds and not loop iterations
///
/// Ages are counted in emit passes, because that is the only clock on which
/// "unseen" means anything here: a node is refreshed by being *asked about*,
/// and it is only asked about while a draw list is being built.
///
/// Wall-clock would be wrong because the renderer counts replays, not seconds,
/// and the two sides must agree on how long "a while" is. Loop iterations
/// would be wrong for a sharper reason, and were: the loop wakes for input,
/// animation, agent traffic and D-Bus pumps, and most of those wakes emit
/// nothing at all. Ageing on them makes a window that is on screen and simply
/// unchanged look identical to one whose nodes have all been unmounted — so
/// every live id expires, is re-minted on the next emit, and the renderer's
/// retained state (a scroll offset, a fade, an animation target) is orphaned
/// against an id nothing refers to any more. The visible symptom is a panel
/// that silently loses its scroll position, and a list that then cannot be
/// scrolled back because the producer and the renderer no longer agree on
/// where it is.
///
/// That is why the counter is not advanced by its caller alone:
/// `advanceFrame()` is inert unless `noteEmitPass()` has recorded that
/// something was actually drawn. `ImageStore.endFrame` withholds its own clock
/// on idle iterations for the same reason — an unused-looking cache entry and
/// an unseen-looking node are the same mistake about the same silence.
public enum SceneNodeIdentity {
    /// Emit passes an unseen node keeps its id before the id is released.
    ///
    /// Matches `kRetainReplays` in `render_window.cpp`. A node absent this
    /// long has already been forgotten by the renderer, so keeping the
    /// mapping past this point buys nothing — the node would come back to an
    /// id whose state is gone either way.
    static let retentionFrames: UInt64 = 1800

    /// Further emit passes a released id waits before it can be handed out
    /// again.
    ///
    /// Pure margin. Both sides count the same events, but they do not count
    /// them at the same instant — the renderer sweeps in batches, and it
    /// replays on its own account (a tint fading, a scroll easing) between
    /// the producer's emits. Reuse is the one mistake with no visible symptom
    /// until much later, so it gets slack.
    static let quarantineFrames: UInt64 = 300

    private struct Assignment {
        var sceneID: UInt32
        var lastSeen: UInt64
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var assigned: [NodeID: Assignment] = [:]
    nonisolated(unsafe) private static var nodesBySceneID: [UInt32: NodeID] = [:]
    /// Released ids and the frame they were released on, oldest first —
    /// append at the back and take from the front, so one look at the front
    /// answers "is anything reusable yet".
    nonisolated(unsafe) private static var quarantined: [(id: UInt32, since: UInt64)] = []
    /// Ids past quarantine and available again.
    nonisolated(unsafe) private static var free: [UInt32] = []
    /// Never issued yet. Starts at 1: the renderer reads 0 as "no node".
    nonisolated(unsafe) private static var nextFresh: UInt32 = 1
    nonisolated(unsafe) private static var frame: UInt64 = 0
    /// Whether a draw list has been built since the last `advanceFrame()`.
    ///
    /// The gate that makes the clock an emit clock. Set by the emitter rather
    /// than inferred by the loop, because only the emitter knows whether a
    /// wake turned into drawing — and a caller that has to remember to check
    /// is a caller that will eventually forget.
    nonisolated(unsafe) private static var emitted = false

    /// The scene id for `node`, minting one if it has none.
    ///
    /// Also marks the node as drawn this frame, which is what keeps its id.
    /// A node stops being asked about when it stops being emitted — whether
    /// it was unmounted or merely scrolled out of a virtualized list — and
    /// that is the only signal needed. Nothing has to notice an unmount.
    public static func id(for node: NodeID) -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        if var existing = assigned[node] {
            existing.lastSeen = frame
            assigned[node] = existing
            return existing.sceneID
        }
        let sceneID = free.popLast() ?? {
            let fresh = nextFresh
            // Wrapping would collide with a live node, and there is no
            // sensible recovery — 4 billion simultaneous nodes is not a
            // situation to paper over.
            precondition(fresh != .max, "scene node ids exhausted")
            nextFresh += 1
            return fresh
        }()
        assigned[node] = Assignment(sceneID: sceneID, lastSeen: frame)
        nodesBySceneID[sceneID] = node
        return sceneID
    }

    /// Resolves renderer read-back to the view-node identity used by LavaUI.
    public static func node(for sceneID: UInt32) -> NodeID? {
        guard sceneID != 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return nodesBySceneID[sceneID]
    }

    /// Records that a draw list was built. Called once per `emitTree`.
    ///
    /// Several windows emitting in one iteration still only count as one pass:
    /// scene ids are process-wide, and counting per window would age them at N
    /// times the rate the renderer retires its own state at.
    static func noteEmitPass() {
        lock.lock()
        defer { lock.unlock() }
        emitted = true
    }

    /// Advances the frame counter and ages the tables, if anything has been
    /// drawn since the last call. Call once per loop iteration, before
    /// anything asks for an id.
    ///
    /// Safe to call on every iteration precisely because it is inert without
    /// an emit — see the note on emit passes above. Callers do not have to
    /// know which wakes drew and which did not.
    public static func advanceFrame() {
        lock.lock()
        defer { lock.unlock() }
        guard emitted else { return }
        emitted = false
        frame &+= 1

        if frame > retentionFrames {
            let cutoff = frame - retentionFrames
            for (node, assignment) in assigned where assignment.lastSeen < cutoff {
                assigned.removeValue(forKey: node)
                nodesBySceneID[assignment.sceneID] = nil
                quarantined.append((assignment.sceneID, frame))
            }
        }
        // The front is the oldest, so this stops at the first one still
        // serving its time.
        var releasable = 0
        while releasable < quarantined.count,
              frame - quarantined[releasable].since >= quarantineFrames {
            free.append(quarantined[releasable].id)
            releasable += 1
        }
        if releasable > 0 { quarantined.removeFirst(releasable) }
    }

    /// Live mappings, quarantined ids, and ids ready for reuse. For tests and
    /// for anyone wondering whether this grows without bound.
    public static var census: (assigned: Int, quarantined: Int, free: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (assigned.count, quarantined.count, free.count)
    }

    /// Forgets everything. Tests only — a process that did this while a
    /// renderer held state would reissue every id it had just given out.
    public static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        assigned.removeAll()
        nodesBySceneID.removeAll()
        quarantined.removeAll()
        free.removeAll()
        nextFresh = 1
        frame = 0
        emitted = false
    }
}
