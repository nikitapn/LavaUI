import Foundation

/// Grid buffer + cursor for a VT-like terminal.
public final class TerminalScreen: @unchecked Sendable {
    public private(set) var cols: Int
    public private(set) var rows: Int
    /// Row-major cells of the *active* buffer (main or alternate), the
    /// visible rows only. A copy: the screen itself goes through `grid`.
    public var cells: [TerminalCell] {
        Array(grid[index(0, 0)..<index(rows, 0)])
    }
    /// The active buffer, with `spareRows` more rows than are visible, and
    /// the visible ones starting `origin` rows in. A line feed at the bottom
    /// of the screen moves `origin` instead of the screen: moving every row up
    /// by one was a memmove of the whole grid per line, most of what printing
    /// a fast program's output cost — and it grows with the window, so a
    /// maximized terminal paid several times what the benchmark shows. The
    /// rows go back to the start once the spares run out, one move per
    /// `spareRows` lines.
    private var grid: [TerminalCell]
    private var origin = 0
    private static let spareRows = 64
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

    /// Last OSC 0/1/2 title the shell sent. Empty until the first one.
    public private(set) var windowTitle: String = ""
    /// Last OSC 7 working directory (filesystem path). Empty until reported.
    public private(set) var workingDirectory: String = ""
    /// Set by OSC 52. The host copies it to the seat selection and clears it.
    public var pendingClipboard: String?

    /// How many lines above the live screen the view is currently showing.
    /// Zero is "follow the bottom"; positive means the user has scrolled up
    /// into history. The alternate screen has no history, so this stays 0 there.
    public private(set) var viewOffset: Int = 0

    /// Lines held above the live screen on the primary buffer. Capped so a
    /// long-running shell cannot grow forever.
    public private(set) var scrollbackLineCount: Int = 0

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

    /// Primary-screen history. Each entry is one full row of `cols` cells.
    /// Only lines that scroll off the top of the *main* screen land here —
    /// the alternate screen is ephemeral, which is what full-screen tools
    /// assume.
    private var scrollback: [[TerminalCell]] = []
    private let maxScrollbackLines = 10_000
    /// History is trimmed this many lines at a time once past the cap, not one
    /// per line feed: `removeFirst` shifts the whole array, and at the cap that
    /// was ten thousand moves for every line a busy program printed.
    private let scrollbackTrimBatch = 1_024

    // ─── Soft wraps ──────────────────────────────────────────────────────
    //
    // Whether each row *continues* onto the next one, because the text ran
    // past the right margin, as opposed to ending because the program said so.
    //
    // A grid of cells cannot answer that on its own, and the difference is the
    // whole of reflow: joining rows that were never one line would run a
    // program's output together, and not joining the ones that were leaves
    // every wrapped line permanently broken at whatever width it first
    // appeared. So it is recorded at the moment it happens — the only moment
    // it is known — and carried alongside the cells everywhere they move.
    private var rowWrapped: [Bool]
    private var scrollbackWrapped: [Bool] = []
    private var mainRowWrapped: [Bool]?

    private let parser = AnsiParser()

