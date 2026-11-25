/// The parse state of one open document. Parsing is lazy and catches up
/// to the current buffer when the editor asks for indentation.
public final class IndentationProvider {
    public enum Language {
        case swift, python, c, cpp
    }

    #if canImport(SwiftParser) && canImport(SwiftSyntax)
    public static let hasSwiftParser = true
    private lazy var swift = SwiftIndentation()
    #else
    public static let hasSwiftParser = false
    #endif
    private lazy var python = PythonIndentation()
    private lazy var c = CFamilyIndentation(cpp: false)
    private lazy var cpp = CFamilyIndentation(cpp: true)

    public init() {}

    /// Nil leaves the current line's indentation in place.
    public func indentation(
        in text: String, at caret: String.Index, language: Language, unit: String = "    "
    ) -> String? {
        let offset = text.utf8.distance(from: text.utf8.startIndex, to: caret)
        switch language {
        case .swift:
            #if canImport(SwiftParser) && canImport(SwiftSyntax)
            return swift.indentation(in: text, at: offset, unit: unit)
            #else
            return nil
            #endif
        case .python:
            return python.indentation(in: text, at: offset, unit: unit)
        case .c:
            return c.indentation(in: text, at: offset, unit: unit)
        case .cpp:
            return cpp.indentation(in: text, at: offset, unit: unit)
        }
    }
}

/// A contiguous replacement from the last parsed snapshot. Multiple edits
/// between Enter presses can invalidate more than one line, so retain only
/// the unchanged prefix and suffix when reusing the tree.
struct SourceChange {
    let start: Int
    let oldEnd: Int
    let newEnd: Int

    init(from old: [UInt8], to new: [UInt8]) {
        var start = 0
        let sharedLimit = min(old.count, new.count)
        while start < sharedLimit, old[start] == new[start] { start += 1 }
        // Equal leading bytes can be part of two different Unicode scalars.
        while start < new.count, Self.isContinuation(new[start]) { start -= 1 }

        var oldEnd = old.count
        var newEnd = new.count
        while oldEnd > start, newEnd > start, old[oldEnd - 1] == new[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        while newEnd < new.count, Self.isContinuation(new[newEnd]) {
            oldEnd += 1
            newEnd += 1
        }
        self.start = start
        self.oldEnd = oldEnd
        self.newEnd = newEnd
    }

    static func isContinuation(_ byte: UInt8) -> Bool { byte & 0xc0 == 0x80 }
}

func isHorizontalSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }

func lineIndent(in bytes: [UInt8], at offset: Int) -> String {
    let start = bytes[..<offset].lastIndex(of: 0x0a).map { $0 + 1 } ?? 0
    return String(decoding: bytes[start...].prefix(while: isHorizontalSpace), as: UTF8.self)
}

func indented(_ base: String, by unit: String) -> String {
    base + (base.last == "\t" ? "\t" : unit)
}
