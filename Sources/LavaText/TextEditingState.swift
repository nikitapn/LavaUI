import Foundation

// Phase 7 — text editing, pure logic half.
//
// Deliberately knows nothing about glyphs, fonts, or the GPU: everything here
// is testable without a window. Only two operations genuinely need the shaper
// (click → cursor, cursor → caret x), and they live in ShapedRun instead.
//
// Cursors are `String.Index`, never integers. Swift's indices move by grapheme
// cluster, so an arrow key steps over an emoji ZWJ sequence, a combining
// accent, or a regional-indicator pair as one unit — the thing that makes text
// editing miserable in C++ is free here, provided we never fall back to
// byte or codepoint offsets.

/// Selection and caret for a single editable string.
///
/// `anchor` is where a selection started, `focus` is the moving end and where
/// the caret is drawn. They are equal when there is no selection.
public struct TextEditingState: Equatable {
    public private(set) var text: String
    public private(set) var anchor: String.Index
    public private(set) var focus: String.Index

    /// Which version of the *content* this is. Changes on every edit, and
    /// never for a caret or selection move.
    ///
    /// Exists for the caches around this type. Converting between a
    /// `String.Index` and a character offset walks the buffer, so every
    /// consumer that does it in a hot path — the draw list's first visible
    /// row, the caret, a hit test — keeps the last pair it resolved and works
    /// relative to it. Such a pair is only meaningful for the buffer it was
    /// taken from, and "has the text changed" has no cheap answer otherwise:
    /// comparing two `String`s is a content comparison, and comparing a *copy*
    /// of the state (this is a value type, copied constantly) says nothing
    /// about whether the text moved.
    ///
    /// Process-wide unique rather than a per-instance counter, so a cache
    /// cannot mistake a freshly constructed state — whose counter would start
    /// over — for the one it sampled.
    ///
    /// It participates in the synthesized `Equatable`, which makes equality
    /// stricter than it was: two states built separately from the same string
    /// are no longer `==`. Nothing in the repo compares whole states (only
    /// their `text`), and leaving the conformance synthesized is worth more
    /// than the looser semantics — a hand-written `==` is one field away from
    /// silently ignoring the next thing added here.
    public private(set) var revision: UInt64 = TextEditingState.nextRevision()

    private final class Counter: @unchecked Sendable {
        var value: UInt64 = 1
    }
    private static let counter = Counter()

    /// Editing is single-threaded (the frame loop), like `NodeID.generate`.
    private static func nextRevision() -> UInt64 {
        counter.value &+= 1
        return counter.value
    }

    /// Edit history. Every mutation funnels through `replace(...)`, which is
    /// what makes undo possible without auditing each operation separately —
    /// the thing the plan warned becomes painful to retrofit.
    public private(set) var undoStack = UndoStack()

    /// Column to aim for during vertical movement, in characters.
    ///
    /// Held across consecutive up/down presses and cleared by anything else,
    /// so a run of Down/Up returns to where it began rather than tracking the
    /// shortest line it passed through.
    internal var desiredColumn: Int?

    /// Visual rows, when the view has wrapped the buffer. Nil means one row
    /// per logical line. Vertical movement and Home/End follow *these* — with
    /// wrapping, a visual row is not a logical line, and navigating by
    /// newlines would skip whole wrapped rows.
    public internal(set) var visualRows: [Range<Int>]?

    /// Which side of a wrap boundary the caret sits on. Only meaningful when
    /// the caret is exactly at one; see `CaretAffinity`.
    public internal(set) var affinity: CaretAffinity = .downstream

    /// Installed by the view after each wrap pass.
    public mutating func setVisualRows(_ rows: [Range<Int>]?) {
        visualRows = rows
    }

    /// Row structure currently in effect.
    public var layout: VisualLayout {
        if let visualRows { return VisualLayout(rows: visualRows) }
        return .logical(text)
    }

    /// Last offset↔index pair resolved — see `offset(of:)`.
    ///
    /// A **class**, so the two conversions stay non-mutating. That is what
    /// makes this invisible to every caller: they are `func`s on a value type
    /// held in a dozen places, and making them `mutating` would both break
    /// those callers and force each one to hoist its arguments and results
    /// through locals to avoid overlapping exclusive access to `self`.
    ///
    /// Shared by copies of the state, which is safe rather than merely
    /// tolerable: `revision` is process-unique and changes on every edit, so a
    /// shared revision means identical text, and a hint taken from one copy is
    /// exactly as valid for the other. Two copies that have since diverged
    /// simply take turns missing.
    private final class IndexAnchor {
        private(set) var revision: UInt64 = 0
        private(set) var offset = 0
        private(set) var index: String.Index

