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
/// ## Frames, not seconds
///
/// Ages are counted in emit passes rather than wall-clock, because the
/// renderer counts replays. An idle app that is not drawing is not replaying
/// either, and both sides must agree on how long "a while" is — under a clock
/// they would not, and an id could come back up for reuse while a renderer
/// that has not repainted still held the old state against it.
public enum SceneNodeIdentity {
    /// Frames an unseen node keeps its id before the id is released.
    ///
    /// Matches `kRetainReplays` in `render_window.cpp`. A node absent this
    /// long has already been forgotten by the renderer, so keeping the
    /// mapping past this point buys nothing — the node would come back to an
    /// id whose state is gone either way.
    static let retentionFrames: UInt64 = 1800

    /// Further frames a released id waits before it can be handed out again.
    ///
    /// Pure margin. Both sides count the same events, but they do not count
    /// them at the same instant — the renderer sweeps in batches, and a frame
    /// that fails to emit still ages an entry here. Reuse is the one mistake
    /// with no visible symptom until much later, so it gets slack.
    static let quarantineFrames: UInt64 = 300

    private struct Assignment {
        var sceneID: UInt32
        var lastSeen: UInt64
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var assigned: [NodeID: Assignment] = [:]
    /// Released ids and the frame they were released on, oldest first —
    /// append at the back and take from the front, so one look at the front
    /// answers "is anything reusable yet".
    nonisolated(unsafe) private static var quarantined: [(id: UInt32, since: UInt64)] = []
    /// Ids past quarantine and available again.
    nonisolated(unsafe) private static var free: [UInt32] = []
    /// Never issued yet. Starts at 1: the renderer reads 0 as "no node".
    nonisolated(unsafe) private static var nextFresh: UInt32 = 1
    nonisolated(unsafe) private static var frame: UInt64 = 0

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
        return sceneID
    }

    /// Advances the frame counter and ages the tables. Call once per emit
    /// pass, before anything asks for an id.
    ///
    /// Explicit rather than inferred from `DrawList.clear()`, because with two
    /// windows that would run twice a frame and halve every age here while the
    /// renderer's own counter — one per window — kept the original rate.
    public static func advanceFrame() {
        lock.lock()
        defer { lock.unlock() }
        frame &+= 1

        if frame > retentionFrames {
            let cutoff = frame - retentionFrames
            for (node, assignment) in assigned where assignment.lastSeen < cutoff {
                assigned.removeValue(forKey: node)
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
        quarantined.removeAll()
        free.removeAll()
        nextFresh = 1
        frame = 0
    }
}
