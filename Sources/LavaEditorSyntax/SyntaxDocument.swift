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
/// (`changes(since:)`), applying them to that copy and to the tree and
/// reparsing as they arrive — one batch a frame at most, since that is how
/// often the editor sends them. When a state cannot say what
/// changed — a `setText`, another editor's buffer, a log that has moved on —
/// the text is copied over again and parsed whole, which is always correct.
///
/// The main thread only ever enqueues: `follow` is a copy of a few splices,
/// and a question (`indentation`) waits behind them for at most
/// `answerTimeout`. A file whose first parse is still running answers nil —
/// keep the line's indentation — rather than freezing the window.
///
/// **Highlighting** is a `HighlightSource`: after every parse, and whenever
/// the editor asks for other lines, the worker runs the language's
/// `highlights.scm` over the lines asked for (plus a screenful each side)
/// and publishes them. Drawing waits up to `highlightWait` for the layer of
/// the revision on screen, and otherwise draws what it has.
public final class SyntaxDocument: HighlightSource, @unchecked Sendable {
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
    /// The longest drawing waits for highlights of the revision it is
    /// drawing. A keystroke's reparse and highlight pass normally land well
    /// inside it; past it, lines whose text is unchanged keep the colours
    /// they had and the rest take the editor's own highlighter for a frame.
    public let highlightWait: TimeInterval

    // Main thread only: what the worker has been sent.
    private var sentRevision: UInt64?
    private var sentLanguage: Language?
    /// The lines the worker was last asked to highlight.
    private var requestedLines: Range<Int>?
    /// A wait that ran out, so the next frames at the same revision draw
    /// what there is rather than each waiting again.
    private var gaveUp: (revision: UInt64, lines: Range<Int>)?

    private let published = Published()
    private let worker: Worker

    public init(answerTimeout: DispatchTimeInterval = .milliseconds(50), highlightWait: TimeInterval = 0.008) {
        self.answerTimeout = answerTimeout
        self.highlightWait = highlightWait
        worker = Worker(published: published)
    }

    /// Whether `language` has a highlight query, and so is worth installing
    /// as a `HighlightSource` for.
    public static func highlights(_ language: Language) -> Bool {
        switch language {
        case .swift: return false
        case .python: return Grammar.python.highlights != nil
        case .c: return Grammar.c.highlights != nil
        case .cpp: return Grammar.cpp.highlights != nil
        }
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

    // MARK: HighlightSource

    public func highlights(for state: TextEditingState, lines: Range<Int>) -> HighlightLayer? {
        guard let language = sentLanguage, Self.highlights(language) else { return nil }
        follow(state, language: language)
        if let requested = requestedLines,
           requested.lowerBound <= lines.lowerBound, lines.upperBound <= requested.upperBound {
        } else {
            // A screenful either side, so a scroll is usually drawn from what
            // is already there while the worker catches up.
            let margin = max(50, lines.count)
            let wanted = max(0, lines.lowerBound - margin)..<(lines.upperBound + margin)
            requestedLines = wanted
            worker.enqueue(.highlight(wanted))
        }
        let patient = gaveUp.map { !($0.revision == state.revision && $0.lines == lines) } ?? true
        let (layer, ready) = published.take(
            revision: state.revision, lines: lines, waiting: patient ? highlightWait : 0
        )
        gaveUp = ready ? nil : (state.revision, lines)
        return layer
    }

    public var highlightsChanged: (@Sendable () -> Void)? {
        get { published.withLock { published.changed } }
        set { published.withLock { published.changed = newValue } }
    }

    public var hasUndrawnHighlights: Bool {
        published.withLock { published.generation != published.drawnGeneration }
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

    /// The newest highlight layer, handed from the worker to drawing.
    final class Published: @unchecked Sendable {
        private let condition = NSCondition()
        // All under `condition`'s lock.
        var layer: HighlightLayer?
        var covered: Range<Int> = 0..<0
        var generation = 0
        var drawnGeneration = 0
        var changed: (@Sendable () -> Void)?

        func withLock<T>(_ body: () -> T) -> T {
            condition.lock()
            defer { condition.unlock() }
            return body()
        }

        /// Worker: a new layer, and whoever wants to know.
        func publish(_ layer: HighlightLayer, covering lines: Range<Int>) {
            condition.lock()
            self.layer = layer
            covered = lines
            generation += 1
            let changed = changed
            condition.broadcast()
            condition.unlock()
            changed?()
        }

        /// Main: the newest layer, after waiting up to `waiting` for one at
        /// `revision` that covers `lines`; and whether it came.
        func take(revision: UInt64, lines: Range<Int>, waiting: TimeInterval) -> (HighlightLayer?, Bool) {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date(timeIntervalSinceNow: waiting)
            func ready() -> Bool {
                guard let layer, layer.revision == revision, covered.lowerBound <= lines.lowerBound else { return false }
                // Lines past the end of the file are covered by covering the end.
                return lines.upperBound <= covered.upperBound || covered.upperBound >= layer.lineCount
            }
            while !ready(), condition.wait(until: deadline) {}
            drawnGeneration = generation
            return (layer, ready())
        }
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
        /// Which lines drawing wants highlighted.
        case highlight(Range<Int>)
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
        private let published: Published
        /// Lines drawing asked for; nil until it asks, which is when
        /// highlighting starts costing anything.
        private var wanted: Range<Int>?

        init(published: Published) {
            self.published = published
        }

        private var language: Language?
        private var bytes: [UInt8] = []
        /// The revision `bytes` is at; nil when lost.
        private var revision: UInt64?
        private var treeSitter: TreeSitterTree?
        #if canImport(SwiftParser) && canImport(SwiftSyntax)
        private var swift: SwiftTree?
        #endif
        func enqueue(_ message: Message) {
            queue.async { self.handle(message) }
        }

        private func handle(_ message: Message) {
            switch message {
            case .reset(let language, let bytes, let revision):
                adopt(language)
                self.bytes = bytes
                self.revision = revision
                treeSitter.map { tree in self.bytes.withUnsafeBufferPointer { tree.reset($0) } }
                #if canImport(SwiftParser) && canImport(SwiftSyntax)
                swift?.reset()
                #endif
                parse()
                highlight()
            case .edits(let changes, let revision):
                guard self.revision != nil, apply(changes) else {
                    self.revision = nil
                    return
                }
                self.revision = revision
                // At once rather than after a pause: the colours follow each
                // keystroke, and the editor sends at most one batch a frame.
                parse()
                highlight()
            case .highlight(let lines):
                wanted = lines
                highlight()
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

        /// Publishes the wanted lines' highlights for the current revision.
        private func highlight() {
            guard let wanted, let revision, let tree = treeSitter, let query = tree.grammar.highlights
            else { return }
            bytes.withUnsafeBufferPointer { bytes in
                guard let root = tree.parse(bytes), let mutable = tree.mutableTree else { return }
                let layer = query.layer(
                    tree: mutable, root: root, bytes: bytes, lines: tree.lines, wanted: wanted, revision: revision
                )
                published.publish(layer, covering: wanted)
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
