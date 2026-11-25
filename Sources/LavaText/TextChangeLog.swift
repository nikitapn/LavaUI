/// One splice of a buffer, in UTF-8 bytes: `removedLength` bytes at `offset`
/// were replaced by `inserted`.
///
/// What a consumer that keeps its own copy of the buffer's structure — a
/// syntax tree — needs in order to follow an edit instead of re-reading the
/// whole buffer. The removed text itself is not kept: a tree only needs to
/// know how much went, and `TextEdit` already holds it for undo.
public struct TextChange: Equatable, Sendable {
    public let offset: Int
    public let removedLength: Int
    public let inserted: String

    public init(offset: Int, removedLength: Int, inserted: String) {
        self.offset = offset
        self.removedLength = removedLength
        self.inserted = inserted
    }
}

/// The splices that took a buffer from one revision to the next, newest last.
///
/// Bounded, and allowed to forget: a consumer asks for the changes since the
/// revision it last saw, and nil means "not on record — read the buffer whole".
/// That answer is always correct, so the log can drop history whenever keeping
/// it would cost too much — a replacement of the whole buffer, a burst of more
/// edits than anyone reads between, an inserted text larger than the budget.
public struct TextChangeLog: Equatable {
    /// More edits than an Enter is ever this far behind.
    static let capacity = 256
    /// What the kept `inserted` strings may add up to. Past it, the oldest go.
    static let byteBudget = 1 << 20

    private struct Entry: Equatable {
        /// The revision the buffer had before this change.
        let before: UInt64
        let change: TextChange
    }

    private var entries: [Entry] = []
    private var bytes = 0

    public init() {}

    mutating func append(_ change: TextChange, before revision: UInt64) {
        let size = change.inserted.utf8.count
        guard size <= Self.byteBudget else {
            removeAll()
            return
        }
        entries.append(Entry(before: revision, change: change))
        bytes += size
        while entries.count > Self.capacity || bytes > Self.byteBudget {
            bytes -= entries.removeFirst().change.inserted.utf8.count
        }
    }

    /// Forgets everything: the buffer was replaced, not edited.
    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
        bytes = 0
    }

    /// The changes, in order, from `revision` to `current`. Empty when they
    /// are the same; nil when `revision` is not on record.
    func changes(since revision: UInt64, current: UInt64) -> [TextChange]? {
        if revision == current { return [] }
        guard let first = entries.lastIndex(where: { $0.before == revision }) else { return nil }
        return entries[first...].map(\.change)
    }
}