        init(_ index: String.Index) { self.index = index }

        func store(revision: UInt64, offset: Int, index: String.Index) {
            self.revision = revision
            self.offset = offset
            self.index = index
        }
    }

    /// Excluded from equality on purpose: it is a cache, so resolving a caret
    /// offset must not make two equal states unequal. The synthesized `==`
    /// would compare it by *identity*, which is exactly wrong — two states
    /// built separately from the same string would differ by their caches.
    private let indexAnchor: IndexAnchor

    public static func == (lhs: TextEditingState, rhs: TextEditingState) -> Bool {
        lhs.text == rhs.text && lhs.anchor == rhs.anchor && lhs.focus == rhs.focus
            && lhs.revision == rhs.revision && lhs.undoStack == rhs.undoStack
            && lhs.visualRows == rhs.visualRows && lhs.desiredColumn == rhs.desiredColumn
            && lhs.affinity == rhs.affinity
    }

    public init(_ text: String = "") {
        self.text = text
        self.anchor = text.startIndex
        self.focus = text.startIndex
        self.indexAnchor = IndexAnchor(text.startIndex)
    }

    // MARK: Selection

    public var hasSelection: Bool { anchor != focus }

    /// Selection in document order, regardless of drag direction.
    public var selectedRange: Range<String.Index> {
        anchor <= focus ? anchor..<focus : focus..<anchor
    }

    public var selectedText: String { String(text[selectedRange]) }

    /// Selects the word containing `index` — what a double-click should do.
    /// Falls back to the run of separators when the click lands between words,
    /// so a double-click on whitespace still selects something coherent.
    public mutating func selectWord(at index: String.Index) {
        let range = wordRange(at: clamp(index))
        anchor = range.lowerBound
        focus = range.upperBound
        desiredColumn = nil
        affinity = .downstream
    }

    /// The word-ish run around `index`, using the same classification as
    /// Ctrl+arrow so double-click and word movement agree.
    public func wordRange(at index: String.Index) -> Range<String.Index> {
        guard !text.isEmpty else { return text.startIndex..<text.startIndex }

        // A caret at the very end has no character under it; look left.
        var probe = index
        if probe >= text.endIndex { probe = text.index(before: text.endIndex) }

        let wordish = Self.isWordCharacter(text[probe])

        var lower = probe
        while lower > text.startIndex {
            let prev = text.index(before: lower)
            if Self.isWordCharacter(text[prev]) != wordish { break }
            lower = prev
        }

        var upper = probe
        while upper < text.endIndex, Self.isWordCharacter(text[upper]) == wordish {
            upper = text.index(after: upper)
        }
        return lower..<upper
    }

    public mutating func selectAll() {
        anchor = text.startIndex
        focus = text.endIndex
        desiredColumn = nil
        affinity = .downstream
    }

    /// Collapses to the caret end, as typing or a plain arrow key should.
    public mutating func clearSelection() { anchor = focus }

    public mutating func setCursor(_ index: String.Index, extending: Bool = false) {
        focus = clamp(index)
        if !extending { anchor = focus }
        desiredColumn = nil
        affinity = .downstream
    }

    // MARK: Movement

    public mutating func moveLeft(extending: Bool = false) {
        // A plain left arrow with a selection collapses to its start rather
        // than moving — matching every other editor.
        if hasSelection, !extending {
            focus = selectedRange.lowerBound
            anchor = focus
            return
        }
        if focus > text.startIndex {
            focus = text.index(before: focus)
        }
        if !extending { anchor = focus }
        desiredColumn = nil
        affinity = .downstream
    }

    public mutating func moveRight(extending: Bool = false) {
        if hasSelection, !extending {
            focus = selectedRange.upperBound
            anchor = focus
            return
        }
        if focus < text.endIndex {
            focus = text.index(after: focus)
        }
        if !extending { anchor = focus }
        desiredColumn = nil
        affinity = .downstream
    }

    public mutating func moveToStart(extending: Bool = false) {
        focus = text.startIndex
        if !extending { anchor = focus }
        desiredColumn = nil
        affinity = .downstream
    }

