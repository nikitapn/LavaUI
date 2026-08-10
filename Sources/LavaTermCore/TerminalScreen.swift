import Foundation

/// Grid buffer + cursor for a VT-like terminal.
public final class TerminalScreen: @unchecked Sendable {
    public private(set) var cols: Int
    public private(set) var rows: Int
    /// Row-major cells of the *active* buffer (main or alternate).
    public private(set) var cells: [TerminalCell]
    public private(set) var cursorCol: Int = 0
    public private(set) var cursorRow: Int = 0
    public private(set) var cursorVisible: Bool = true
    /// DECCKM: when set, arrow keys send application sequences (`ESC O A`)
    /// rather than ANSI ones (`ESC [ A`). Full-screen tools (tmux, vim)
    /// turn this on and expect the other spelling.
    public private(set) var applicationCursorKeys: Bool = false
    /// Whether the alternate screen is showing. Exposed so tests can assert
    /// the switch happened without reading private storage.
    public private(set) var onAlternateScreen: Bool = false

    public private(set) var currentFg: TerminalColor = .defaultForeground
    public private(set) var currentBg: TerminalColor = .defaultBackground
    public private(set) var bold: Bool = false
    public private(set) var inverse: Bool = false
    public private(set) var underline: Bool = false

    private var scrollTop: Int = 0
    private var scrollBottom: Int
    private var savedCol: Int = 0
    private var savedRow: Int = 0
    private var originMode = false

    /// Main buffer while the alternate screen is active. Nil on the main
    /// screen. Swapping rather than copying keeps enter/leave O(1) in the
    /// cell count sense (just a pointer swap of two arrays).
    private var mainCells: [TerminalCell]?
    private var mainCursorCol: Int = 0
    private var mainCursorRow: Int = 0
    private var mainScrollTop: Int = 0
    private var mainScrollBottom: Int = 0

    private let parser = AnsiParser()

