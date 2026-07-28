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

    public mutating func selectAll() {
        anchor = text.startIndex
        focus = text.endIndex
    }

    /// Collapses to the caret end, as typing or a plain arrow key should.
    public mutating func clearSelection() { anchor = focus }

    public mutating func setCursor(_ index: String.Index, extending: Bool = false) {
        focus = clamp(index)
        if !extending { anchor = focus }
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
    }

    public mutating func moveToStart(extending: Bool = false) {
        focus = text.startIndex
        if !extending { anchor = focus }
    }

    public mutating func moveToEnd(extending: Bool = false) {
        focus = text.endIndex
        if !extending { anchor = focus }
    }

    public mutating func moveWordLeft(extending: Bool = false) {
        focus = wordBoundary(before: focus)
        if !extending { anchor = focus }
    }

    public mutating func moveWordRight(extending: Bool = false) {
        focus = wordBoundary(after: focus)
        if !extending { anchor = focus }
    }

    // MARK: Editing

    public mutating func insert(_ string: String) {
        guard !string.isEmpty || hasSelection else { return }
        let range = selectedRange
        text.replaceSubrange(range, with: string)
        // replaceSubrange invalidates indices; recompute from the offset the
        // edit started at plus what we inserted.
        let start = text.utf8.index(
            text.utf8.startIndex, offsetBy: text.utf8.distance(
                from: text.utf8.startIndex, to: range.lowerBound.samePosition(in: text.utf8)!
            )
        )
        let inserted = string.utf8.count
        let end = text.utf8.index(start, offsetBy: inserted)
        focus = snapToCharacterBoundary(String.Index(end, within: text) ?? text.endIndex)
        anchor = focus
    }

    public mutating func deleteBackward() {
        if hasSelection {
            deleteSelection()
            return
        }
        guard focus > text.startIndex else { return }
        // index(before:) steps a whole grapheme, so one press removes one
        // user-perceived character rather than half an emoji.
        let from = text.index(before: focus)
        text.removeSubrange(from..<focus)
        focus = from
        anchor = from
    }

    public mutating func deleteForward() {
        if hasSelection {
            deleteSelection()
            return
        }
        guard focus < text.endIndex else { return }
        let to = text.index(after: focus)
        text.removeSubrange(focus..<to)
        anchor = focus
    }

    public mutating func deleteWordBackward() {
        if hasSelection {
            deleteSelection()
            return
        }
        let from = wordBoundary(before: focus)
        guard from < focus else { return }
        text.removeSubrange(from..<focus)
        focus = from
        anchor = from
    }

    private mutating func deleteSelection() {
        let range = selectedRange
        guard !range.isEmpty else { return }
        text.removeSubrange(range)
        focus = range.lowerBound
        anchor = focus
    }

    /// Replaces the whole buffer, e.g. when the bound value changed elsewhere.
    public mutating func setText(_ new: String, keepingCursor: Bool = false) {
        let offset = keepingCursor
            ? text.utf8.distance(from: text.utf8.startIndex, to: focus.samePosition(in: text.utf8)!)
            : new.utf8.count
        text = new
        let clamped = min(offset, new.utf8.count)
        let byteIndex = new.utf8.index(new.utf8.startIndex, offsetBy: clamped)
        focus = snapToCharacterBoundary(String.Index(byteIndex, within: new) ?? new.endIndex)
        anchor = focus
    }

    // MARK: Helpers

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
