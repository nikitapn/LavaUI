/// Turning what a server says into what an editor shows: the completion list
/// as the user narrows it, and a hover reply as lines for a card. Kept here,
/// beside the models, so it is tested without an editor.

public enum CompletionRanking {
    /// The items worth showing for `prefix` — the word typed so far — best
    /// first, at most `limit`, as indices into `items`.
    ///
    /// Three tiers, as editors have converged on: the typed text exactly
    /// starting the candidate, then starting it ignoring case, then appearing
    /// in it in order (`fbz` finds `fooBarBaz`) as long as the first character
    /// matches. Within a tier the server's `sortText` decides, which is how it
    /// says that a local variable beats a global of the same name.
    public static func rank(_ items: [CompletionItem], prefix: String, limit: Int = 200) -> [Int] {
        let typed = Array(prefix.lowercased())
        var scored: [(tier: Int, key: String, length: Int, index: Int)] = []
        scored.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let candidate = item.filterText ?? item.label
            let tier: Int
            if prefix.isEmpty || candidate.hasPrefix(prefix) {
                tier = 0
            } else if candidate.lowercased().hasPrefix(String(typed)) {
                tier = 1
            } else if isSubsequence(typed, of: Array(candidate.lowercased())) {
                tier = 2
            } else {
                continue
            }
            scored.append((tier, item.sortText ?? item.label, item.label.count, index))
        }
        scored.sort {
            if $0.tier != $1.tier { return $0.tier < $1.tier }
            if $0.key != $1.key { return $0.key < $1.key }
            return $0.length < $1.length
        }
        return scored.prefix(limit).map(\.index)
    }

    private static func isSubsequence(_ needle: [Character], of haystack: [Character]) -> Bool {
        guard let first = needle.first, haystack.first == first else { return false }
        var at = haystack.startIndex
        for character in needle {
            guard let found = haystack[at...].firstIndex(of: character) else { return false }
            at = found + 1
        }
        return true
    }

    /// A short mark for an item's `CompletionItemKind`, or nil for none.
    public static func glyph(forKind kind: Int?) -> String? {
        switch kind {
        case 2: return "m"      // method
        case 3: return "f"      // function
        case 4: return "c"      // constructor
        case 5, 10: return "p"  // field, property
        case 6: return "v"      // variable
        case 7: return "C"      // class
        case 8: return "I"      // interface / protocol
        case 9: return "M"      // module
        case 13: return "E"     // enum
        case 14: return "k"     // keyword
        case 15: return "s"     // snippet
        case 20: return "e"     // enum member
        case 21: return "K"     // constant
        case 22: return "S"     // struct
        case 25: return "T"     // type parameter
        case nil: return nil
        default: return "·"
        }
    }
}

public enum HoverPresentation {
    public struct Line: Equatable, Sendable {
        public let text: String
        public let isCode: Bool

        public init(_ text: String, isCode: Bool) {
            self.text = text
            self.isCode = isCode
        }
    }

    /// A hover reply as card lines: code kept as written and never wrapped,
    /// prose wrapped at `width` characters, rules and runs of blank lines
    /// dropped, and at most `maxLines` with an ellipsis when cut.
    ///
    /// A part with a language is code up to its first blank line — the
    /// signature — and prose after: how servers lay out "the declaration,
    /// then its documentation" once the Markdown around it is gone.
    public static func lines(_ hover: LSPHover, width: Int = 80, maxLines: Int = 18) -> [Line] {
        var out: [Line] = []
        for content in hover.contents {
            if !out.isEmpty { out.append(Line("", isCode: false)) }
            var inCode = content.language != nil
            for raw in content.text.components(separatedBy: "\n") {
                let line = raw.replacingOccurrences(of: "\t", with: "    ")
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    inCode = false
                    if out.last?.text.isEmpty == false { out.append(Line("", isCode: false)) }
                    continue
                }
                if trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), trimmed.count >= 3 { continue }
                if inCode {
                    out.append(Line(line, isCode: true))
                } else {
                    out += wrap(trimmed, width: width).map { Line($0, isCode: false) }
                }
            }
        }
        while out.last?.text.isEmpty == true { out.removeLast() }
        if out.count > maxLines {
            out = Array(out.prefix(maxLines - 1)) + [Line("…", isCode: false)]
        }
        return out
    }

    static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}

/// A completion's snippet as plain text and where the caret goes in it.
///
/// No tab stops to step through yet, so placeholders are inserted empty —
/// `foo(${1:a}, ${2:b})` becomes `foo(, )` — and the caret lands on the
/// first one (the lowest number from 1, else `$0`, else the end). Escapes
/// (`\$`, `\}`, `\\`) come out as the character; choices (`${1|a,b|}`)
/// and variables (`$TM_FILENAME`) come out empty.
public enum SnippetText {
    public static func expand(_ snippet: String) -> (text: String, caret: Int) {
        var text = ""
        var count = 0
        var stops: [Int: Int] = [:]
        let characters = Array(snippet)
        var i = 0
        let depth = 0
        func record(_ number: Int) {
            if stops[number] == nil { stops[number] = count }
        }
        while i < characters.count {
            let c = characters[i]
            if c == "\\", i + 1 < characters.count, "$}\\".contains(characters[i + 1]) {
                if depth == 0 { text.append(characters[i + 1]); count += 1 }
                i += 2
                continue
            }
            if c == "$", i + 1 < characters.count {
                let next = characters[i + 1]
                if next.isNumber {
                    var j = i + 1
                    var number = 0
                    while j < characters.count, let digit = characters[j].wholeNumberValue {
                        number = number * 10 + digit
                        j += 1
                    }
                    if depth == 0 { record(number) }
                    i = j
                    continue
                }
                if next == "{" {
                    var j = i + 2
                    var number = 0
                    var numbered = false
                    while j < characters.count, let digit = characters[j].wholeNumberValue {
                        number = number * 10 + digit
                        numbered = true
                        j += 1
                    }
                    if numbered, depth == 0 { record(number) }
                    // Skip the placeholder's default, choices or variable name,
                    // nested placeholders included.
                    var nesting = 1
                    while j < characters.count, nesting > 0 {
                        if characters[j] == "\\" { j += 2; continue }
                        if characters[j] == "{" { nesting += 1 }
                        if characters[j] == "}" { nesting -= 1 }
                        j += 1
                    }
                    i = j
                    continue
                }
                if next.isLetter || next == "_" {
                    var j = i + 1
                    while j < characters.count, characters[j].isLetter || characters[j].isNumber || characters[j] == "_" {
                        j += 1
                    }
                    i = j
                    continue
                }
            }
            if depth == 0 { text.append(c); count += 1 }
            i += 1
        }
        let first = stops.keys.filter { $0 > 0 }.min()
        let caret = first.flatMap { stops[$0] } ?? stops[0] ?? count
        return (text, caret)
    }
}
