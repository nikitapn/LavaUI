import Dispatch
import Foundation
import LavaText

/// The syntax tree of one open document, parsed in the background and kept
/// up to date with its buffer.
///
/// Owned by the document, not by any one feature: indentation is its first
/// reader, and highlighting, folding or selection by syntax node should read
/// the same tree rather than each parsing the file again.
///
/// **The worker never sees the editor's `String`.** A snapshot would share the
/// buffer's storage, and the editor's next keystroke would then copy the whole
/// file. The worker keeps a byte copy of its own instead, made once, and
/// follows the editor through the splices `TextEditingState` records
/// (`changes(since:)`), applying them to that copy and to the tree as they
/// arrive and reparsing once typing pauses. When a state cannot say what
/// changed — a `setText`, another editor's buffer, a log that has moved on —
/// the text is copied over again and parsed whole, which is always correct.
///
/// The main thread only ever enqueues: `follow` is a copy of a few splices,
/// and a question (`indentation`) waits behind them for at most
/// `answerTimeout`. A file whose first parse is still running answers nil —
/// keep the line's indentation — rather than freezing the window.
public final class SyntaxDocument: @unchecked Sendable {
    public enum Language: Sendable {
        case swift, python, c, cpp
    }

    #if canImport(SwiftParser) && canImport(SwiftSyntax)
    public static let hasSwiftParser = true
    #else
    public static let hasSwiftParser = false
    #endif

    /// The longest a question waits for the parse to catch up. An Enter after
    /// an edit waits for one incremental reparse; only a first parse of a
    /// large file runs past this.
    public let answerTimeout: DispatchTimeInterval

    // Main thread only: what the worker has been sent.
    private var sentRevision: UInt64?
    private var sentLanguage: Language?

    private let worker = Worker()

    public init(answerTimeout: DispatchTimeInterval = .milliseconds(50)) {
        self.answerTimeout = answerTimeout
    }

    /// Hands the worker whatever `state` changed since the last call — or the
    /// whole text when that is not on record — and returns at once. Called by
    /// the editor after its edits; cheap when nothing changed.
    public func follow(_ state: TextEditingState, language: Language) {
        if state.revision == sentRevision, language == sentLanguage { return }
        if language == sentLanguage, let revision = sentRevision, let changes = state.changes(since: revision) {
            worker.enqueue(.edits(changes, revision: state.revision))
        } else {
            worker.enqueue(.reset(language, bytes: Array(state.text.utf8), revision: state.revision))
        }
        sentRevision = state.revision
        sentLanguage = language
    }

    /// The whitespace a new line at `caret` should start with, or nil to keep
    /// the current line's — which is also the answer when the parse has not
    /// caught up within `answerTimeout`.
    public func indentation(
        for state: TextEditingState, at caret: String.Index, language: Language, unit: String = "    "
    ) -> String? {
        follow(state, language: language)
        let text = state.text
        let offset = text.utf8.distance(from: text.utf8.startIndex, to: caret)
        let revision = state.revision
        let answer = ask(timeout: answerTimeout) { worker in
            worker.indentation(at: offset, unit: unit, revision: revision)
        }
        switch answer {
        case .some(.answer(let indent)): return indent
        case .some(.stale):
            // The worker lost the thread (a splice that did not fit). The
            // next follow sends the text whole.
            sentRevision = nil
            return nil
        case .none: return nil
        }
    }

    /// The same, for a text that is not being edited. Parses it whole.
    public func indentation(
        in text: String, at caret: String.Index, language: Language, unit: String = "    "
    ) -> String? {
        indentation(for: TextEditingState(text), at: caret, language: language, unit: unit)
    }

    /// Runs `body` on the worker, after everything already sent, and waits
    /// for it — nil if that takes longer than `timeout`. The work still runs
    /// then; only its answer is dropped.
    private func ask<Value>(timeout: DispatchTimeInterval, _ body: @escaping (Worker) -> Value) -> Value? {
        let reply = Reply<Value>()
        worker.enqueue(.run { reply.value = body($0); reply.done.signal() })
        guard reply.done.wait(timeout: .now() + timeout) == .success else { return nil }
        return reply.value
    }

    private final class Reply<Value>: @unchecked Sendable {
        // Written before `done` is signalled, read only after it was.
        var value: Value?
        let done = DispatchSemaphore(value: 0)
    }

    // MARK: Testing

    /// Waits for everything sent so far, without a timeout.
    func sync<Value>(_ body: @escaping (Worker) -> Value) -> Value {
        ask(timeout: .never, body)!
    }

    /// How many times the tree was built from nothing rather than edited.
    var fullParses: Int { sync { $0.fullParses } }

    /// Whether edits are waiting for a reparse.
    var isDirty: Bool { sync { $0.isDirty } }

    /// The tree as an S-expression, after following `state`.
    func sExpression(for state: TextEditingState, language: Language) -> String? {
        follow(state, language: language)
        return sync { $0.sExpression() }
    }
}

extension SyntaxDocument {
    enum Message: @unchecked Sendable {
        case reset(Language, bytes: [UInt8], revision: UInt64)
        case edits([TextChange], revision: UInt64)
        case run((Worker) -> Void)
    }

