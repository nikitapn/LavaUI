import Foundation

/// Where a cell is, in the grid rather than on the screen.
///
/// Ordered reading order — down a row beats along a column — which is what
/// makes a selection between two cells a range rather than a rectangle.
public struct CellPosition: Equatable, Comparable, Sendable {
    public var row: Int
    public var col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }

    public static func < (a: CellPosition, b: CellPosition) -> Bool {
        a.row == b.row ? a.col < b.col : a.row < b.row
    }
}

/// The arithmetic that turns a cell into pixels, and pixels back into a cell.
///
/// It existed before this file, inline in the paint closure and discarded a
/// line later, which is the whole reason selection looked hard: a `Canvas`
/// hands the app a press at *some pixel*, and nothing could say which
/// character that was. Painting and hit-testing being the same four numbers is
/// not a coincidence to exploit later — it is the thing that has to be true for
/// a click to land where it looks like it landed.
public struct TerminalGeometry {
    public var originX: Float
    public var originY: Float
    public var cellW: Float
    public var cellH: Float
    public var cols: Int
    public var rows: Int

    public init(
        originX: Float, originY: Float, cellW: Float, cellH: Float,
        cols: Int, rows: Int
    ) {
        self.originX = originX
        self.originY = originY
        self.cellW = cellW
        self.cellH = cellH
        self.cols = cols
        self.rows = rows
    }

    public func x(col: Int) -> Float { originX + Float(col) * cellW }
    public func y(row: Int) -> Float { originY + Float(row) * cellH }

    /// The cell under a point, clamped to the grid.
    ///
    /// Clamped rather than optional because every caller is a drag: a pointer
    /// dragged off the right edge means "to the end of the line", and one
    /// dragged above the top means "from the first row" — an optional would
    /// make both of those a special case at the call site, and they are the
    /// normal case.
    public func cell(atX px: Float, y py: Float) -> CellPosition {
        let col = Int(((px - originX) / cellW).rounded(.down))
        let row = Int(((py - originY) / cellH).rounded(.down))
        return CellPosition(
            row: min(max(0, row), max(0, rows - 1)),
            col: min(max(0, col), max(0, cols - 1))
        )
    }
}

/// A range of cells the user has chosen, and how they chose it.
///
/// Anchor and focus rather than start and end, for the reason every text
/// selection uses them: dragging backwards past where you began is normal, and
/// a selection that stored its ends in order would forget which one the
/// pointer is holding.
public struct TerminalSelection {
    /// What one press picks: a character, the word it is inside, or the whole
    /// row. Once chosen it governs the whole drag, so a double-click-and-drag
    /// extends word by word — which is the behaviour that makes double-click
    /// worth having rather than a shortcut for one word.
    public enum Granularity {
        case character, word, line
    }

    public private(set) var granularity: Granularity = .character
    /// The span the press itself covered. A word- or line-granularity drag is
    /// the union of this and the span under the pointer now, which is what
    /// keeps whole words whole at both ends.
    private var anchorSpan: (first: CellPosition, last: CellPosition)?
    private var focusSpan: (first: CellPosition, last: CellPosition)?
    /// Where the press landed, so a later extend can tell whether the pointer
    /// has actually gone anywhere.
    private var pressed: CellPosition?
    /// Whether the pointer reached a *different cell* before it was let go.
    ///
    /// Not "whether an extend arrived": a release commonly delivers one last
    /// move at the position it is releasing at, and counting that would make
    /// every click a one-cell drag — so a plain click would leave a single
    /// highlighted character behind instead of clearing the selection. Sticky
    /// once set, because a drag that wanders and comes back is still a drag.
    public private(set) var dragged = false

    public init() {}

    public var isEmpty: Bool { range == nil }

    /// The whole selection, in reading order, inclusive at both ends.
    public var range: ClosedRange<CellPosition>? {
        guard let anchorSpan, let focusSpan else { return nil }
        let first = min(anchorSpan.first, focusSpan.first)
        let last = max(anchorSpan.last, focusSpan.last)
        return first...last
    }

