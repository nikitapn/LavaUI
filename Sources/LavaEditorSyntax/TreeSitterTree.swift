import Foundation
import LavaText
internal import SwiftTreeSitter
internal import TreeSitter
internal import TreeSitterC
internal import TreeSitterCPP
internal import TreeSitterPython

/// A grammar and the queries written against it.
///
/// Queries live in `Queries/<name>/*.scm`. A file whose first line is
/// `; inherits: <other>` starts with that language's file of the same name,
/// which is how C++ reuses C's rules: every C node name is also a C++ one.
final class Grammar: Sendable {
    let name: String
    let language: SwiftTreeSitter.Language
    let indents: Query?

    private init(_ name: String, _ language: OpaquePointer) {
        self.name = name
        self.language = SwiftTreeSitter.Language(language)
        indents = Self.query("indents", for: name, language: self.language)
    }

    static let c = Grammar("c", tree_sitter_c())
    static let cpp = Grammar("cpp", tree_sitter_cpp())
    static let python = Grammar("python", tree_sitter_python())

    static func source(_ file: String, for name: String) -> String? {
        guard let url = Bundle.module.url(forResource: file, withExtension: "scm", subdirectory: "Queries/\(name)"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let prefix = "; inherits: "
        guard let first = text.split(separator: "\n", maxSplits: 1).first, first.hasPrefix(prefix) else {
            return text
        }
        let parent = first.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return (source(file, for: parent) ?? "") + "\n" + text
    }

    /// Nil, said once on stderr, when the file is missing or names a node the
    /// grammar has not got — a grammar upgrade that renamed one. The feature
    /// then answers nil and the editor keeps the line's indentation.
    private static func query(_ file: String, for name: String, language: SwiftTreeSitter.Language) -> Query? {
        guard let text = source(file, for: name) else {
            FileHandle.standardError.write(Data("LavaEditorSyntax: no \(file).scm for \(name)\n".utf8))
            return nil
        }
        do {
            return try Query(language: language, data: Data(text.utf8))
        } catch {
            FileHandle.standardError.write(Data("LavaEditorSyntax: \(name)/\(file).scm: \(error)\n".utf8))
            return nil
        }
    }
}

/// A tree-sitter tree that follows one buffer through its edits.
final class TreeSitterTree {
    let grammar: Grammar
    private let parser = Parser()
    private var tree: MutableTree?
    /// The revision `tree` describes.
    private var revision: UInt64?
    private(set) var lines = LineStarts()
    private(set) var fullParses = 0

    init?(_ grammar: Grammar) {
        self.grammar = grammar
        guard (try? parser.setLanguage(grammar.language)) != nil else { return nil }
    }

    var mutableTree: MutableTree? { tree }

    /// Brings the tree to `state`'s text; `bytes` is that text.
    func sync(to state: TextEditingState, bytes: UnsafeBufferPointer<UInt8>) -> Node? {
        guard bytes.count < Int(UInt32.max) else { return nil }
        if let tree, revision == state.revision { return tree.rootNode }
        if let tree, let revision, let changes = state.changes(since: revision),
           follow(changes, in: tree), lines.byteCount == bytes.count {
            // Edited in place; the parse below reuses what the edits missed.
        } else {
            tree = nil
            lines = LineStarts(bytes)
            fullParses += 1
        }
        tree = parser.parse(tree: tree, encoding: TSInputEncodingUTF8) { offset, _ in
            guard offset < bytes.count else { return nil }
            // Chunks end on a character boundary, so no read hands the lexer
            // half a scalar.
            var end = min(offset + 16 * 1024, bytes.count)
            while end < bytes.count, bytes[end] & 0xc0 == 0x80 { end += 1 }
            return Data(UnsafeBufferPointer(rebasing: bytes[offset..<end]))
        }
        revision = tree == nil ? nil : state.revision
        return tree?.rootNode
    }

    /// Tells the tree about each splice, in the coordinates of the buffer as
    /// it was at that point. False when one does not fit the buffer this tree
    /// knows, which means the log and the tree disagree and neither is worth
    /// trusting.
    private func follow(_ changes: [TextChange], in tree: MutableTree) -> Bool {
        for change in changes {
            let start = change.offset
            let oldEnd = start + change.removedLength
            let newEnd = start + change.inserted.utf8.count
            guard start >= 0, oldEnd <= lines.byteCount else { return false }
            let startPoint = lines.point(at: start)
            let oldEndPoint = lines.point(at: oldEnd)
            lines.apply(change)
            tree.edit(InputEdit(
                startByte: start, oldEndByte: oldEnd, newEndByte: newEnd,
                startPoint: startPoint, oldEndPoint: oldEndPoint, newEndPoint: lines.point(at: newEnd)
            ))
        }
        return true
    }
}

/// Where each line starts, kept in step with the splices, so an edit's row
/// and column cost a binary search rather than a count of every newline
/// before it.
struct LineStarts {
    private(set) var starts: [Int] = [0]
    private(set) var byteCount = 0

    init() {}

    init(_ bytes: UnsafeBufferPointer<UInt8>) {
        byteCount = bytes.count
        for index in bytes.indices where bytes[index] == 0x0a { starts.append(index + 1) }
    }

    func row(at offset: Int) -> Int {
        var low = 0
        var high = starts.count
        while high - low > 1 {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle } else { high = middle }
        }
        return low
    }

    func lineStart(at offset: Int) -> Int { starts[row(at: offset)] }

    /// Columns are bytes, as tree-sitter counts them.
    func point(at offset: Int) -> Point {
        let row = row(at: offset)
        return Point(row: row, column: offset - starts[row])
    }

    mutating func apply(_ change: TextChange) {
        let start = change.offset
        let oldEnd = start + change.removedLength
        let delta = change.inserted.utf8.count - change.removedLength
        // A line starting inside (start, oldEnd] began after a newline the
        // splice removed.
        let low = row(at: start) + 1
        var high = low
        while high < starts.count, starts[high] <= oldEnd { high += 1 }
        for index in high..<starts.count { starts[index] += delta }
        var added: [Int] = []
        for (index, byte) in change.inserted.utf8.enumerated() where byte == 0x0a {
            added.append(start + index + 1)
        }
        starts.replaceSubrange(low..<high, with: added)
        byteCount += delta
    }
}
