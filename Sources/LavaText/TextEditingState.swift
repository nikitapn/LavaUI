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

    public init(_ text: String = "") {
        self.text = text
        self.anchor = text.startIndex
        self.focus = text.startIndex
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
    }

    /// Collapses to the caret end, as typing or a plain arrow key should.
    public mutating func clearSelection() { anchor = focus }

    public mutating func setCursor(_ index: String.Index, extending: Bool = false) {
        focus = clamp(index)
        if !extending { anchor = focus }
        desiredColumn = nil
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
    }

    public mutating func moveToStart(extending: Bool = false) {
        focus = text.startIndex
        if !extending { anchor = focus }
        desiredColumn = nil
    }

    public mutating func moveToEnd(extending: Bool = false) {
        focus = text.endIndex
        if !extending { anchor = focus }
        desiredColumn = nil
    }

    public mutating func moveWordLeft(extending: Bool = false) {
        focus = wordBoundary(before: focus)
        if !extending { anchor = focus }
        desiredColumn = nil
    }

    public mutating func moveWordRight(extending: Bool = false) {
        focus = wordBoundary(after: focus)
        if !extending { anchor = focus }
        desiredColumn = nil
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
        let start = offset(of: range.lowerBound)
        let removed = String(text[range])
        guard !(removed.isEmpty && replacement.isEmpty) else { return }

        if record {
            undoStack.record(TextEdit(
                offset: start,
                removed: removed,
                inserted: replacement,
                anchorBefore: offset(of: anchor),
                focusBefore: offset(of: focus)
            ))
        }

        text.replaceSubrange(range, with: replacement)
        let caret = index(atOffset: start + replacement.count)
        focus = caret
        anchor = caret
        desiredColumn = nil
    }

    // MARK: Undo / redo

    public var canUndo: Bool { undoStack.canUndo }
    public var canRedo: Bool { undoStack.canRedo }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let edit = undoStack.popUndo() else { return false }
        apply(edit.inverted)
        // Restore where the user was, not just what the text was.
        anchor = index(atOffset: edit.anchorBefore)
        focus = index(atOffset: edit.focusBefore)
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
        let lower = index(atOffset: edit.offset)
        let upper = index(atOffset: edit.offset + edit.removed.count)
        text.replaceSubrange(lower..<upper, with: edit.inserted)
        let caret = index(atOffset: edit.offset + edit.inserted.count)
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
        undoStack.clear()
        let clamped = min(offset, new.utf8.count)
        let byteIndex = new.utf8.index(new.utf8.startIndex, offsetBy: clamped)
        focus = snapToCharacterBoundary(String.Index(byteIndex, within: new) ?? new.endIndex)
        anchor = focus
    }

    // MARK: Helpers

    /// Character offset of an index. Characters, not bytes, so the value
    /// stays meaningful across graphemes of differing byte length.
    func offset(of index: String.Index) -> Int {
        text.distance(from: text.startIndex, to: index)
    }

    func index(atOffset offset: Int) -> String.Index {
        let clamped = max(0, min(offset, text.count))
        return text.index(text.startIndex, offsetBy: clamped)
    }

    private func clamp(_ index: String.Index) -> String.Index {
        if index < text.startIndex { return text.startIndex }
        if index > text.endIndex { return text.endIndex }
        return index
    }

    /// A UTF-8 offset can land inside a grapheme; a caret never should.
    private func snapToCharacterBoundary(_ index: String.Index) -> String.Index {
        var i = text.startIndex
        while i < text.endIndex {
            if i >= index { return i }
            i = text.index(after: i)
        }
        return text.endIndex
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
    public var lines: [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
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

    public mutating func moveToLineStart(extending: Bool = false) {
        focus = lineRange(at: focus).lowerBound
        if !extending { anchor = focus }
        desiredColumn = nil
    }

    public mutating func moveToLineEnd(extending: Bool = false) {
        focus = lineRange(at: focus).upperBound
        if !extending { anchor = focus }
        desiredColumn = nil
    }

    // MARK: Vertical

    /// Moves up one line, preserving the column the user *started* from.
    ///
    /// The remembered column is the whole point. Without it, stepping down
    /// through a short line and back up strands the caret at that short line's
    /// end instead of returning to the original column — the classic
    /// multi-line caret bug, and invisible until someone navigates ragged text.
    public mutating func moveUp(extending: Bool = false) {
        let line = lineIndex(of: focus)
        guard line > 0 else {
            // Already on the first line: go to its start, like every editor.
            focus = text.startIndex
            if !extending { anchor = focus }
            return
        }
        let target = desiredColumn ?? column(of: focus)
        focus = index(line: line - 1, column: target)
        if !extending { anchor = focus }
        desiredColumn = target
    }

    public mutating func moveDown(extending: Bool = false) {
        let line = lineIndex(of: focus)
        let lastLine = lines.count - 1
        guard line < lastLine else {
            focus = text.endIndex
            if !extending { anchor = focus }
            return
        }
        let target = desiredColumn ?? column(of: focus)
        focus = index(line: line + 1, column: target)
        if !extending { anchor = focus }
        desiredColumn = target
    }
}
