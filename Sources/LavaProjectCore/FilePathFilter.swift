/// Indexed display paths. Matches use offsets in the original characters so
/// case folding can never move the highlight into a different glyph.
public struct FilePathFilter: Sendable {
    public struct Match: Equatable, Sendable {
        public let index: Int
        public let ranges: [Range<Int>]
    }

    public struct Results: Sendable {
        public let matches: [Match]
        public let total: Int
    }

    private struct Path: Sendable {
        let name: String
        let letters: [String]
        let starts: [Bool]
        let filename: Int

        init(_ text: String) {
            name = text
            let chars = Array(text)
            letters = chars.map { $0.lowercased() }
            starts = chars.indices.map { $0 == 0 || !(chars[$0 - 1].isLetter || chars[$0 - 1].isNumber) }
            filename = chars.lastIndex(of: "/").map { $0 + 1 } ?? 0
        }

        func match(_ word: [String], from start: Int) -> (indices: [Int], contiguous: Bool)? {
            guard word.count <= letters.count - start else { return nil }
            var substring: Int?
            for offset in start...(letters.count - word.count) where letters[offset] == word[0] {
                guard letters[offset..<(offset + word.count)].elementsEqual(word) else { continue }
                if starts[offset] { return (Array(offset..<(offset + word.count)), true) }
                if substring == nil { substring = offset }
            }
            if let offset = substring { return (Array(offset..<(offset + word.count)), true) }

            // Work backwards first to see how late each letter can land.
            // Preferring an initial must not skip the only viable match.
            var end = letters.count
            var last = Array(repeating: 0, count: word.count)
            for i in word.indices.reversed() {
                guard let offset = letters[start..<end].lastIndex(of: word[i]) else { return nil }
                last[i] = offset
                end = offset
            }

            var hits: [Int] = []
            var next = start
            for i in word.indices {
                let choices = next...last[i]
                let offset = choices.first { starts[$0] && letters[$0] == word[i] }
                    ?? choices.first { letters[$0] == word[i] }!
                hits.append(offset)
                next = offset + 1
            }
            return (hits, false)
        }
    }

    private let paths: [Path]

    public init(_ paths: [String]) {
        self.paths = paths.map(Path.init)
    }

    /// Every word must match. An exact path completes itself. Otherwise
    /// prefer basename matches, uninterrupted runs and initials. Keep
    /// empty queries in the caller's listing order.
    public func rank(_ query: String, limit: Int = .max) -> Results {
        let words = query.split(whereSeparator: \.isWhitespace).map { $0.map { $0.lowercased() } }
        guard !words.isEmpty else {
            return Results(matches: paths.indices.prefix(limit).map { Match(index: $0, ranges: []) },
                           total: paths.count)
        }

        let characterCount = words.reduce(0) { $0 + $1.count }
        var scored: [(index: Int, score: (Int, Int, Int, Int, Int, Int), hits: [Int])] = []
        for (index, path) in paths.enumerated() {
            var filenames = 0, contiguous = 0, initials = 0, gaps = 0
            var hits: [Int] = []
            for word in words {
                let inName = path.match(word, from: path.filename)
                guard let match = inName ?? (path.filename == 0 ? nil : path.match(word, from: 0)) else { break }
                if inName != nil { filenames += 1 }
                if match.contiguous { contiguous += 1 }
                initials += match.indices.filter { path.starts[$0] }.count
                gaps += match.indices.last! - match.indices.first! + 1 - word.count
                hits += match.indices
            }
            if hits.count == characterCount {
                scored.append((index, (query == path.name ? 1 : 0, filenames, contiguous, initials, -gaps, -path.letters.count), hits))
            }
        }
        scored.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        let matches = scored.prefix(limit).map { item in
            var ranges: [Range<Int>] = []
            for index in Set(item.hits).sorted() {
                if let last = ranges.last, last.upperBound == index {
                    ranges[ranges.count - 1] = last.lowerBound..<(index + 1)
                } else {
                    ranges.append(index..<(index + 1))
                }
            }
            return Match(index: item.index, ranges: ranges)
        }
        return Results(matches: matches, total: scored.count)
    }
}