    public mutating func moveToEnd(extending: Bool = false) {
        focus = text.endIndex
        if !extending { anchor = focus }
        desiredColumn = nil
        affinity = .downstream
    }

    public mutating func moveWordLeft(extending: Bool = false) {
        focus = wordBoundary(before: focus)
        if !extending { anchor = focus }
        desiredColumn = nil
        affinity = .downstream
    }

    public mutating func moveWordRight(extending: Bool = false) {
        focus = wordBoundary(after: focus)
        if !extending { anchor = focus }
        desiredColumn = nil
        affinity = .downstream
    }

    // MARK: The one mutation path

    /// Replaces `range` with `replacement`, records it for undo, and leaves
    /// the caret after the inserted text.
    ///
    /// Every editing operation goes through here. That is the whole point:
    /// undo cannot be bolted onto a type that mutates its buffer in eight
    /// places, and this type used to.
    private mutating func replace(
        _ range: Range<String.Index>, with replacement: String, record: Bool = true
    ) {
        let removed = String(text[range])
        guard !(removed.isEmpty && replacement.isEmpty) else { return }
        // UTF-8 offsets, not character offsets: this runs once per keystroke,
        // and `offset(of:)` walks the whole prefix by grapheme. See `TextEdit`.
        let start = utf8Offset(of: range.lowerBound)
        // Character offset of the splice, taken *before* the buffer moves and
        // only while the anchor is already live — then it is a few steps from
        // the caret, and this is what lets the anchor survive the edit. See
        // the reseed below.
        let startChar: Int? = indexAnchor.revision == revision
            ? offset(of: range.lowerBound) : nil

        if record {
            undoStack.record(TextEdit(
                offset: start,
                removed: removed,
                inserted: replacement,
                anchorBefore: utf8Offset(of: anchor),
                focusBefore: utf8Offset(of: focus)
            ))
        }

        text.replaceSubrange(range, with: replacement)
        revision = Self.nextRevision()
        // Row ranges are character offsets into `text`. Leaving them installed
        // after a delete (or any length-changing edit) makes every consumer of
        // `layout` — `rowTexts`, `scrollToCaretX`, hit-testing — walk past
        // `endIndex` and trap in `String.index(_:offsetBy:)`. Nil means
        // `layout` falls back to a live `.logical(text)` until the view's
        // next wrap/seed pass reinstalls a table.
        visualRows = nil
        reseedAnchor(atUTF8Offset: start, characterOffset: startChar)
        let caret = index(atUTF8Offset: start + replacement.utf8.count)
        focus = caret
        anchor = caret
        desiredColumn = nil
        affinity = .downstream
    }

    /// Re-establishes the offset↔index anchor on the *new* buffer, at the
    /// point the edit spliced.
    ///
    /// Without this, every edit orphaned the anchor — its revision no longer
    /// matched — and the next question anyone asked about the caret walked the
    /// buffer from byte zero to find it. That is the same cost the anchor was
    /// introduced to remove, reappearing once per keystroke and growing with
    /// how far into the file the caret is: ~4 ms a character 4 MB in, and
    /// linear beyond that. Every caller after an edit wants a position at or
    /// beside the splice, so the splice is exactly where the anchor belongs.
    ///
    /// `characterOffset` is the splice's character offset measured before the
    /// buffer moved, or nil when the anchor was already stale — there is
    /// nothing to preserve then, and establishing it here would pay the walk
    /// this exists to avoid.
    ///
    /// The prefix bytes are untouched by a splice, so its character count
    /// carries over — *provided* the splice point is a character boundary on
    /// both sides of the edit. It was one before (the range came from
    /// character-space navigation); `String.Index(_:within:)` is the exact
    /// test for after, and nil means the edit merged clusters across the seam
    /// (a combining mark typed onto a letter, an LF landing behind a CR). Then
    /// the count genuinely moved and the anchor is left stale to be rebuilt
    /// honestly.
    private func reseedAnchor(atUTF8Offset offset: Int, characterOffset: Int?) {
        guard let characterOffset else { return }
        let utf8 = text.utf8
        guard offset <= utf8.count else { return }
        let byteIndex = utf8.index(utf8.startIndex, offsetBy: offset)
        guard let boundary = String.Index(byteIndex, within: text) else { return }
        indexAnchor.store(revision: revision, offset: characterOffset, index: boundary)
    }