    public init(cols: Int = 80, rows: Int = 24) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.grid = Array(
            repeating: .empty, count: self.cols * (self.rows + Self.spareRows))
        self.rowWrapped = Array(repeating: false, count: self.rows)
        self.scrollBottom = self.rows - 1
    }

    public func resize(cols newCols: Int, rows newRows: Int) {
        let nc = max(1, newCols)
        let nr = max(1, newRows)
        guard nc != cols || nr != rows else { return }

        if onAlternateScreen {
            // The alternate screen is not reflowed, and that is not a
            // shortcut. It belongs to a full-screen program that has drawn an
            // absolute layout on it and will redraw the whole thing when it
            // sees SIGWINCH; rewrapping vim's window into continuation lines
            // would produce something no program ever intended, for the one
            // frame before it repainted anyway.
            setGrid(resizeBuffer(
                cells, fromCols: cols, fromRows: rows, toCols: nc, toRows: nr
            ), width: nc)
            rowWrapped = Array(repeating: false, count: nr)
            if let saved = mainCells {
                mainCells = resizeBuffer(
                    saved, fromCols: cols, fromRows: rows, toCols: nc, toRows: nr
                )
                mainRowWrapped = Array(repeating: false, count: nr)
                mainCursorCol = min(mainCursorCol, nc - 1)
                mainCursorRow = min(mainCursorRow, nr - 1)
                mainScrollTop = 0
                mainScrollBottom = nr - 1
            }
            scrollback = scrollback.map { row in
                var next = Array(repeating: TerminalCell.empty, count: nc)
                for c in 0..<min(row.count, nc) { next[c] = row[c] }
                return next
            }
            cols = nc
            rows = nr
            scrollTop = 0
            scrollBottom = rows - 1
            cursorCol = min(cursorCol, cols - 1)
            cursorRow = min(cursorRow, rows - 1)
            viewOffset = min(viewOffset, scrollback.count)
            return
        }

        reflow(toCols: nc, toRows: nr)
    }

    /// One row, as reflow sees it.
    private struct WrappedRow {
        var cells: [TerminalCell]
        /// Continues onto the row below rather than ending here.
        var wrapped: Bool
    }

    /// Rewraps everything the screen holds to a new width.
    ///
    /// The alternative — copy the top-left corner of the old grid into the new
    /// one — is what this used to do, and it is lossy in the direction that
    /// matters: narrowing a window deletes the right-hand end of every line
    /// that was longer than the new width, permanently, including in the
    /// history. Widening is no better, since lines that wrapped stay broken at
    /// a margin that no longer exists.
    ///
    /// So the grid is turned back into the *logical* lines that produced it,
    /// rewrapped at the new width, and laid out again. Scrollback and the live
    /// screen are one sequence for this purpose — a line that wrapped across
    /// the boundary between them is still one line — which is also why the
    /// cursor is tracked by its offset into its own logical line rather than
    /// by a row and column that will not survive.
    private func reflow(toCols nc: Int, toRows nr: Int) {
        // ── 1. Every row there is, history first ──────────────────────────
        var source: [WrappedRow] = []
        source.reserveCapacity(scrollback.count + rows)
        for (index, line) in scrollback.enumerated() {
            source.append(WrappedRow(
                cells: line,
                wrapped: index < scrollbackWrapped.count && scrollbackWrapped[index]
            ))
        }
        for r in 0..<rows {
            let base = index(r, 0)
            source.append(WrappedRow(
                cells: Array(grid[base..<(base + cols)]),
                wrapped: r < rowWrapped.count && rowWrapped[r]
            ))
        }
        let cursorSourceRow = scrollback.count + cursorRow

        // The blank rows below the cursor are unused screen, not content, and
        // rewrapping them as empty lines would push real output off the top:
        // a line that grows from one row to two has to take its extra row from
        // somewhere, and taking it from the bottom padding is free while taking
        // it from the history is a line scrolling away for no reason. Anything
        // genuinely printed below the cursor still counts — a program is
        // allowed to move the cursor up and keep writing underneath it.
        var lastContent = cursorSourceRow
        for index in stride(from: source.count - 1, through: 0, by: -1) {
            guard index > lastContent else { break }
            let row = source[index]
            if row.wrapped || !Self.trimmingTrailingBlanks(row.cells).isEmpty {
                lastContent = index
                break
            }
        }
        if lastContent + 1 < source.count {
            source.removeSubrange((lastContent + 1)...)
        }

        // ── 2. Join soft-wrapped runs back into logical lines ─────────────
        var lines: [[TerminalCell]] = []
        var cursorLine = 0
        var cursorOffset = 0
        var current: [TerminalCell] = []
        for (index, row) in source.enumerated() {
            if index == cursorSourceRow {
                cursorLine = lines.count
                cursorOffset = current.count + cursorCol
            }
            // A wrapped row is full by definition, so its trailing blanks are
            // content. An ended one is padded out to the width by the grid,
            // and keeping that padding would make every logical line exactly
            // as long as the old screen was wide — rewrapping noise.
            current.append(
                contentsOf: row.wrapped ? row.cells : Self.trimmingTrailingBlanks(row.cells)
            )
            if !row.wrapped {
                lines.append(current)
                current = []
            }
        }
        if !current.isEmpty { lines.append(current) }

        // ── 3. Lay the logical lines out at the new width ─────────────────
        var out: [WrappedRow] = []
        out.reserveCapacity(lines.count)
        var cursorOutRow = 0
        var cursorOutCol = 0
        for (index, line) in lines.enumerated() {
            var start = 0
            repeat {
                let end = min(line.count, start + nc)
                let isLast = end >= line.count
                if index == cursorLine, cursorOffset >= start,
                   cursorOffset < end || isLast
                {
                    cursorOutRow = out.count
                    cursorOutCol = min(nc - 1, cursorOffset - start)
                }
                var chunk = Array(line[start..<end])
                if chunk.count < nc {
                    chunk.append(
                        contentsOf: repeatElement(.empty, count: nc - chunk.count)
                    )
                }
                out.append(WrappedRow(cells: chunk, wrapped: !isLast))
                start = end
            } while start < line.count
        }
        if out.isEmpty {
            out.append(WrappedRow(
                cells: Array(repeating: .empty, count: nc), wrapped: false
            ))
        }

        // ── 4. Split back into history and screen ─────────────────────────
        //
        // The screen is the last `nr` rows. The cursor is normally on the last
        // one of them — it is a shell prompt — so it comes along; a cursor
        // parked far above the end is clamped into view rather than dragging
        // the window up and stranding the rows below it.
        let windowStart = max(0, out.count - nr)
        var history = out.prefix(windowStart).map(\.cells)
        var historyWrapped = out.prefix(windowStart).map(\.wrapped)
        if history.count > maxScrollbackLines {
            let drop = history.count - maxScrollbackLines
            history.removeFirst(drop)
            historyWrapped.removeFirst(drop)
        }

        var grid = Array(repeating: TerminalCell.empty, count: nc * nr)
        var wrapped = Array(repeating: false, count: nr)
        for r in 0..<nr {
            let index = windowStart + r
            guard index < out.count else { break }
            let base = r * nc
            for c in 0..<nc { grid[base + c] = out[index].cells[c] }
            wrapped[r] = out[index].wrapped
        }

        setGrid(grid, width: nc)
        rowWrapped = wrapped
        scrollback = history
        scrollbackWrapped = historyWrapped
        scrollbackLineCount = scrollback.count
        cols = nc
        rows = nr
        scrollTop = 0
        scrollBottom = rows - 1
        cursorRow = min(rows - 1, max(0, cursorOutRow - windowStart))
        cursorCol = min(cols - 1, max(0, cursorOutCol))
        savedCol = min(cols - 1, savedCol)
        savedRow = min(rows - 1, savedRow)
        // Reflow moves every history line, so an offset counted in old lines
        // means nothing now. Clamping keeps it in range; being glued to the
        // bottom, which is where a terminal usually is, is exact.
        viewOffset = min(viewOffset, scrollback.count)
    }

    /// A row without the padding the grid gave it.
    ///
    /// Only blanks that carry no colour of their own: a bar of highlighted
    /// spaces at the end of a line is content, and dropping it would rewrap a
    /// prompt's background into the wrong place.
    private static func trimmingTrailingBlanks(
        _ row: [TerminalCell]
    ) -> [TerminalCell] {
        var end = row.count
        while end > 0 {
            let cell = row[end - 1]
            let isPadding = cell.scalar == " " && cell.bg == .default
                && !cell.inverse && !cell.underline
            if !isPadding { break }
            end -= 1
        }
        return Array(row[0..<end])
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
        return grid[index(row, col)]
    }

    /// Where a visible cell is in `grid`.
    @inline(__always)
    private func index(_ row: Int, _ col: Int) -> Int {
        (origin + row) * cols + col
    }

    /// Installs `visible` — exactly the visible rows, `width` cells each — as
    /// the active buffer, with the spare rows after it. The width is passed
    /// because a resize installs the new grid before `cols` changes.
    private func setGrid(_ visible: [TerminalCell], width: Int) {
        var next = visible
        next.append(contentsOf: repeatElement(.empty, count: width * Self.spareRows))
        grid = next
        origin = 0
    }

    /// Fills visible cells `from..<to` (indices into `grid`).
    private func fill(_ from: Int, _ to: Int, with cell: TerminalCell) {
        guard to > from else { return }
        grid.withUnsafeMutableBufferPointer { g in
            (g.baseAddress! + from).update(repeating: cell, count: to - from)
        }
    }

    /// The cell at a viewport row, honouring `viewOffset`.
    ///
    /// Painting and hit-testing both go through this so a selection made
    /// while scrolled up copies what the user actually sees, not whatever
    /// is under it on the live screen.
    public func visibleCell(row: Int, col: Int) -> TerminalCell {
        guard row >= 0, row < rows, col >= 0, col < cols else { return .empty }
        let offset = onAlternateScreen ? 0 : viewOffset
        if offset == 0 {
            return grid[index(row, col)]
        }
        // Combined buffer: scrollback lines, then the live screen.
        // Viewport starts `offset` lines above the bottom of that buffer.
        let history = scrollback.count
        let lineIndex = history - offset + row
        if lineIndex < 0 {
            return .empty
        }
        if lineIndex < history {
            let line = scrollback[lineIndex]
            return col < line.count ? line[col] : .empty
        }
        let liveRow = lineIndex - history
        guard liveRow >= 0, liveRow < rows else { return .empty }
        return grid[index(liveRow, col)]
    }

    /// True when the viewport is not glued to the live bottom.
    public var isScrolledUp: Bool { viewOffset > 0 && !onAlternateScreen }

    /// Move the viewport by `delta` lines. Positive looks further into
    /// history (wheel-up). Returns true if the offset actually changed.
    @discardableResult
    public func scrollView(by delta: Int) -> Bool {
        guard !onAlternateScreen, delta != 0 else { return false }
        let maxOffset = scrollback.count
        let next = max(0, min(maxOffset, viewOffset + delta))
        guard next != viewOffset else { return false }
        viewOffset = next
        return true
    }

    /// Snap the viewport to the live screen. Called when the user types, so
    /// they are not editing a command they cannot see.
    public func scrollToBottom() {
        viewOffset = 0
    }

    /// Ingest PTY output.
    public func feed(_ data: Data) {
        parser.feed(data, into: self)
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
            // The program ended this line itself, so it does not continue —
            // even if a previous print had wrapped into it.
            if cursorRow >= 0, cursorRow < rowWrapped.count {
                rowWrapped[cursorRow] = false
            }
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
        case .setTitle(let title):
            windowTitle = title
        case .setWorkingDirectory(let uri):
            if let path = Self.path(fromOSC7: uri) {
                workingDirectory = path
            }
        case .setClipboard(let text):
            pendingClipboard = text
        case .ignore:
            break
        }
    }

    /// OSC 7 carries `file://host/path` (or a bare absolute path from some
    /// shells). Returns the filesystem path, percent-decoded.
    static func path(fromOSC7 uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            return trimmed
        }
        if let url = URL(string: trimmed), url.isFileURL {
            // `fileURL.path` percent-decodes and drops the host.
            let path = url.path
            return path.isEmpty ? nil : path
        }
        // `file://hostname/path` without a third slash confuses some parsers;
        // peel the scheme by hand.
        if trimmed.hasPrefix("file://") {
            var rest = String(trimmed.dropFirst("file://".count))
            if rest.hasPrefix("/") {
                return rest.removingPercentEncoding ?? rest
            }
            if let slash = rest.firstIndex(of: "/") {
                rest = String(rest[slash...])
                return rest.removingPercentEncoding ?? rest
            }
        }
        return nil
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
            fill(index(0, 0), index(rows, 0), with: .empty)
            for r in rowWrapped.indices { rowWrapped[r] = false }
            cursorCol = 0
            cursorRow = 0
            scrollTop = 0
            scrollBottom = rows - 1
            return
        }
        mainCells = cells
        mainRowWrapped = rowWrapped
        mainCursorCol = cursorCol
        mainCursorRow = cursorRow
        mainScrollTop = scrollTop
        mainScrollBottom = scrollBottom
        setGrid(Array(repeating: .empty, count: cols * rows), width: cols)
        rowWrapped = Array(repeating: false, count: rows)
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
        setGrid(saved, width: cols)
        rowWrapped = mainRowWrapped ?? Array(repeating: false, count: rows)
        if rowWrapped.count != rows {
            rowWrapped = Array(repeating: false, count: rows)
        }
        mainCells = nil
        mainRowWrapped = nil
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

    /// `put` for a run, a row segment at a time under one exclusive access —
    /// per character, the checked subscript and the property reads around it
    /// were most of what printing cost.
    private func putASCII(_ bytes: UnsafeBufferPointer<UInt8>) {
        let width = cols
        var cell = TerminalCell(
            scalar: " ", fg: currentFg, bg: currentBg,
            bold: bold, inverse: inverse, underline: underline)
        var i = 0
        while i < bytes.count {
            if cursorCol >= width {
                if cursorRow >= 0, cursorRow < rowWrapped.count {
                    rowWrapped[cursorRow] = true
                }
                cursorCol = 0
                lineFeed()
            }
            let col = cursorCol
            let take = min(bytes.count - i, width - col)
            let start = index(cursorRow, col)
            let from = i
            grid.withUnsafeMutableBufferPointer { grid in
                for k in 0..<take {
                    cell.scalar = Unicode.Scalar(bytes[from + k])
                    grid[start + k] = cell
                }
            }
            cursorCol = col + take
            i += take
        }
    }

    private func put(_ s: Unicode.Scalar) {
        // C1 / control shouldn't land here
        if s.value < 0x20 || s.value == 0x7F { return }
        if cursorCol >= cols {
            // Recorded before the feed, which may scroll and take the row with
            // it — after that there is no way to say which row this was.
            if cursorRow >= 0, cursorRow < rowWrapped.count {
                rowWrapped[cursorRow] = true
            }
            cursorCol = 0
            lineFeed()
        }
        grid[index(cursorRow, cursorCol)] = TerminalCell(
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
        // Only the primary screen keeps history, and only lines that leave
        // through the top of the screen (region starts at row 0). A region
        // that starts mid-screen is an editor viewport; those lines are not
        // scrollback.
        if !onAlternateScreen && top == 0 {
            scrollback.append(Array(grid[index(0, 0)..<index(1, 0)]))
            scrollbackWrapped.append(rowWrapped.first ?? false)
            if scrollback.count > maxScrollbackLines + scrollbackTrimBatch {
                let drop = scrollback.count - maxScrollbackLines
                scrollback.removeFirst(drop)
                scrollbackWrapped.removeFirst(min(drop, scrollbackWrapped.count))
            }
            scrollbackLineCount = scrollback.count
            // Keep the viewport fixed on the same history line while new
            // output arrives underneath — only if the user was already
            // looking up. At the bottom we stay glued.
            if viewOffset > 0 {
                viewOffset = min(viewOffset + 1, scrollback.count)
            }
        }
        // One move for the block, under one exclusive access. Cell by cell it
        // was a whole screen of checked subscripts per line feed — 95% of what
        // ingesting a fast program's output cost. Cells hold no references,
        // so the move is a plain memmove.
        let blank = blankCell()
        if top == 0 && bottom == rows - 1 {
            // The whole screen: the window onto `grid` moves down a row.
            if origin + rows + 1 > grid.count / width {
                let from = origin * width
                grid.withUnsafeMutableBufferPointer { grid in
                    let base = grid.baseAddress!
                    base.update(from: base + from, count: rows * width)
                }
                origin = 0
            }
            origin += 1
            fill(index(bottom, 0), index(bottom + 1, 0), with: blank)
        } else {
            let at = origin * width
            grid.withUnsafeMutableBufferPointer { grid in
                let base = grid.baseAddress! + at
                (base + top * width).update(
                    from: base + (top + 1) * width, count: (bottom - top) * width)
                (base + bottom * width).update(repeating: blank, count: width)
            }
        }
        rowWrapped.withUnsafeMutableBufferPointer { wrapped in
            let base = wrapped.baseAddress!
            (base + top).update(from: base + top + 1, count: bottom - top)
            base[bottom] = false
        }
    }

    private func scrollDown() {
        let width = cols
        let top = scrollTop
        let bottom = scrollBottom
        if top > bottom { return }
        // As `scrollUp`, the other way.
        let blank = blankCell()
        let at = origin * width
        grid.withUnsafeMutableBufferPointer { grid in
            let base = grid.baseAddress! + at
            (base + (top + 1) * width).update(
                from: base + top * width, count: (bottom - top) * width)
            (base + top * width).update(repeating: blank, count: width)
        }
        rowWrapped.withUnsafeMutableBufferPointer { wrapped in
            let base = wrapped.baseAddress!
            (base + top + 1).update(from: base + top, count: bottom - top)
            base[top] = false
        }
    }

    private func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseFromCursorToEnd()
        case 1:
            eraseFromStartToCursor()
        default:
            fill(index(0, 0), index(rows, 0), with: blankCell())
            for r in rowWrapped.indices { rowWrapped[r] = false }
            if mode == 3 {
                // CSI 3 J — clear scrollback, xterm extension.
                scrollback.removeAll(keepingCapacity: true)
                scrollbackWrapped.removeAll(keepingCapacity: true)
                scrollbackLineCount = 0
                viewOffset = 0
            }
        }
    }

    private func eraseLine(_ mode: Int) {
        let base = index(cursorRow, 0)
        // Clearing to the end of a row is the program saying the line stops
        // here, so it no longer continues into the next one.
        if mode != 1, cursorRow < rowWrapped.count { rowWrapped[cursorRow] = false }
        switch mode {
        case 0:
            for c in cursorCol..<cols { grid[base + c] = blankCell() }
        case 1:
            for c in 0...cursorCol where c < cols { grid[base + c] = blankCell() }
        default:
            for c in 0..<cols { grid[base + c] = blankCell() }
        }
    }

    private func eraseFromCursorToEnd() {
        eraseLine(0)
        if cursorRow + 1 < rows {
            fill(index(cursorRow + 1, 0), index(rows, 0), with: blankCell())
            for r in (cursorRow + 1)..<rows { rowWrapped[r] = false }
        }
    }

    private func eraseFromStartToCursor() {
        if cursorRow > 0 {
            fill(index(0, 0), index(cursorRow, 0), with: blankCell())
        }
        eraseLine(1)
    }

    private func deleteChars(_ n: Int) {
        let base = index(cursorRow, 0)
        let count = min(n, cols - cursorCol)
        for c in cursorCol..<(cols - count) {
            grid[base + c] = grid[base + c + count]
        }
        for c in (cols - count)..<cols {
            grid[base + c] = blankCell()
        }
    }

    private func insertChars(_ n: Int) {
        let base = index(cursorRow, 0)
        let count = min(n, cols - cursorCol)
        for c in stride(from: cols - 1, through: cursorCol + count, by: -1) {
            grid[base + c] = grid[base + c - count]
        }
        for c in cursorCol..<(cursorCol + count) {
            grid[base + c] = blankCell()
        }
    }

    private func eraseChars(_ n: Int) {
        let base = index(cursorRow, 0)
        let end = min(cols, cursorCol + n)
        for c in cursorCol..<end {
            grid[base + c] = blankCell()
        }
    }

    /// DL. Only inside the scroll region, as every terminal does it: outside
    /// it the count went negative, and with the cursor two rows from the
    /// bottom `cursorRow...(scrollBottom - count)` was `1...0` — a trap, so
    /// `\n` then `CSI 2 M` on a three-row screen took the terminal down.
    private func deleteLines(_ n: Int) {
        guard n > 0, cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let top = cursorRow
        let bottom = scrollBottom
        let count = min(n, bottom - top + 1)
        let width = cols
        let blank = blankCell()
        let at = origin * width
        grid.withUnsafeMutableBufferPointer { grid in
            let base = grid.baseAddress! + at
            (base + top * width).update(
                from: base + (top + count) * width, count: (bottom - top + 1 - count) * width)
            (base + (bottom - count + 1) * width).update(repeating: blank, count: count * width)
        }
        rowWrapped.withUnsafeMutableBufferPointer { wrapped in
            let base = wrapped.baseAddress!
            (base + top).update(from: base + top + count, count: bottom - top + 1 - count)
            (base + bottom - count + 1).update(repeating: false, count: count)
        }
    }

    /// IL. The same rules as `deleteLines`, the other way.
    private func insertLines(_ n: Int) {
        guard n > 0, cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let top = cursorRow
        let bottom = scrollBottom
        let count = min(n, bottom - top + 1)
        let width = cols
        let blank = blankCell()
        let at = origin * width
        grid.withUnsafeMutableBufferPointer { grid in
            let base = grid.baseAddress! + at
            (base + (top + count) * width).update(
                from: base + top * width, count: (bottom - top + 1 - count) * width)
            (base + top * width).update(repeating: blank, count: count * width)
        }
        rowWrapped.withUnsafeMutableBufferPointer { wrapped in
            let base = wrapped.baseAddress!
            (base + top + count).update(from: base + top, count: bottom - top + 1 - count)
            (base + top).update(repeating: false, count: count)
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

extension TerminalScreen: AnsiSink {
    func perform(_ op: AnsiParser.Output) { apply(op) }
    func printASCII(_ bytes: UnsafeBufferPointer<UInt8>) { putASCII(bytes) }
}