    public init(cols: Int = 80, rows: Int = 24) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.cells = Array(repeating: .empty, count: self.cols * self.rows)
        self.scrollBottom = self.rows - 1
    }

    public func resize(cols newCols: Int, rows newRows: Int) {
        let nc = max(1, newCols)
        let nr = max(1, newRows)
        guard nc != cols || nr != rows else { return }
        cells = resizeBuffer(cells, fromCols: cols, fromRows: rows, toCols: nc, toRows: nr)
        if var saved = mainCells {
            saved = resizeBuffer(saved, fromCols: cols, fromRows: rows, toCols: nc, toRows: nr)
            mainCells = saved
            mainCursorCol = min(mainCursorCol, nc - 1)
            mainCursorRow = min(mainCursorRow, nr - 1)
            mainScrollTop = 0
            mainScrollBottom = nr - 1
        }
        cols = nc
        rows = nr
        scrollTop = 0
        scrollBottom = rows - 1
        cursorCol = min(cursorCol, cols - 1)
        cursorRow = min(cursorRow, rows - 1)
    }

    private func resizeBuffer(
        _ source: [TerminalCell], fromCols: Int, fromRows: Int,
        toCols: Int, toRows: Int
    ) -> [TerminalCell] {
        var next = Array(repeating: TerminalCell.empty, count: toCols * toRows)
        let copyRows = min(fromRows, toRows)
        let copyCols = min(fromCols, toCols)
        for r in 0..<copyRows {
            for c in 0..<copyCols {
                next[r * toCols + c] = source[r * fromCols + c]
            }
        }
        return next
    }

    public func cell(row: Int, col: Int) -> TerminalCell {
        guard row >= 0, row < rows, col >= 0, col < cols else { return .empty }
        return cells[row * cols + col]
    }

    /// Ingest PTY output.
    public func feed(_ data: Data) {
        for op in parser.feed(data) {
            apply(op)
        }
    }

    /// Ingest a UTF-8 string (tests / scripted input).
    public func feed(_ string: String) {
        feed(Data(string.utf8))
    }

    // MARK: - Apply

    private func apply(_ op: AnsiParser.Output) {
        switch op {
        case .print(let s):
            put(s)
        case .bell:
            break
        case .backspace:
            if cursorCol > 0 { cursorCol -= 1 }
        case .tab:
            let next = ((cursorCol / 8) + 1) * 8
            cursorCol = min(cols - 1, next)
        case .lineFeed:
            // Pending wrap: cursor may sit at `cols` after the last cell.
            // Clear it so the next print does not also wrap (double advance).
            if cursorCol >= cols { cursorCol = 0 }
            lineFeed()
        case .carriageReturn:
            cursorCol = 0
        case .cursorUp(let n):
            cursorRow = max(scrollTop, cursorRow - n)
        case .cursorDown(let n):
            cursorRow = min(scrollBottom, cursorRow + n)
        case .cursorForward(let n):
            cursorCol = min(cols - 1, cursorCol + n)
        case .cursorBack(let n):
            cursorCol = max(0, cursorCol - n)
        case .cursorPosition(let row, let col):
            // 1-based; 0 means "keep" for partial CUP variants we map oddly
            if row > 0 { cursorRow = min(rows - 1, max(0, row - 1)) }
            if col > 0 { cursorCol = min(cols - 1, max(0, col - 1)) }
        case .eraseDisplay(let mode):
            eraseDisplay(mode)
        case .eraseLine(let mode):
            eraseLine(mode)
        case .setGraphics(let params):
            applySGR(params)
        case .scrollUp(let n):
            for _ in 0..<n { scrollUp() }
        case .scrollDown(let n):
            for _ in 0..<n { scrollDown() }
        case .saveCursor:
            savedCol = cursorCol
            savedRow = cursorRow
        case .restoreCursor:
            cursorCol = min(cols - 1, savedCol)
            cursorRow = min(rows - 1, savedRow)
        case .setScrollRegion(let top, let bottom):
            // DECSTBM: top and bottom are 1-based inclusive. Empty / zero bottom
            // means "default" (the whole screen). Equal margins are legal and
            // give a one-line region.
            let t = max(0, top - 1)
            let b = bottom == 0 ? rows - 1 : min(rows - 1, bottom - 1)
            if t <= b {
                scrollTop = t
                scrollBottom = b
                cursorCol = 0
                cursorRow = scrollTop
            }
        case .deleteChars(let n):
            deleteChars(n)
        case .insertChars(let n):
            insertChars(n)
        case .eraseChars(let n):
            eraseChars(n)
        case .deleteLines(let n):
            deleteLines(n)
        case .insertLines(let n):
            insertLines(n)
        case .privateModes(let modes, let set):
            for mode in modes {
                applyPrivateMode(mode, set: set)
            }
        case .ignore:
            break
        }
    }

    /// DECSET / DECRST. Only the modes a full-screen tool actually needs are
    /// implemented; the rest are acknowledged and ignored so a sequence does
    /// not leave the parser in a bad state.
    private func applyPrivateMode(_ mode: Int, set: Bool) {
        switch mode {
        case 1:
            // DECCKM — application cursor keys.
            applicationCursorKeys = set
        case 25:
            // DECTCEM — show / hide cursor.
            cursorVisible = set
        case 47, 1047:
            // Alternate screen, without (47/1047) or with (1049) a cursor
            // save. Enter clears the alt buffer so the previous full-screen
            // app does not flash through.
            if set {
                enterAlternateScreen(saveCursor: false)
            } else {
                leaveAlternateScreen(restoreCursor: false)
            }
        case 1048:
            if set {
                savedCol = cursorCol
                savedRow = cursorRow
            } else {
                cursorCol = min(cols - 1, savedCol)
                cursorRow = min(rows - 1, savedRow)
            }
        case 1049:
            if set {
                enterAlternateScreen(saveCursor: true)
            } else {
                leaveAlternateScreen(restoreCursor: true)
            }
        default:
            break
        }
    }

    private func enterAlternateScreen(saveCursor: Bool) {
        if saveCursor {
            savedCol = cursorCol
            savedRow = cursorRow
        }
        guard !onAlternateScreen else {
            // Already on alt: clear it, which is what a second 1049h from a
            // nested tool should do rather than stacking another buffer.
            for i in cells.indices { cells[i] = .empty }
            cursorCol = 0
            cursorRow = 0
            scrollTop = 0
            scrollBottom = rows - 1
            return
        }
        mainCells = cells
        mainCursorCol = cursorCol
        mainCursorRow = cursorRow
        mainScrollTop = scrollTop
        mainScrollBottom = scrollBottom
        cells = Array(repeating: .empty, count: cols * rows)
        cursorCol = 0
        cursorRow = 0
        scrollTop = 0
        scrollBottom = rows - 1
        onAlternateScreen = true
    }

    private func leaveAlternateScreen(restoreCursor: Bool) {
        guard onAlternateScreen, let saved = mainCells else {
            // Already on main: still honour a restore so a lone 1049l after
            // a crash does not leave the cursor wherever the alt left it.
            if restoreCursor {
                cursorCol = min(cols - 1, savedCol)
                cursorRow = min(rows - 1, savedRow)
            }
            return
        }
        cells = saved
        mainCells = nil
        scrollTop = mainScrollTop
        scrollBottom = min(rows - 1, mainScrollBottom)
        if restoreCursor {
            cursorCol = min(cols - 1, savedCol)
            cursorRow = min(rows - 1, savedRow)
        } else {
            cursorCol = min(cols - 1, mainCursorCol)
            cursorRow = min(rows - 1, mainCursorRow)
        }
        onAlternateScreen = false
    }

    private func put(_ s: Unicode.Scalar) {
        // C1 / control shouldn't land here
        if s.value < 0x20 || s.value == 0x7F { return }
        if cursorCol >= cols {
            cursorCol = 0
            lineFeed()
        }
        let idx = cursorRow * cols + cursorCol
        cells[idx] = TerminalCell(
            scalar: s,
            fg: currentFg,
            bg: currentBg,
            bold: bold,
            inverse: inverse,
            underline: underline
        )
        cursorCol += 1
    }

    private func lineFeed() {
        // Scroll only when the cursor is *inside* the scrolling region and on
        // its bottom margin. A line feed on the status line (below the region)
        // must not scroll the pane away — that is how tmux's status bar works.
        if cursorRow >= scrollTop && cursorRow <= scrollBottom {
            if cursorRow == scrollBottom {
                scrollUp()
            } else {
                cursorRow += 1
            }
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    private func scrollUp() {
        let width = cols
        let top = scrollTop
        let bottom = scrollBottom
        if top > bottom { return }
        for r in top..<bottom {
            let dst = r * width
            let src = (r + 1) * width
            for c in 0..<width {
                cells[dst + c] = cells[src + c]
            }
        }
        let last = bottom * width
        for c in 0..<width {
            cells[last + c] = blankCell()
        }
    }

    private func scrollDown() {
        let width = cols
        let top = scrollTop
        let bottom = scrollBottom
        if top > bottom { return }
        for r in stride(from: bottom, through: top + 1, by: -1) {
            let dst = r * width
            let src = (r - 1) * width
            for c in 0..<width {
                cells[dst + c] = cells[src + c]
            }
        }
        let first = top * width
        for c in 0..<width {
            cells[first + c] = blankCell()
        }
    }

    private func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseFromCursorToEnd()
        case 1:
            eraseFromStartToCursor()
        default:
            for i in cells.indices { cells[i] = blankCell() }
            if mode == 3 {
                // xterm clear scrollback — we have no scrollback buffer yet
            }
        }
    }

    private func eraseLine(_ mode: Int) {
        let base = cursorRow * cols
        switch mode {
        case 0:
            for c in cursorCol..<cols { cells[base + c] = blankCell() }
        case 1:
            for c in 0...cursorCol where c < cols { cells[base + c] = blankCell() }
        default:
            for c in 0..<cols { cells[base + c] = blankCell() }
        }
    }

    private func eraseFromCursorToEnd() {
        eraseLine(0)
        if cursorRow + 1 < rows {
            for i in ((cursorRow + 1) * cols)..<cells.count {
                cells[i] = blankCell()
            }
        }
    }

    private func eraseFromStartToCursor() {
        if cursorRow > 0 {
            for i in 0..<(cursorRow * cols) {
                cells[i] = blankCell()
            }
        }
        eraseLine(1)
    }

    private func deleteChars(_ n: Int) {
        let base = cursorRow * cols
        let count = min(n, cols - cursorCol)
        for c in cursorCol..<(cols - count) {
            cells[base + c] = cells[base + c + count]
        }
        for c in (cols - count)..<cols {
            cells[base + c] = blankCell()
        }
    }

    private func insertChars(_ n: Int) {
        let base = cursorRow * cols
        let count = min(n, cols - cursorCol)
        for c in stride(from: cols - 1, through: cursorCol + count, by: -1) {
            cells[base + c] = cells[base + c - count]
        }
        for c in cursorCol..<(cursorCol + count) {
            cells[base + c] = blankCell()
        }
    }

    private func eraseChars(_ n: Int) {
        let base = cursorRow * cols
        let end = min(cols, cursorCol + n)
        for c in cursorCol..<end {
            cells[base + c] = blankCell()
        }
    }

    private func deleteLines(_ n: Int) {
        let count = min(n, scrollBottom - cursorRow + 1)
        let width = cols
        for r in cursorRow...(scrollBottom - count) {
            let dst = r * width
            let src = (r + count) * width
            for c in 0..<width { cells[dst + c] = cells[src + c] }
        }
        for r in (scrollBottom - count + 1)...scrollBottom {
            let base = r * width
            for c in 0..<width { cells[base + c] = blankCell() }
        }
    }

    private func insertLines(_ n: Int) {
        let count = min(n, scrollBottom - cursorRow + 1)
        let width = cols
        for r in stride(from: scrollBottom, through: cursorRow + count, by: -1) {
            let dst = r * width
            let src = (r - count) * width
            for c in 0..<width { cells[dst + c] = cells[src + c] }
        }
        for r in cursorRow..<(cursorRow + count) {
            let base = r * width
            for c in 0..<width { cells[base + c] = blankCell() }
        }
    }

    private func blankCell() -> TerminalCell {
        TerminalCell(
            scalar: " ",
            fg: currentFg,
            bg: currentBg,
            bold: false,
            inverse: false,
            underline: false
        )
    }

    private func applySGR(_ params: [Int]) {
        if params.isEmpty {
            resetAttrs()
            return
        }
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:
                resetAttrs()
            case 1:
                bold = true
            case 2, 22:
                bold = false
            case 4:
                underline = true
            case 24:
                underline = false
            case 7:
                inverse = true
            case 27:
                inverse = false
            case 30...37:
                currentFg = .index(UInt8(p - 30))
            case 39:
                currentFg = .defaultForeground
            case 40...47:
                currentBg = .index(UInt8(p - 40))
            case 49:
                currentBg = .defaultBackground
            case 90...97:
                currentFg = .index(UInt8(p - 90 + 8))
            case 100...107:
                currentBg = .index(UInt8(p - 100 + 8))
            case 38:
                // 38;5;n or 38;2;r;g;b
                if i + 1 < params.count {
                    let mode = params[i + 1]
                    if mode == 5, i + 2 < params.count {
                        currentFg = .index(UInt8(clamping: params[i + 2]))
                        i += 2
                    } else if mode == 2, i + 4 < params.count {
                        currentFg = .rgb(
                            UInt8(clamping: params[i + 2]),
                            UInt8(clamping: params[i + 3]),
                            UInt8(clamping: params[i + 4])
                        )
                        i += 4
                    }
                }
            case 48:
                if i + 1 < params.count {
                    let mode = params[i + 1]
                    if mode == 5, i + 2 < params.count {
                        currentBg = .index(UInt8(clamping: params[i + 2]))
                        i += 2
                    } else if mode == 2, i + 4 < params.count {
                        currentBg = .rgb(
                            UInt8(clamping: params[i + 2]),
                            UInt8(clamping: params[i + 3]),
                            UInt8(clamping: params[i + 4])
                        )
                        i += 4
                    }
                }
            default:
                break
            }
            i += 1
        }
    }

    private func resetAttrs() {
        currentFg = .defaultForeground
        currentBg = .defaultBackground
        bold = false
        inverse = false
        underline = false
    }
}