    /// Replaces a character range with `replacement`, as one undoable edit.
    ///
    /// Offsets rather than `String.Index` because the callers are find/replace
    /// and an LSP-style edit, and both of those hold offsets from a scan that
    /// has already finished — see `TextSearch`.
    public mutating func replace(offsets range: Range<Int>, with replacement: String) {
        let lo = index(atOffset: range.lowerBound)
        let hi = index(atOffset: max(range.lowerBound, range.upperBound))
        replace(lo..<hi, with: replacement)
    }

    /// Replaces every range in `ranges` with `replacement` and returns how
    /// many were applied. Ranges are character offsets over the current
    /// buffer, as `TextSearch.matches` reports them.
    ///
    /// **One undo step, not one per match.** That is the whole reason this is
    /// here rather than in the caller: a replace-all is a single thing the
    /// user did, and undoing it a match at a time is the behaviour people file
    /// bugs about. It is done by rewriting the span from the first match to
    /// the last as a single edit, so the recorded `removed` text is that whole
    /// span — replacing across a large buffer holds a copy of it in the undo
    /// history until the history is dropped.
    ///
    /// Overlapping ranges are not applied twice: after sorting, any range
    /// starting before the previous one ended is skipped. Empty ranges are
    /// skipped too — a zero-width match would otherwise insert `replacement`
    /// at every position between two real ones.
    @discardableResult
    public mutating func replaceAll(
        _ ranges: [Range<Int>], with replacement: String
    ) -> Int {
        var applied: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound })
        where !range.isEmpty && range.lowerBound >= (applied.last?.upperBound ?? 0) {
            applied.append(range)
        }
        guard let first = applied.first else { return 0 }

        // Walked once, forward, rather than `index(atOffset:)` per match:
        // that walks from the start of the buffer every call, so replacing
        // 5,000 matches would cost 5,000 walks of everything before each one.
        let spanStart = index(atOffset: first.lowerBound)
        var rebuilt = ""
        var cursor = first.lowerBound
        var idx = spanStart
        for range in applied {
            if range.lowerBound > cursor {
                let kept = text.index(idx, offsetBy: range.lowerBound - cursor)
                rebuilt += text[idx..<kept]
                idx = kept
            }
            rebuilt += replacement
            idx = text.index(idx, offsetBy: range.upperBound - range.lowerBound)
            cursor = range.upperBound
        }
        replace(spanStart..<idx, with: rebuilt)
        return applied.count
    }

    // MARK: Undo / redo

    public var canUndo: Bool { undoStack.canUndo }
    public var canRedo: Bool { undoStack.canRedo }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let edit = undoStack.popUndo() else { return false }
        apply(edit.inverted)
        // Restore where the user was, not just what the text was.
        anchor = index(atUTF8Offset: edit.anchorBefore)
        focus = index(atUTF8Offset: edit.focusBefore)
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let edit = undoStack.popRedo() else { return false }
        apply(edit)
        return true
    }

    /// Applies an edit without recording it — used by undo/redo, which must
    /// not push new history while walking the existing history.
    private mutating func apply(_ edit: TextEdit) {
        let lower = index(atUTF8Offset: edit.offset)
        let upper = index(atUTF8Offset: edit.offset + edit.removed.utf8.count)
        let startChar: Int? = indexAnchor.revision == revision ? offset(of: lower) : nil
        text.replaceSubrange(lower..<upper, with: edit.inserted)
        revision = Self.nextRevision()
        visualRows = nil
        // Same reason as `replace`: holding undo down is a run of edits, and
        // each one otherwise orphans the anchor for the caret query that
        // follows it.
        reseedAnchor(atUTF8Offset: edit.offset, characterOffset: startChar)
        let caret = index(atUTF8Offset: edit.offset + edit.inserted.utf8.count)
        focus = caret
        anchor = caret
    }

    // MARK: Editing

    public mutating func insert(_ string: String) {
        guard !string.isEmpty || hasSelection else { return }
        replace(selectedRange, with: string)
    }

    public mutating func deleteBackward() {
        if hasSelection {
            deleteSelection()
            return
        }
        guard focus > text.startIndex else { return }
        // index(before:) steps a whole grapheme, so one press removes one
        // user-perceived character rather than half an emoji.
        replace(text.index(before: focus)..<focus, with: "")
    }

    public mutating func deleteForward() {
        if hasSelection {
            deleteSelection()
            return
        }
        guard focus < text.endIndex else { return }
        replace(focus..<text.index(after: focus), with: "")
    }

    public mutating func deleteWordBackward() {
        if hasSelection {
            deleteSelection()
            return
        }
        let from = wordBoundary(before: focus)
        guard from < focus else { return }
        replace(from..<focus, with: "")
    }

    private mutating func deleteSelection() {
        let range = selectedRange
        guard !range.isEmpty else { return }
        replace(range, with: "")
    }

    /// Replaces the whole buffer, e.g. when the bound value changed elsewhere.
    public mutating func setText(_ new: String, keepingCursor: Bool = false) {
        let offset = keepingCursor
            ? text.utf8.distance(from: text.utf8.startIndex, to: focus.samePosition(in: text.utf8)!)
            : new.utf8.count
        text = new
        revision = Self.nextRevision()
        // Same reason as `replace`: rows are character offsets into the old
        // buffer and describe nothing once it is gone. The view layer usually
        // reseeds immediately afterwards, but "usually" is not an invariant —
        // anything that reads `layout` in between walks past `endIndex`.
        visualRows = nil
        undoStack.clear()
        // Reads `text`, so it has to run after the assignment above. Clamping
        // and boundary-snapping both live in `index(atUTF8Offset:)`; doing them
        // here used to mean a full walk of the new buffer on every reload.
        focus = index(atUTF8Offset: offset)
        anchor = focus
    }

    // MARK: Helpers

    /// Character offset of an index. Characters, not bytes, so the value
    /// stays meaningful across graphemes of differing byte length.
    /// Character offset of `index`, measured from the last pair resolved.
    ///
    /// Both conversions here walk graphemes, so unaided they cost the
    /// *offset*, not the distance moved. Every vertical move makes one of
    /// each, so a caret near the end of a large file paid for the whole file
    /// to move one row — and Page Down, being a row move repeated a screenful
    /// of times, paid it thirty-odd times over. On a 4.7 MB buffer: 0.68ms per
    /// page at the top, 187ms twenty-seven thousand rows in, rising linearly
    /// and without bound. That is the reported symptom exactly — "the farther
    /// from the beginning, the laggier".
    ///
    /// Anchored, the cost is the distance travelled: a row for an arrow key, a
    /// screenful for a page, and flat with depth. `LeafNode` already does this
    /// for the draw and drag paths; here it is where the caret itself lives,
    /// so every caller gets it rather than the two that remembered to.
    public func offset(of index: String.Index) -> Int {
        let anchor = indexAnchor
        if anchor.revision == revision {
            if anchor.index == index { return anchor.offset }
            // Signed: the caret moves both ways, and `distance` walks
            // backwards from a later index perfectly well.
            let resolved = anchor.offset + text.distance(from: anchor.index, to: index)
            anchor.store(revision: revision, offset: resolved, index: index)
            return resolved
        }
        let resolved = text.distance(from: text.startIndex, to: index)
        anchor.store(revision: revision, offset: resolved, index: index)
        return resolved
    }

    /// Clamped with `limitedBy:` rather than against `text.count`, because
    /// `String.count` is a full grapheme-break walk of the buffer — O(length)
    /// regardless of how small `offset` is. The draw path calls this once per
    /// emit to reach the first visible row, so on a 10 MB log that single
    /// clamp cost ~12ms of *every* redraw, including ones that only moved a
    /// caret. `limitedBy:` costs O(min(offset, length)) and stops at the end.
    public func index(atOffset offset: Int) -> String.Index {
        guard offset > 0 else { return text.startIndex }
        let anchor = indexAnchor
        if anchor.revision == revision {
            let delta = offset - anchor.offset
            if delta == 0 { return anchor.index }
            let limit = delta > 0 ? text.endIndex : text.startIndex
            if let moved = text.index(anchor.index, offsetBy: delta, limitedBy: limit) {
                anchor.store(revision: revision, offset: offset, index: moved)
                return moved
            }
        }
        let resolved = text.index(text.startIndex, offsetBy: offset, limitedBy: text.endIndex)
            ?? text.endIndex
        anchor.store(revision: revision, offset: offset, index: resolved)
        return resolved
    }

    private func clamp(_ index: String.Index) -> String.Index {
        if index < text.startIndex { return text.startIndex }
        if index > text.endIndex { return text.endIndex }
        return index
    }

    /// UTF-8 offset of an index — O(1), because `String.Index` already stores
    /// its encoded byte offset and `UTF8View.distance` is a subtraction.
    ///
    /// This is the whole reason the edit path and the undo history speak
    /// bytes: the character-offset equivalent above walks the buffer. See
    /// `TextEdit`.
    func utf8Offset(of index: String.Index) -> Int {
        text.utf8.distance(from: text.utf8.startIndex, to: index)
    }

    /// Index at a UTF-8 offset, clamped to the buffer and snapped **down** to
    /// a character boundary.
    ///
    /// Snapping down rather than up matters for deletion: an offset landing
    /// inside a grapheme means the caret belongs at the start of the character
    /// containing it, not past it. The backwards walk is bounded by one
    /// grapheme cluster — two bytes for `"\r\n"`, a couple of dozen for the
    /// longest ZWJ emoji — and does not run at all on the ASCII path, where
    /// every byte is already a boundary.
    func index(atUTF8Offset offset: Int) -> String.Index {
        let utf8 = text.utf8
        guard offset > 0 else { return text.startIndex }
        guard offset < utf8.count else { return text.endIndex }
        var byteIndex = utf8.index(utf8.startIndex, offsetBy: offset)
        while byteIndex > utf8.startIndex {
            if let boundary = String.Index(byteIndex, within: text) { return boundary }
            byteIndex = utf8.index(before: byteIndex)
        }
        return text.startIndex
    }

    /// Word classification, hand-rolled on purpose: Foundation's
    /// `enumerateSubstrings(.byWords)` is unavailable in
    /// swift-corelibs-foundation, and pulling in ICU for this would be
    /// disproportionate. Identifier-style words (letters, digits, underscore)
    /// are also the right unit for a code editor, which is where this lands.
    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    /// Start of the word at or before `index`. Skips any run of separators
    /// first, so Ctrl+Left from mid-whitespace reaches the previous word
    /// rather than stopping at the gap.
    private func wordBoundary(before index: String.Index) -> String.Index {
        var i = index
        guard i > text.startIndex else { return i }

        while i > text.startIndex {
            let prev = text.index(before: i)
            if Self.isWordCharacter(text[prev]) { break }
            i = prev
        }
        while i > text.startIndex {
            let prev = text.index(before: i)
            if !Self.isWordCharacter(text[prev]) { break }
            i = prev
        }
        return i
    }

    /// End of the word at or after `index`, skipping leading separators.
    private func wordBoundary(after index: String.Index) -> String.Index {
        var i = index
        guard i < text.endIndex else { return i }

        while i < text.endIndex, !Self.isWordCharacter(text[i]) {
            i = text.index(after: i)
        }
        while i < text.endIndex, Self.isWordCharacter(text[i]) {
            i = text.index(after: i)
        }
        return i
    }
}

