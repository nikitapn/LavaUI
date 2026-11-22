import Foundation

/// PTY output waiting to be parsed, between the reader thread and the frame
/// loop.
///
/// It used to be one `MainQueue.async` per 8 KiB read, and the loop runs every
/// posted closure before it draws — so under a program that writes faster
/// than the terminal parses (`yes`, a build, `cat` of a big file) the queue
/// never ran dry, each frame waited for all of it, and the window presented a
/// few times a second while the backlog grew without bound. Here the loop
/// takes a slice per turn (`TerminalSession.ingestSlice`), and a reader that
/// gets `capacity` ahead blocks — which stops reading the PTY, which blocks
/// the program when the kernel's buffer fills. That is how a terminal is
/// supposed to slow a firehose down.
final class PtyInbox: @unchecked Sendable {
    private let condition = NSCondition()
    /// The reader's own chunks, oldest at `head`. A queue of them rather than
    /// one `Data`: `removeFirst` on a `Data` only moves its start, and with the
    /// reader appending at the other end the storage grew for as long as the
    /// inbox never ran empty — which under a firehose is forever.
    private var chunks: [Data] = []
    private var head = 0
    private var queued = 0
    private var closed = false
    /// A slice is posted to the loop or running. Exactly one at a time: the
    /// reader posting on every empty→non-empty edge while the slice also
    /// re-posted itself let copies pile up, each running its whole budget in
    /// the same drain — 70 ms turns of the loop, and the frame rate fell
    /// apart.
    private var scheduled = false
    private let capacity: Int

    init(capacity: Int = 1 << 20) {
        self.capacity = capacity
    }

    /// Reader thread. True when the caller must post a slice: none is
    /// scheduled, so nothing else would take this chunk.
    func push(_ chunk: Data) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while queued >= capacity && !closed { condition.wait() }
        if closed { return false }
        chunks.append(chunk)
        queued += chunk.count
        if scheduled { return false }
        scheduled = true
        return true
    }

    /// Frame loop, at the end of a slice. True when bytes are left and the
    /// slice must post itself again; false hands scheduling back to `push`.
    /// One decision under the lock, so a chunk pushed in between is either
    /// left for the re-post or wakes the loop itself — never neither.
    func finishSlice() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if queued > 0 && !closed { return true }
        scheduled = false
        return false
    }

    /// Frame loop. Whole chunks, about `max` bytes of them (at least one), or
    /// nil when there is nothing.
    func take(max: Int) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        guard head < chunks.count else { return nil }
        var out = chunks[head]
        head += 1
        while head < chunks.count, out.count + chunks[head].count <= max {
            out.append(chunks[head])
            head += 1
        }
        queued -= out.count
        if head == chunks.count {
            chunks.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64 {
            chunks.removeFirst(head)
            head = 0
        }
        condition.broadcast()
        return out
    }

    /// Lets a reader blocked on a full inbox go, for good.
    func close() {
        condition.lock()
        closed = true
        chunks = []
        head = 0
        queued = 0
        condition.broadcast()
        condition.unlock()
    }
}
