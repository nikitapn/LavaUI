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

        // Matching happens over UTF-8 bytes, not `String.range(of:)`.
        //
        // The obvious loop — `range(of:needle, range: start..<endIndex)` per
        // match — is quadratic twice over, and on a large buffer it does not
        // read as slow, it reads as a hang. Foundation converts that
        // `Range<String.Index>` to an `NSRange`, which measures the UTF-16
        // distance from `startIndex`; and turning each result back into a
        // character offset measured from `startIndex` again. Both are O(length)
        // per match, and "ERROR" occurs ~65,000 times in a 10 MB log.
        //
        // A byte scan plus one ordered pass to convert offsets is O(length),
        // and for the all-ASCII case — every log this ships against — the
        // conversion pass is not needed at all.
        let needleBytes = Array(needle.utf8)
        let byteHits = byteOffsets(of: needleBytes, in: haystack)
        guard !byteHits.isEmpty else { return [] }
        let needleCount = needle.count

        // One byte per character means byte offsets *are* character offsets.
        // (`"\r\n"` is two bytes and one grapheme, so this correctly rejects
        // CRLF buffers as well as non-ASCII ones.)
        if haystack.utf8.count == haystack.count {
            return byteHits.map { $0..<($0 + needleCount) }
        }

        var result: [Range<Int>] = []
        result.reserveCapacity(byteHits.count)
        var hit = 0
        var charOffset = 0
        var byteOffset = 0
        var i = haystack.startIndex
        while i < haystack.endIndex, hit < byteHits.count {
            // A byte match that starts inside a grapheme is not a match a text
            // editor can select, so it is dropped rather than reported at a
            // rounded-off offset.
            while hit < byteHits.count, byteHits[hit] < byteOffset { hit += 1 }
            if hit < byteHits.count, byteHits[hit] == byteOffset {
                result.append(charOffset..<(charOffset + needleCount))
                hit += 1
            }
            byteOffset += haystack[i].utf8.count
            charOffset += 1
            i = haystack.index(after: i)
        }
        return result
    }

    /// Non-overlapping occurrences of `needle`'s bytes, as UTF-8 offsets.
    private static func byteOffsets(of needle: [UInt8], in haystack: String) -> [Int] {
        func scan(_ buf: UnsafeBufferPointer<UInt8>) -> [Int] {
            var hits: [Int] = []
            let n = needle.count
            guard n > 0, buf.count >= n else { return hits }
            let first = needle[0]
            var i = 0
            let limit = buf.count - n
            while i <= limit {
                if buf[i] == first {
                    var k = 1
                    while k < n, buf[i + k] == needle[k] { k += 1 }
                    if k == n {
                        hits.append(i)
                        // Skip the whole match: "aa" in "aaaa" is two matches,
                        // not three — see the doc comment above.
                        i += n
                        continue
                    }
                }
                i += 1
            }
            return hits
        }

        if let hits = haystack.utf8.withContiguousStorageIfAvailable({ scan($0) }) {
            return hits
        }
        // Bridged or otherwise non-contiguous storage: one copy, then the same
        // scan. Rare enough not to be worth a second implementation.
        return Array(haystack.utf8).withUnsafeBufferPointer { scan($0) }
    }
}