// MARK: - Lines and vertical movement

extension TextEditingState {
    /// Whether the buffer contains any hard line break.
    public var isMultiline: Bool { text.contains("\n") }

    /// Logical lines, split on "\n". A trailing newline yields a final empty
    /// line, which is correct: the caret can sit there.
    ///
    /// `Collection.split` compares `Character`s, so it grapheme-breaks the
    /// whole buffer to find bytes it could have scanned for — on a 4 MB log
    /// that is ~60 ms, and a wrapping editor asks for this on every keystroke.
    /// The scan below finds the newlines as bytes and cuts the same
    /// `Substring`s at them.
    public var lines: [Substring] {
        utf8Lines() ?? text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// Newline positions as byte offsets, or nil when a byte scan cannot
    /// answer.
    ///
    /// CR disqualifies the buffer, as everywhere else here: "\r\n" is a single
    /// `Character`, so a `String.Index` taken at the LF would not be on a
    /// grapheme boundary and slicing there is not the same split. A lone LF
    /// always is one, whatever surrounds it, which is what makes this exact
    /// for every other buffer including non-ASCII ones.
    private func utf8Lines() -> [Substring]? {
        let utf8 = text.utf8
        let scanned: [Int]?? = utf8.withContiguousStorageIfAvailable { bytes in
            var breaks: [Int] = []
            for i in 0..<bytes.count {
                if bytes[i] == 0x0D { return nil }
                if bytes[i] == 0x0A { breaks.append(i) }
            }
            return breaks
        }
        guard let breaks = scanned ?? nil else { return nil }

        var result: [Substring] = []
        result.reserveCapacity(breaks.count + 1)
        var lineStart = text.startIndex
        var cursorByte = 0
        var cursor = utf8.startIndex
        for position in breaks {
            let end = utf8.index(cursor, offsetBy: position - cursorByte)
            result.append(text[lineStart..<end])
            cursor = utf8.index(after: end)
            cursorByte = position + 1
            lineStart = cursor
        }
        result.append(text[lineStart...])
        return result
    }

    /// Range of the line containing `index`, excluding its terminator.
    public func lineRange(at index: String.Index) -> Range<String.Index> {
        var start = index
        while start > text.startIndex {
            let prev = text.index(before: start)
            if text[prev] == "\n" { break }
            start = prev
        }
        var end = index
        while end < text.endIndex, text[end] != "\n" {
            end = text.index(after: end)
        }
        return start..<end
    }

    /// Zero-based logical line number of `index`.
    public func lineIndex(of index: String.Index) -> Int {
        var count = 0
        var i = text.startIndex
        while i < index, i < text.endIndex {
            if text[i] == "\n" { count += 1 }
            i = text.index(after: i)
        }
        return count
    }

    /// Character offset of `index` within its own line.
    public func column(of index: String.Index) -> Int {
        text.distance(from: lineRange(at: index).lowerBound, to: index)
    }

    /// Start index of line `n`, or `endIndex` if `n` is past the last line.
    public func startOfLine(_ n: Int) -> String.Index {
        guard n > 0 else { return text.startIndex }
        var seen = 0
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\n" {
                seen += 1
                let next = text.index(after: i)
                if seen == n { return next }
                i = next
            } else {
                i = text.index(after: i)
            }
        }
        return text.endIndex
    }

    /// Index at `line`/`column`, clamped to that line's length.
    public func index(line: Int, column: Int) -> String.Index {
        let start = startOfLine(line)
        let end = lineRange(at: start).upperBound
        let available = text.distance(from: start, to: end)
        return text.index(start, offsetBy: min(max(0, column), available))
    }

    // MARK: Home / End are per-line once there is more than one

    /// Home/End act on the *visual* row, matching what the user sees. When
    /// nothing is wrapped this is the same as the logical line.
    public mutating func moveToLineStart(extending: Bool = false) {
        let l = layout
        let row = l.rows[l.rowIndex(ofOffset: offset(of: focus), affinity: affinity)]
        focus = index(atOffset: row.lowerBound)
        affinity = .downstream
        if !extending { anchor = focus }
        desiredColumn = nil
        affinity = .downstream
    }

    public mutating func moveToLineEnd(extending: Bool = false) {
        let l = layout
        let row = l.rows[l.rowIndex(ofOffset: offset(of: focus), affinity: affinity)]
        focus = index(atOffset: row.upperBound)
        affinity = .upstream
        if !extending { anchor = focus }
        desiredColumn = nil
        affinity = .downstream
    }

    // MARK: Vertical

    /// Moves up one line, preserving the column the user *started* from.
    ///
    /// The remembered column is the whole point. Without it, stepping down
    /// through a short line and back up strands the caret at that short line's
    /// end instead of returning to the original column — the classic
    /// multi-line caret bug, and invisible until someone navigates ragged text.
    public mutating func moveUp(extending: Bool = false) {
        let l = layout
        let here = offset(of: focus)
        let row = l.rowIndex(ofOffset: here, affinity: affinity)
        guard row > 0 else {
            focus = text.startIndex
            if !extending { anchor = focus }
            return
        }
        let target = desiredColumn ?? l.column(ofOffset: here, affinity: affinity)
        let landed = l.offset(row: row - 1, column: target)
        // Clamped to the row's end: stay on that row rather than jumping to
        // the start of the next one, which is the same offset.
        affinity = landed == l.rows[row - 1].upperBound ? .upstream : .downstream
        focus = index(atOffset: landed)
        if !extending { anchor = focus }
        desiredColumn = target
    }

    public mutating func moveDown(extending: Bool = false) {
        let l = layout
        let here = offset(of: focus)
        let row = l.rowIndex(ofOffset: here, affinity: affinity)
        guard row < l.count - 1 else {
            focus = text.endIndex
            if !extending { anchor = focus }
            return
        }
        let target = desiredColumn ?? l.column(ofOffset: here, affinity: affinity)
        let landed = l.offset(row: row + 1, column: target)
        affinity = landed == l.rows[row + 1].upperBound ? .upstream : .downstream
        focus = index(atOffset: landed)
        if !extending { anchor = focus }
        desiredColumn = target
    }
}
