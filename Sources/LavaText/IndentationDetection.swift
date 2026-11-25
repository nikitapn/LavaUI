/// What a file's own leading whitespace says about how it is indented.
///
/// The configured style is a default for files that have none yet. A file
/// that already has one outranks it: a tab-indented C file or a Makefile
/// edited with "insert spaces" would otherwise grow a second style one Enter
/// at a time, and in a Makefile that is a broken recipe, not a cosmetic issue.
public struct DetectedIndentation: Equatable, Sendable {
    public var insertSpaces: Bool
    /// Spaces per level, when the file indents with spaces and its steps agree
    /// on one. Nil for tabs: how wide a tab is, the bytes don't say.
    public var tabSize: Int?

    public init(insertSpaces: Bool, tabSize: Int?) {
        self.insertSpaces = insertSpaces
        self.tabSize = tabSize
    }

    /// Nil when no line is indented, which is no evidence either way.
    ///
    /// Tabs and spaces are decided by which more lines begin with. The width
    /// of a level is the most common step between consecutive indented lines,
    /// counting only steps of 2–8: a step of 1 is alignment, not a level. On a
    /// tie the smaller step wins, because in a 2-space file the 4s are mostly
    /// double dedents. Lines that start with `*` are skipped — a block
    /// comment's continuation sits one space off its opener.
    ///
    /// Reads at most `lineLimit` lines, so opening a large file costs a scan
    /// of its head and not of all of it.
    public static func detect(in text: String, lineLimit: Int = 10_000) -> DetectedIndentation? {
        let utf8 = text.utf8
        var index = utf8.startIndex
        var tabLines = 0
        var spaceLines = 0
        var steps = [Int](repeating: 0, count: 9)
        // Spaces on the last line that counted; nil after a line that tells
        // us nothing about a space step (tab-led, mixed).
        var previous: Int? = 0
        var lines = 0
        while index < utf8.endIndex, lines < lineLimit {
            lines += 1
            var spaces = 0
            var tabs = 0
            var startsWithTab = false
            var first: UInt8?
            while index < utf8.endIndex {
                let byte = utf8[index]
                if byte == 0x20 {
                    spaces += 1
                } else if byte == 0x09 {
                    if spaces == 0, tabs == 0 { startsWithTab = true }
                    tabs += 1
                } else {
                    first = byte
                    break
                }
                index = utf8.index(after: index)
            }
            if let newline = utf8[index...].firstIndex(of: 0x0a) {
                index = utf8.index(after: newline)
            } else {
                index = utf8.endIndex
            }
            // Blank lines say nothing, and must not reset the step either:
            // a paragraph break inside a block is not a dedent to column 0.
            guard let first, first != 0x0a, first != 0x0d else { continue }
            if first == UInt8(ascii: "*") { continue }
            if startsWithTab {
                tabLines += 1
                previous = nil
                continue
            }
            guard tabs == 0 else {
                previous = nil
                continue
            }
            if spaces > 0 { spaceLines += 1 }
            if let previous {
                let step = abs(spaces - previous)
                if (2...8).contains(step) { steps[step] += 1 }
            }
            previous = spaces
        }
        guard tabLines > 0 || spaceLines > 0 else { return nil }
        if tabLines > spaceLines { return .init(insertSpaces: false, tabSize: nil) }
        let best = (2...8).max { steps[$0] < steps[$1] || (steps[$0] == steps[$1] && $0 > $1) }!
        return .init(insertSpaces: true, tabSize: steps[best] > 0 ? best : nil)
    }
}