    public mutating func begin(
        at position: CellPosition, granularity: Granularity, in screen: TerminalScreen
    ) {
        self.granularity = granularity
        pressed = position
        dragged = false
        // A character-granularity press is only a *pending* selection: a plain
        // click should not light up one cell (and fill the primary selection
        // with one character). Word and line presses are deliberate picks and
        // take effect on the press itself.
        if granularity == .character {
            anchorSpan = nil
            focusSpan = nil
        } else {
            anchorSpan = TerminalSelection.span(
                at: position, granularity: granularity, in: screen)
            focusSpan = anchorSpan
        }
    }

    public mutating func extend(to position: CellPosition, in screen: TerminalScreen) {
        guard let pressed else { return }
        if granularity == .character {
            // Still sitting on the press cell: not a drag yet. A release
            // commonly delivers one last move here, and counting it would make
            // every click a one-cell selection.
            if position == pressed && !dragged { return }
            if !dragged {
                anchorSpan = TerminalSelection.span(
                    at: pressed, granularity: .character, in: screen)
                dragged = true
            }
            focusSpan = TerminalSelection.span(
                at: position, granularity: .character, in: screen)
            return
        }
        guard anchorSpan != nil else { return }
        focusSpan = TerminalSelection.span(
            at: position, granularity: granularity, in: screen)
        if position != pressed { dragged = true }
    }

    public mutating func clear() {
        anchorSpan = nil
        focusSpan = nil
        pressed = nil
        dragged = false
        granularity = .character
    }

    /// The columns of `row` that are inside the selection, or nil if none are.
    ///
    /// Shared by the paint pass and the copy, so a highlight can never cover
    /// something the clipboard would not get.
    public func columns(inRow row: Int, cols: Int) -> ClosedRange<Int>? {
        guard let range, cols > 0, row >= range.lowerBound.row,
              row <= range.upperBound.row
        else { return nil }
        let first = row == range.lowerBound.row ? range.lowerBound.col : 0
        let last = row == range.upperBound.row ? range.upperBound.col : cols - 1
        guard first <= last else { return nil }
        return min(first, cols - 1)...min(last, cols - 1)
    }

    /// What the clipboard should get.
    ///
    /// Trailing blanks are dropped per row: a terminal row is always the full
    /// width, so keeping them would paste a rectangle of spaces for what
    /// looked like a sentence.
    public func text(from screen: TerminalScreen) -> String {
        guard let range else { return "" }
        var lines: [String] = []
        for row in range.lowerBound.row...range.upperBound.row {
            guard row < screen.rows,
                  let columns = columns(inRow: row, cols: screen.cols)
            else { continue }
            var line = ""
            for col in columns where col < screen.cols {
                // visibleCell: a selection made while scrolled into history
                // must copy what was under the pointer, not the live screen
                // underneath.
                line.unicodeScalars.append(screen.visibleCell(row: row, col: col).scalar)
            }
            while line.last == " " { line.removeLast() }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - What one press covers

    private static func span(
        at position: CellPosition, granularity: Granularity, in screen: TerminalScreen
    ) -> (first: CellPosition, last: CellPosition) {
        switch granularity {
        case .character:
            return (position, position)
        case .line:
            return (CellPosition(row: position.row, col: 0),
                    CellPosition(row: position.row, col: max(0, screen.cols - 1)))
        case .word:
            guard position.col < screen.cols, position.row < screen.rows,
                  isWord(screen.visibleCell(row: position.row, col: position.col).scalar)
            else { return (position, position) }
            var first = position.col, last = position.col
            while first > 0,
                  isWord(screen.visibleCell(row: position.row, col: first - 1).scalar)
            { first -= 1 }
            while last + 1 < screen.cols,
                  isWord(screen.visibleCell(row: position.row, col: last + 1).scalar)
            { last += 1 }
            return (CellPosition(row: position.row, col: first),
                    CellPosition(row: position.row, col: last))
        }
    }

    /// What counts as one word to double-click.
    ///
    /// Wider than a word in prose, because what is on a terminal screen is
    /// mostly paths, flags and URLs — and double-clicking `/usr/share/applications`
    /// to get three separate selections would be useless exactly where this is
    /// used most.
    private static func isWord(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.alphanumerics.contains(scalar) { return true }
        return "_-./~:@+=%#?&".unicodeScalars.contains(scalar)
    }
}
