import Foundation

/// Find-in-buffer: match locations plus which one is current.
///
/// Deliberately holds no reference to the buffer. Matches are recomputed when
/// asked rather than kept in sync with edits, because a stale match range is
/// worse than no match at all — it would highlight, and navigate to, text that
/// has moved.
public struct TextSearch: Equatable {
    public private(set) var query: String = ""
    public private(set) var caseSensitive: Bool = false
    /// Character offsets over the whole buffer.
    public private(set) var matches: [Range<Int>] = []
    public private(set) var currentIndex: Int?

    public init() {}

    public var isActive: Bool { !query.isEmpty }
    public var count: Int { matches.count }

    public var current: Range<Int>? {
        guard let i = currentIndex, matches.indices.contains(i) else { return nil }
        return matches[i]
    }

    /// Recomputes matches. `near` biases the initial selection to the match at
    /// or after the caret, so opening find jumps forward rather than back to
    /// the top of the buffer.
    public mutating func find(
        _ query: String, in text: String,
        caseSensitive: Bool = false, near caret: Int = 0
    ) {
        self.query = query
        self.caseSensitive = caseSensitive
        matches = Self.locate(query, in: text, caseSensitive: caseSensitive)
        currentIndex = matches.isEmpty
            ? nil
            : (matches.firstIndex { $0.lowerBound >= caret } ?? 0)
    }

    public mutating func clear() {
        query = ""
        matches = []
        currentIndex = nil
    }

    /// Wraps at the end, which is what every editor's find does.
    public mutating func next() {
        guard !matches.isEmpty else { return }
        currentIndex = ((currentIndex ?? -1) + 1) % matches.count
    }

    public mutating func previous() {
        guard !matches.isEmpty else { return }
        let i = currentIndex ?? 0
        currentIndex = (i - 1 + matches.count) % matches.count
    }

    /// Plain substring search, in character offsets.
    ///
    /// Overlapping occurrences are skipped — searching "aa" in "aaaa" yields
    /// two matches, not three, matching what editors show.
    static func locate(
        _ query: String, in text: String, caseSensitive: Bool
    ) -> [Range<Int>] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        let haystack = caseSensitive ? text : text.lowercased()
        let needle = caseSensitive ? query : query.lowercased()
        // Case folding can change length (e.g. "İ"), which would misalign every
        // offset. Fall back to case-sensitive rather than report wrong ranges.
        guard haystack.count == text.count, needle.count == query.count else {
            return caseSensitive
                ? [] : locate(query, in: text, caseSensitive: true)
        }

        var result: [Range<Int>] = []
        let needleCount = needle.count
        var start = haystack.startIndex
        while let found = haystack.range(of: needle, range: start..<haystack.endIndex) {
            let lo = haystack.distance(from: haystack.startIndex, to: found.lowerBound)
            result.append(lo..<(lo + needleCount))
            start = found.upperBound
            if start >= haystack.endIndex { break }
        }
        return result
    }
}
