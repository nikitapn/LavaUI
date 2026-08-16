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
        self.cells = Array(repeating: .empty, count: self.cols * self.rows)
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
            cells = resizeBuffer(
                cells, fromCols: cols, fromRows: rows, toCols: nc, toRows: nr
            )
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
            let base = r * cols
            source.append(WrappedRow(
                cells: Array(cells[base..<(base + cols)]),
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

        cells = grid
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
        return cells[row * cols + col]
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
            return cells[row * cols + col]
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
        return cells[liveRow * cols + col]
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
            for i in cells.indices { cells[i] = .empty }
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
        cells = Array(repeating: .empty, count: cols * rows)
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
        cells = saved
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
        // Only the primary screen keeps history, and only lines that leave
        // through the top of the screen (region starts at row 0). A region
        // that starts mid-screen is an editor viewport; those lines are not
        // scrollback.
        if !onAlternateScreen && top == 0 {
            var line = Array(repeating: TerminalCell.empty, count: width)
            for c in 0..<width {
                line[c] = cells[c]
            }
            scrollback.append(line)
            scrollbackWrapped.append(rowWrapped.first ?? false)
            if scrollback.count > maxScrollbackLines {
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
        for r in top..<bottom {
            let dst = r * width
            let src = (r + 1) * width
            for c in 0..<width {
                cells[dst + c] = cells[src + c]
            }
            rowWrapped[r] = rowWrapped[r + 1]
        }
        let last = bottom * width
        for c in 0..<width {
            cells[last + c] = blankCell()
        }
        rowWrapped[bottom] = false
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
            rowWrapped[r] = rowWrapped[r - 1]
        }
        let first = top * width
        for c in 0..<width {
            cells[first + c] = blankCell()
        }
        rowWrapped[top] = false
    }

    private func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseFromCursorToEnd()
        case 1:
            eraseFromStartToCursor()
        default:
            for i in cells.indices { cells[i] = blankCell() }
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
        let base = cursorRow * cols
        // Clearing to the end of a row is the program saying the line stops
        // here, so it no longer continues into the next one.
        if mode != 1, cursorRow < rowWrapped.count { rowWrapped[cursorRow] = false }
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
            for r in (cursorRow + 1)..<rows { rowWrapped[r] = false }
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
            rowWrapped[r] = rowWrapped[r + count]
        }
        for r in (scrollBottom - count + 1)...scrollBottom {
            let base = r * width
            for c in 0..<width { cells[base + c] = blankCell() }
            rowWrapped[r] = false
        }
    }

    private func insertLines(_ n: Int) {
        let count = min(n, scrollBottom - cursorRow + 1)
        let width = cols
        for r in stride(from: scrollBottom, through: cursorRow + count, by: -1) {
            let dst = r * width
            let src = (r - count) * width
            for c in 0..<width { cells[dst + c] = cells[src + c] }
            rowWrapped[r] = rowWrapped[r - count]
        }
        for r in cursorRow..<(cursorRow + count) {
            let base = r * width
            for c in 0..<width { cells[base + c] = blankCell() }
            rowWrapped[r] = false
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