    enum Answer {
        case answer(String?)
        /// The worker is not at the revision asked about.
        case stale
    }

    /// Everything that parses, on one serial queue. Nothing here is touched
    /// from any other thread.
    final class Worker: @unchecked Sendable {
        private let queue = DispatchQueue(label: "LavaEditorSyntax.parse", qos: .userInitiated)
        /// How long typing has to pause before the worker reparses on its own.
        static let settle: DispatchTimeInterval = .milliseconds(30)

        private var language: Language?
        private var bytes: [UInt8] = []
        /// The revision `bytes` is at; nil when lost.
        private var revision: UInt64?
        private var treeSitter: TreeSitterTree?
        #if canImport(SwiftParser) && canImport(SwiftSyntax)
        private var swift: SwiftTree?
        #endif
        /// Bumped by every message, so a settle timer knows whether more
        /// edits came after the ones that started it.
        private var generation = 0

        func enqueue(_ message: Message) {
            queue.async { self.handle(message) }
        }

        private func handle(_ message: Message) {
            generation += 1
            switch message {
            case .reset(let language, let bytes, let revision):
                adopt(language)
                self.bytes = bytes
                self.revision = revision
                treeSitter.map { tree in self.bytes.withUnsafeBufferPointer { tree.reset($0) } }
                #if canImport(SwiftParser) && canImport(SwiftSyntax)
                swift?.reset()
                #endif
                // A whole parse starts now: it is the slow one, and nothing is
                // gained by waiting for a pause that has not begun.
                parse()
            case .edits(let changes, let revision):
                guard self.revision != nil, apply(changes) else {
                    self.revision = nil
                    return
                }
                self.revision = revision
                let generation = generation
                queue.asyncAfter(deadline: .now() + Self.settle) {
                    if self.generation == generation { self.parse() }
                }
            case .run(let body):
                body(self)
            }
        }

        private func adopt(_ next: Language) {
            guard next != language else { return }
            language = next
            treeSitter = nil
            #if canImport(SwiftParser) && canImport(SwiftSyntax)
            swift = nil
            #endif
            switch next {
            case .swift:
                #if canImport(SwiftParser) && canImport(SwiftSyntax)
                swift = SwiftTree()
                #endif
            case .python: treeSitter = TreeSitterTree(.python)
            case .c: treeSitter = TreeSitterTree(.c)
            case .cpp: treeSitter = TreeSitterTree(.cpp)
            }
        }

        private func apply(_ changes: [TextChange]) -> Bool {
            for change in changes {
                let end = change.offset + change.removedLength
                guard change.offset >= 0, end <= bytes.count else { return false }
                bytes.replaceSubrange(change.offset..<end, with: change.inserted.utf8)
            }
            if let treeSitter, !treeSitter.apply(changes) { return false }
            #if canImport(SwiftParser) && canImport(SwiftSyntax)
            swift?.apply(changes)
            #endif
            return true
        }

        private func parse() {
            bytes.withUnsafeBufferPointer { bytes in
                _ = treeSitter?.parse(bytes)
                #if canImport(SwiftParser) && canImport(SwiftSyntax)
                swift?.parse(bytes)
                #endif
            }
        }

        func indentation(at caret: Int, unit: String, revision: UInt64) -> Answer {
            guard self.revision == revision, caret <= bytes.count else { return .stale }
            return .answer(bytes.withUnsafeBufferPointer { bytes -> String? in
                #if canImport(SwiftParser) && canImport(SwiftSyntax)
                if let swift { return swift.indentation(bytes: bytes, at: caret, unit: unit) }
                #endif
                guard let tree = treeSitter, let query = tree.grammar.indents,
                      let root = tree.parse(bytes) else { return nil }
                return IndentQuery.indentation(query: query, tree: tree, root: root, bytes: bytes, at: caret, unit: unit)
            })
        }

        var fullParses: Int {
            #if canImport(SwiftParser) && canImport(SwiftSyntax)
            if let swift { return swift.fullParses }
            #endif
            return treeSitter?.fullParses ?? 0
        }

        var isDirty: Bool {
            #if canImport(SwiftParser) && canImport(SwiftSyntax)
            if let swift { return swift.isDirty }
            #endif
            return treeSitter?.isDirty ?? false
        }

        func sExpression() -> String? {
            bytes.withUnsafeBufferPointer { treeSitter?.parse($0)?.sExpressionString }
        }
    }
}

/// The buffer's UTF-8 without copying it. A native string is contiguous; the
/// copy is for one that is not, which a Swift buffer on Linux never is.
func withBytes<R>(of text: String, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
    if let result = text.utf8.withContiguousStorageIfAvailable(body) { return result }
    return Array(text.utf8).withUnsafeBufferPointer(body)
}

func isHorizontalSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }

/// The leading whitespace of the line holding `offset`.
func lineIndent(in bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> String {
    var start = offset
    while start > 0, bytes[start - 1] != 0x0a { start -= 1 }
    var end = start
    while end < bytes.count, isHorizontalSpace(bytes[end]) { end += 1 }
    return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
}

/// One level past `base`, in the base's own character when it ends in a tab.
func indented(_ base: String, by unit: String) -> String {
    base + (base.last == "\t" ? "\t" : unit)
}
