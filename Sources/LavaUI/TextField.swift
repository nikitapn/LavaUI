import Foundation

/// Single-line editable text.
///
/// Step 1 of the plan's Phase 7 ladder: Latin, no IME, no multi-line. The
/// editing logic itself is `TextEditingState` in `LavaText` (pure, tested
/// headlessly); this type is only the view/node plumbing around it.
///
/// The buffer lives on the *node*, not in `@State`, because a `PrimitiveView`
/// has no body and so never goes through `CompositeNode`'s state transplant.
/// The node persists across rebuilds, which is the same guarantee.
///
/// Focus chrome comes from `Theme.focusRingStyle` by default (a full rounded
/// outline). Pass `focusRing:` / `focusRingWidth:` / `focusRingColor:` to
/// override per field — e.g. `.underline` for the historical top+bottom bars.
public struct TextField: PrimitiveView {
    @Binding public var text: String
    public var placeholder: String
    public var font: UIFont?
    public var onSubmit: (() -> Void)?
    /// When true, Enter inserts a newline instead of submitting, and the box
    /// grows to fit its lines. Hard line breaks only for now — soft wrap is a
    /// separate step, because a wrapped visual line is no longer a logical one
    /// and every index mapping has to account for that.
    public var isMultiline: Bool
    /// Height cap in rows when multi-line; the box grows up to this.
    public var maxLines: Int
    /// Wrap long lines to the field width instead of letting them overflow.
    public var wraps: Bool
    /// Take the caret as soon as this field appears.
    ///
    /// For the window whose entire purpose is one field — a launcher, a search
    /// overlay, a rename prompt. Without it the user has to click the box
    /// before typing, which is asking them to aim at something before saying
    /// what they want.
    ///
    /// Only on mount, and only when nothing else in the window is focused: a
    /// field that re-took focus on every reconcile would steal the caret back
    /// from wherever the user had since put it.
    public var autoFocus: Bool = false
    /// Overrides `Theme.focusRingStyle` when set.
    public var focusRing: FocusRingStyle?
    public var focusRingWidth: Float?
    public var focusRingColor: Color?

    public init(
        text: Binding<String>,
        placeholder: String = "",
        font: UIFont? = nil,
        multiline: Bool = false,
        maxLines: Int = 8,
        wraps: Bool = false,
        autoFocus: Bool = false,
        focusRing: FocusRingStyle? = nil,
        focusRingWidth: Float? = nil,
        focusRingColor: Color? = nil,
        onSubmit: (() -> Void)? = nil
    ) {
        self._text = text
        self.placeholder = placeholder
        self.font = font
        self.isMultiline = multiline
        self.maxLines = maxLines
        self.wraps = wraps
        self.autoFocus = autoFocus
        self.focusRing = focusRing
        self.focusRingWidth = focusRingWidth
        self.focusRingColor = focusRingColor
        self.onSubmit = onSubmit
    }

    public var resolvedFont: UIFont? { font ?? Environment.current.font }

    public var dumpDetail: String { "\"\(text)\"" }

    public func mountPrimitive() -> any AnyViewNode {
        let leaf = LeafNode(kind: .textField, label: "TextField", width: .auto, height: .auto)
        configure(leaf)
        leaf.editing = TextEditingState(text)
        leaf.installTextMeasure()
        if autoFocus, FocusManager.focusedID == nil {
            leaf.focusSelf(binding: _text, onSubmit: onSubmit)
        }
        return leaf
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let leaf = node as? LeafNode, leaf.kind == .textField else {
            return mountPrimitive()
        }
        // The binding is the source of truth for *content*; the node owns the
        // cursor. Only resync when the outside value actually diverged, or an
        // in-progress edit would have its caret reset on every frame.
        if leaf.editing.text != text {
            leaf.editing.setText(text, keepingCursor: true)
        }
        configure(leaf)
        if !leaf.usesTextMeasure { leaf.installTextMeasure() }
        leaf.markMeasureDirty()
        return leaf
    }

    private func configure(_ leaf: LeafNode) {
        let theme = Environment.current.theme
        leaf.theme = theme
        leaf.font = resolvedFont
        leaf.color = .primary
        leaf.placeholder = placeholder
        leaf.fillColor = theme.inset
        leaf.cornerRadius = theme.cornerRadius
        leaf.focusRingStyle = focusRing
        leaf.focusRingWidth = focusRingWidth
        leaf.focusRingColor = focusRingColor
        // Measure against the placeholder when empty so an empty field still
        // reserves a sensible line box.
        leaf.text = leaf.editing.text.isEmpty ? placeholder : leaf.editing.text
        leaf.minWidth = 80
        // The I-beam is what says "you can put a caret here" before anything is
        // clicked. It also makes this leaf a hit-testable scene node, which a
        // field that draws no hover fill was not — the cost of the affordance,
        // paid per field. See `View.cursor(_:)`.
        leaf.cursor = .text
        leaf.isMultiline = isMultiline
        leaf.maxLines = maxLines
        leaf.wraps = wraps && isMultiline
        // No wrapping or sizing here: only the Yoga measure callback knows
        // the resolved width, and setting `height` after installTextMeasure()
        // has forced it to .auto never reached Yoga anyway.

        let binding = _text
        let submit = onSubmit

        // Press: focus, place the caret, and start a drag session.
        leaf.onClickLocal = { [weak leaf] localX, localY, originX, originY, _, _ in
            guard let leaf, let run = leaf.shapedRun() else { return }
            leaf.focusSelf(binding: binding, onSubmit: submit)

            let hit = leaf.index(atLocalX: localX, localY: localY) ?? run.index(atX: localX - leaf.textInset)
            let clicks = ClickCounter.register(x: originX + localX, y: originY + localY)

            if clicks >= 2 {
                // Double click selects the word; a third would select all, but
                // that is left out until it is asked for.
                leaf.editing.selectWord(at: hit)
            } else {
                leaf.editing.setCursor(hit)
                // Capture so the selection keeps extending once the pointer
                // leaves the field — otherwise the hit test simply misses.
                PointerCapture.capture(
                    leaf.id,
                    onMove: { [weak leaf] wx, wy in
                        guard let leaf, let run = leaf.shapedRun() else { return }
                        let lx = wx - originX
                        let ly = wy - originY
                        let target = leaf.index(atLocalX: lx, localY: ly)
                            ?? run.index(atX: lx - leaf.textInset)
                        leaf.editing.setCursor(target, extending: true)
                        CaretBlink.noteEdit()
                        // Selection lives on the retained node, not the bound
                        // text — see the identical note in EditorView.
                        ViewInvalidation.markNeedsRedraw()
                    }
                )
            }
            CaretBlink.noteEdit()
            ViewInvalidation.markNeedsRedraw()
        }
    }
}

extension LeafNode {
    /// Horizontal padding inside a field, matching the draw-side inset.
    var textInset: Float { theme.controlPadding }

    /// Shapes the current buffer for caret/selection maths. Cached on `UIFont`,
    /// so this is a dictionary hit on all but the first call per string.
    func shapedRun() -> ShapedRun? {
        guard let font = font ?? FontStore.default else { return nil }
        return font.shapedRun(editing.text)
    }

    /// Recomputes row boundaries for the current text (and, while wrapping,
    /// width) and installs them on the editing state so navigation follows
    /// what is drawn.
    ///
    /// Called from layout rather than from draw: `moveUp`/`moveDown` consult
    /// these, so they have to exist before a key is handled, not just before
    /// pixels are produced. Guarded on text/width identity in both branches —
    /// `editing.layout` is read many times per frame (caret, hit test,
    /// gutter, decorations), and without this, "no wrap" meant `layout`
    /// fell back to rescanning the whole buffer character by character on
    /// *every* one of those reads, not just when it actually changed.
    func refreshVisualRows(availableWidth: Float) {
        if wraps, let f = font ?? FontStore.default, availableWidth > 0 {
            let textNow = editing.text
            let widthMoved = abs(availableWidth - lastMeasuredWidth) > 0.5
            let replanned = widthMoved || textNow != lastWrappedText
            // A pass still owes work even when nothing moved: the plan below
            // leaves most of the file unbroken and finishes it over the next
            // few frames.
            guard replanned || wrapUnmeasured > 0 else { return }
            lastMeasuredWidth = availableWidth
            lastWrappedText = textNow

            // The gutter is not part of the wrap width. Zero for a text
            // field, which is why this expression serves both.
            let inner = max(8, availableWidth - gutterWidth - textInset * 2)
            if replanned { planWrap(text: textNow, widthMoved: widthMoved) }
            breakWrapWindow(font: f, inner: inner, anchored: !replanned)
            installWrapRows()
            return
        }

        // No wrapping: one row per logical line, cached the same way.
        guard editing.text != lastLogicalRowsText else { return }
        seedLogicalRows()
    }

    // MARK: Soft wrap, one window at a time

    /// How long a frame will spend breaking lines it does not need yet.
    ///
    /// The file still gets wrapped — the row table every consumer reads has
    /// to cover all of it, and a row has to cover real text, so there is no
    /// honest way to leave a hole in the middle. What this buys is that none
    /// of it lands between a keystroke and the frame that answers it: the
    /// window is exact immediately, and the document's height settles over
    /// however many frames it takes.
    ///
    /// A time budget rather than a line count, because a line's cost is its
    /// length and a fixed count is either a stall on a log or pointlessly
    /// timid on source. Four milliseconds leaves the rest of a 60 Hz frame
    /// for everything else, so the settling is invisible instead of being a
    /// shorter stall in a different place.
    /// A `var` so a test can separate the two halves: at zero, a pass
    /// measures what is on screen and nothing else, which is exactly the
    /// state the window has to be correct in.
    nonisolated(unsafe) static var wrapBudget: Double = 0.004

    /// Lines broken between clock reads, so the timing is not most of the
    /// cost of the loop it is timing.
    private static let wrapBudgetGranularity = 32

    /// Lines broken either side of the viewport, so a small scroll finds its
    /// rows already there rather than waiting for the next pass.
    private static let wrapMargin = 64

    /// Rebuilds the per-line plan for a new buffer or a new width, breaking
    /// nothing: every line that cannot be reused gets one provisional row
    /// covering it whole, and is queued.
    private func planWrap(text: String, widthMoved: Bool) {
        let lines = editing.lines
        // The scan `afterEdit` has just done, when it is still current.
        let ranges = lastLogicalRowsText == text
            ? logicalRowCache : VisualLayout.logicalRows(text)

        // A different width breaks every line somewhere else, so nothing
        // survives it. An edit leaves all but one line alone.
        let reusableLines = widthMoved ? [] : wrapCacheLines
        let reusableRows = widthMoved ? [] : wrapCacheRows
        let reusableMeasured = widthMoved ? [] : wrapMeasured

        // How far the old and new line arrays agree from each end.
        //
        // Matching index-for-index is only right while the *number* of lines
        // holds: type a newline into line 3 of a 200,000-line log and every
        // line after it shifts by one, so a positional check says all 199,997
        // changed. An edit is a contiguous region, so the lines before it and
        // the lines after it are both still there — the standard
        // common-prefix/common-suffix trim finds them, and what is left
        // between the two is what actually has to be broken again.
        var head = 0
        while head < reusableLines.count, head < lines.count,
              reusableLines[head] == lines[head] { head += 1 }
        var tail = 0
        while tail < reusableLines.count - head, tail < lines.count - head,
              reusableLines[reusableLines.count - 1 - tail]
                  == lines[lines.count - 1 - tail] { tail += 1 }

        var rows: [[Range<Int>]] = []
        var measured: [Bool] = []
        var lengths: [Int] = []
        rows.reserveCapacity(lines.count)
        measured.reserveCapacity(lines.count)
        lengths.reserveCapacity(lines.count)
        var unmeasured = 0

        for index in lines.indices {
            let length = index < ranges.count ? ranges[index].count : 0
            lengths.append(length)

            let reusedAt: Int?
            if index < head {
                reusedAt = index
            } else if index >= lines.count - tail {
                reusedAt = reusableLines.count - (lines.count - index)
            } else {
                reusedAt = nil
            }
            if let reusedAt, reusableRows.indices.contains(reusedAt),
               reusableMeasured.indices.contains(reusedAt), reusableMeasured[reusedAt]
            {
                rows.append(reusableRows[reusedAt])
                measured.append(true)
            } else {
                rows.append([0..<length])
                measured.append(false)
                unmeasured += 1
            }
        }

        wrapCacheLines = lines
        wrapCacheRows = rows
        wrapMeasured = measured
        wrapLineLength = lengths
        wrapUnmeasured = unmeasured
        wrapCursor = 0
    }

    /// Breaks what the viewport can reach, then a chunk of what is left.
    ///
    /// `anchored` holds the logical line at the top of the box still: rows
    /// above the viewport multiply as they are broken, and without this the
    /// text would creep upward under the reader for as long as the
    /// refinement ran. It is off for the pass that follows a re-plan, where
    /// the caret drives the scroll instead.
    private func breakWrapWindow(font: UIFont, inner: Float, anchored: Bool) {
        guard wrapUnmeasured > 0 else { return }
        let lineHeight = font.lineHeight
        let anchorRow = max(0, Int(scrollY / lineHeight))
        let anchorFraction = scrollY - Float(anchorRow) * lineHeight
        let anchorLine = wrapLine(containingRow: anchorRow)
        let anchorSub = anchorRow - wrapFirstRow(ofLine: anchorLine)

        // Every line contributes at least one row, so a viewport `n` rows tall
        // can never show more than `n` lines starting at the anchor. Measuring
        // that many, plus a margin either side, is what makes the window
        // exact rather than nearly exact.
        // `viewportHeight` is set by emit, so on the very first pass it is
        // still zero; the row cap the editor was built with stands in.
        let box = max(viewportHeight, Float(maxLines) * lineHeight)
        let onScreen = Int(max(0, box) / lineHeight) + 2
        let first = max(0, anchorLine - Self.wrapMargin)
        let last = min(wrapCacheRows.count - 1, anchorLine + onScreen + Self.wrapMargin)
        if first <= last {
            for index in first...last { breakWrapLine(index, font: font, inner: inner) }
        }

        // Then whatever is next, so the scrollbar and the box height converge.
        if Self.wrapBudget > 0 {
            let deadline = FrameScheduler.now() + Self.wrapBudget
            var sinceClockRead = 0
            while wrapCursor < wrapCacheRows.count {
                if !wrapMeasured[wrapCursor] {
                    breakWrapLine(wrapCursor, font: font, inner: inner)
                    sinceClockRead += 1
                    if sinceClockRead >= Self.wrapBudgetGranularity {
                        sinceClockRead = 0
                        if FrameScheduler.now() >= deadline { wrapCursor += 1; break }
                    }
                }
                wrapCursor += 1
            }
        }

        if anchored {
            let sub = min(anchorSub, max(0, wrapCacheRows[anchorLine].count - 1))
            let row = wrapFirstRow(ofLine: anchorLine) + sub
            scrollY = max(0, Float(row) * lineHeight + anchorFraction)
        }
        // One more frame, until there is nothing left to break. Not a body
        // rebuild: nothing the app owns has changed, only how much of the
        // buffer this leaf has looked at.
        if wrapUnmeasured > 0 { ViewInvalidation.markNeedsRedraw() }
    }

    private func breakWrapLine(_ index: Int, font: UIFont, inner: Float) {
        guard wrapMeasured.indices.contains(index), !wrapMeasured[index] else { return }
        // Shaping is what this whole plan exists to defer: it is the cost of
        // the line, and there are as many lines as there are lines.
        PerfCounters.lineWraps += 1
        let s = String(wrapCacheLines[index])
        let advances = font.shapedRun(s).characterAdvances
        wrapCacheRows[index] = SoftWrap.rows(text: s, advances: advances, maxWidth: inner)
        wrapMeasured[index] = true
        wrapUnmeasured -= 1
    }

    /// Which logical line row `target` falls in, over the plan as it stands.
    ///
    /// A running sum rather than the installed `rowLogicalLine`, because this
    /// is asked *between* a re-plan and the install that follows it, when that
    /// table still describes the previous buffer.
    private func wrapLine(containingRow target: Int) -> Int {
        var row = 0
        for (index, broken) in wrapCacheRows.enumerated() {
            row += broken.count
            if row > target { return index }
        }
        return max(0, wrapCacheRows.count - 1)
    }

    private func wrapFirstRow(ofLine line: Int) -> Int {
        var row = 0
        for index in 0..<min(line, wrapCacheRows.count) { row += wrapCacheRows[index].count }
        return row
    }

    /// Flattens the plan into the row table everything else reads.
    private func installWrapRows() {
        var total = 0
        for broken in wrapCacheRows { total += broken.count }

        var rows: [Range<Int>] = []
        var logicalLine: [Int] = []
        var columnStart: [Int] = []
        rows.reserveCapacity(total)
        logicalLine.reserveCapacity(total)
        columnStart.reserveCapacity(total)

        var base = 0
        for (index, broken) in wrapCacheRows.enumerated() {
            for r in broken {
                rows.append((base + r.lowerBound)..<(base + r.upperBound))
                logicalLine.append(index)
                columnStart.append(r.lowerBound)
            }
            // From the byte scan, not from a fresh `line.count`: that would be
            // a grapheme walk per line, O(buffer) across the loop and paid
            // even on a pass where every line came out of the cache.
            base += wrapLineLength[index] + 1  // + the newline that ended it
        }
        editing.setVisualRows(rows)
        rowLogicalLine = logicalLine
        rowColumnStart = columnStart
    }

    /// Logical line holding visual row `row`. Identity while not wrapping.
    func logicalLine(ofRow row: Int) -> Int {
        rowLogicalLine.indices.contains(row) ? rowLogicalLine[row] : row
    }

    /// Where `row` starts within its own logical line. Zero while not wrapping.
    func columnStart(ofRow row: Int) -> Int {
        rowColumnStart.indices.contains(row) ? rowColumnStart[row] : 0
    }

    /// True when `row` is where its logical line begins — the only row that
    /// gets a number in the gutter, so continuation rows read as continuations
    /// rather than as lines of their own.
    func isLineStart(ofRow row: Int) -> Bool {
        guard !rowLogicalLine.isEmpty else { return true }
        guard row > 0 else { return true }
        return logicalLine(ofRow: row) != logicalLine(ofRow: row - 1)
    }

    /// First visual row of a zero-based logical line — what "go to line 400"
    /// has to resolve to once rows and lines are no longer the same thing.
    func firstRow(ofLine line: Int) -> Int {
        guard !rowLogicalLine.isEmpty else { return line }
        return min(rowRunStart(ofLine: line), rowLogicalLine.count - 1)
    }

    /// Where the run of rows belonging to `line` begins, or the row count when
    /// `line` is past the end. Unclamped on purpose: `logicalLineRange` needs
    /// "one past the last row of this line", which a clamped answer cannot
    /// distinguish from "the last row itself".
    private func rowRunStart(ofLine line: Int) -> Int {
        // Rows are ordered by line, so this is a binary search for the first
        // row of the run belonging to `line`.
        var low = 0
        var high = rowLogicalLine.count
        while low < high {
            let mid = low + (high - low) / 2
            if rowLogicalLine[mid] < line { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Character range of the whole logical line `row` sits in, newline
    /// excluded — a gutter click and a go-to-line both select the line, not
    /// the wrapped fragment the pointer happened to land on.
    func logicalLineRange(ofRow row: Int) -> Range<Int> {
        let rows = editing.layout.rows
        guard !rows.isEmpty else { return 0..<0 }
        let clamped = max(0, min(row, rows.count - 1))
        guard !rowLogicalLine.isEmpty else { return rows[clamped] }
        let line = logicalLine(ofRow: clamped)
        let first = min(rowRunStart(ofLine: line), rows.count - 1)
        let last = max(first, min(rowRunStart(ofLine: line + 1), rows.count) - 1)
        return rows[first].lowerBound..<rows[last].upperBound
    }

    /// Logical lines in the buffer, off the row table rather than a fresh
    /// split of the text.
    var logicalLineCount: Int {
        if let last = rowLogicalLine.last { return last + 1 }
        return editing.layout.count
    }

    /// Installs one row per logical line and marks the cache current.
    ///
    /// Called at mount as well as from layout, because `configure` reads the
    /// row count for the gutter width *before* the first measure pass. Without
    /// a table there, `editing.layout` falls back to rescanning the buffer on
    /// each access and throws the result away.
    func seedLogicalRows() {
        lastLogicalRowsText = editing.text
        let rows = VisualLayout.logicalRows(editing.text)
        // Kept, not just installed: `planWrap` wants this exact scan, and on
        // a wrapping editor it runs microseconds after this does.
        logicalRowCache = rows
        editing.setVisualRows(rows)
        // Row *is* logical line now, which the accessors above answer without
        // a table. Leaving a stale one installed would answer for the wrap
        // this buffer no longer has.
        rowLogicalLine = []
        rowColumnStart = []
        // `wrapCacheLines` deliberately survives: `EditorView.reconcilePrimitive`
        // seeds logical rows on *every* text change, to keep the gutter width
        // honest before the measure pass runs, and a wrapping editor reaches
        // its re-wrap through that same pass. Clearing here would empty the
        // cache on exactly the edit it exists to make cheap. It is dropped
        // when wrapping is turned off — see `EditorView.configure`.
    }

    /// Visual rows currently drawn.
    func rowCount() -> Int { editing.layout.count }

    /// Text of visual row `n`.
    func rowText(_ n: Int) -> String {
        let rows = editing.layout.rows
        guard n >= 0, n < rows.count else { return "" }
        let r = rows[n]
        return EditorProbe.measure("text.rowText", at: r.lowerBound) {
            // Through the offset anchor, and then *along the row* for its end:
            // two independent `index(atOffset:)` calls each walked from the
            // buffer's start, so reading one row near the end of a large file
            // — which is what every pointer move during a drag does — cost
            // two full walks before anything was shaped.
            let lo = textIndex(atOffset: r.lowerBound)
            let hi = editing.text.index(
                lo, offsetBy: r.upperBound - r.lowerBound,
                limitedBy: editing.text.endIndex
            ) ?? editing.text.endIndex
            return String(editing.text[lo..<hi])
        }
    }

    /// Index under a point in node-local coordinates, resolving the visual row
    /// first. Nil when there is no font to shape with.
    func index(atLocalX x: Float, localY y: Float) -> String.Index? {
        guard let f = font ?? FontStore.default else { return nil }
        let inset = textInset
        let rows = editing.layout.rows
        let row = max(0, min(rows.count - 1, Int((y - inset) / f.lineHeight)))
        let line = rowText(row)
        let local = EditorProbe.measure("text.shapeRow") {
            f.shapedRun(line).index(atX: x - inset)
        }
        let column = line.distance(from: line.startIndex, to: local)
        let offset = editing.layout.offset(row: row, column: column)
        // Anchored like the row above, which for a hit test means walking from
        // the row's start to the column under the pointer.
        return EditorProbe.measure("text.hitIndex", at: offset) {
            textIndex(atOffset: offset)
        }
    }

    func focusSelf(binding: Binding<String>, onSubmit: (() -> Void)?) {
        FocusManager.focus(
            id,
            onKey: { [weak self] event in
                guard let self else { return false }
                return self.handleKey(event, binding: binding, onSubmit: onSubmit)
            },
            onChar: { [weak self] character in
                guard let self else { return false }
                self.editing.insert(String(character))
                binding.wrappedValue = self.editing.text
                self.afterEdit()
                return true
            }
        )
    }

    /// Clipboard text in the form this control can hold.
    ///
    /// Two separate corrections, and only the second depends on the control:
    ///
    /// **Line endings are normalised to `\n` first, always.** A clipboard
    /// filled by a browser, a Windows tool or a terminal often carries CRLF,
    /// and a stray CR is not a cosmetic problem here: `SoftWrap` treats
    /// `"\r\n"` as one grapheme, so a buffer holding any CR falls off the
    /// ASCII fast path and re-scans the whole thing as `Character`s on every
    /// mount — documented there as ~130ms on a 10 MB log.
    ///
    /// **Newlines survive only in a multiline control.** A single-line field
    /// has nowhere to show a line break, so it becomes a space rather than an
    /// invisible character that moves the caret somewhere the text is not.
    /// A multiline field and `EditorView` take the text as it is: pasting a
    /// stack trace into a log pane and getting one long line was the bug this
    /// replaces.
    func pastable(_ raw: String) -> String {
        var text = raw
        // Guarded because the scan is the whole cost on a large paste, and a
        // clipboard filled on this platform usually has no CR at all.
        if text.contains("\r") {
            text = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        }
        guard !isMultiline else { return text }
        return text.replacingOccurrences(of: "\n", with: " ")
    }

    /// Called after any key: an offscreen caret reads as a frozen editor.
    func followCaret() {
        guard let f = font ?? FontStore.default else { return }
        scrollToCaret(lineHeight: f.lineHeight)
        scrollToCaretX(font: f)
    }

    private func afterEdit() {
        text = editing.text.isEmpty ? placeholder : editing.text
        // Force soft-wrap to recompute even though the box width has not
        // changed. Only the *text* mark is cleared: `lastMeasuredWidth` is
        // what tells `refreshVisualRows` whether every line has to be broken
        // again or only the ones that actually changed, and clearing it here
        // threw away the per-line wrap cache on every keystroke — the whole
        // file re-shaped to answer an edit to one line of it.
        lastWrappedText = ""
        lastLogicalRowsText = nil
        // Immediate logical-row table so followCaret / measure do not rescan
        // the buffer on every layout access while wrap is pending.
        seedLogicalRows()
        markMeasureDirty()
        CaretBlink.noteEdit()
        ViewInvalidation.markDirty()
    }

    /// A key that moved the caret or the selection and left the buffer alone.
    ///
    /// Everything `afterEdit` does beyond this rebuilds row tables, and rows
    /// do not move when the text does not. Running it after every key is what
    /// made navigation cost a rescan of the *whole buffer* per press, so the
    /// cost tracked the file's size rather than the distance travelled: on a
    /// 3.9 MB log, 58 ms a Page Down with wrapping off — a full
    /// `VisualLayout.logicalRows` walk — and 4.4 s with it on, because the
    /// cleared width mark also re-shaped and re-broke all 11,631 lines.
    private func afterCaretMove() {
        CaretBlink.noteEdit()
        ViewInvalidation.markDirty()
    }

    /// What Tab inserts in an editor. See the `KeyCode.tab` case.
    static let indentUnit = "    "

    private func handleKey(
        _ event: KeyEvent, binding: Binding<String>, onSubmit: (() -> Void)?
    ) -> Bool {
        let shift = event.shift
        // The revision, not the text: it is process-unique and bumped by every
        // mutation, so "did this key edit anything" is an integer compare
        // instead of a comparison of two multi-megabyte buffers.
        let before = editing.revision

        switch event.key {
        case KeyCode.left:
            event.control ? editing.moveWordLeft(extending: shift)
                          : editing.moveLeft(extending: shift)
        case KeyCode.right:
            event.control ? editing.moveWordRight(extending: shift)
                          : editing.moveRight(extending: shift)
        case KeyCode.up:
            editing.moveUp(extending: shift)
        case KeyCode.down:
            editing.moveDown(extending: shift)
        case KeyCode.home:
            // Ctrl+Home is buffer start; bare Home is line start, which only
            // differ once there is more than one line.
            event.control ? editing.moveToStart(extending: shift)
                          : editing.moveToLineStart(extending: shift)
        case KeyCode.end:
            event.control ? editing.moveToEnd(extending: shift)
                          : editing.moveToLineEnd(extending: shift)
        case KeyCode.backspace:
            event.control ? editing.deleteWordBackward() : editing.deleteBackward()
        case KeyCode.delete:
            editing.deleteForward()
        case KeyCode.enter:
            if isMultiline, !event.control {
                editing.insert("\n")
            } else {
                onSubmit?()
            }
        case KeyCode.pageUp, KeyCode.pageDown:
            guard isMultiline else { return false }
            // A screenful, minus a row of overlap so the line the eye was on
            // is still there after the jump — the convention every pager and
            // editor follows, and what stops a page down from losing the
            // reader's place.
            let lineHeight = (font ?? FontStore.default)?.lineHeight ?? 18
            let screenful = viewportHeight > 0
                ? Int(viewportHeight / lineHeight)
                : max(1, maxLines)
            let step = max(1, screenful - 1)
            for _ in 0..<step {
                if event.key == KeyCode.pageUp {
                    editing.moveUp(extending: shift)
                } else {
                    editing.moveDown(extending: shift)
                }
            }
        case KeyCode.tab where kind == .editor && !event.shift:
            // Spaces, not a tab character. The shaper has no notion of a tab
            // stop, so a `\t` in the buffer is a character the font has no
            // glyph for and draws as a tofu box — an editor whose Tab key
            // produced that would be making the problem worse on purpose.
            // Four is the common default; Shift+Tab has no outdent yet, so it
            // falls through to focus traversal rather than pretending.
            editing.insert(Self.indentUnit)
        case KeyCode.escape:
            FocusManager.resignFocus(id)
        case KeyCode.a where event.control:
            editing.selectAll()
        case KeyCode.z where event.control && event.shift:
            editing.redo()
        case KeyCode.z where event.control:
            editing.undo()
        // Ctrl+Y is the Windows-style redo; both are common enough to accept.
        case KeyCode.y where event.control:
            editing.redo()
        case KeyCode.c where event.control:
            if editing.hasSelection { ClipboardBridge.write(editing.selectedText) }
        case KeyCode.x where event.control:
            if editing.hasSelection {
                ClipboardBridge.write(editing.selectedText)
                editing.deleteBackward()
            }
        case KeyCode.v where event.control:
            let pasted = pastable(ClipboardBridge.read())
            if !pasted.isEmpty {
                // One `insert`, not one per line: it is one edit, so it is one
                // undo step and one re-wrap rather than a thousand of each.
                editing.insert(pasted)
            }
        default:
            return false
        }

        if editing.revision != before {
            binding.wrappedValue = editing.text
            // Refresh row cache *before* followCaret: deletion leaves
            // visualRows nil (see TextEditingState.replace), and scroll
            // clamping shapes the widest rows from `layout`.
            afterEdit()
        } else {
            afterCaretMove()
        }
        followCaret()
        return true
    }
}

/// Indirection so `LavaUI` views can reach the clipboard without every view
/// carrying an `Editor` reference. The app installs this once at startup.
public enum ClipboardBridge {
    nonisolated(unsafe) public static var reader: (() -> String)?
    nonisolated(unsafe) public static var writer: ((String) -> Void)?
    /// PNG of the seat selection, when it is an image. Nil if the host
    /// cannot read pictures (windowed GLFW) or the selection is text.
    nonisolated(unsafe) public static var imageReader: (() -> [UInt8])?

    /// The *primary* selection — what middle-click pastes. A second selection,
    /// filled by the act of selecting rather than by a copy command, which is
    /// why a widget writes it from wherever a drag ends rather than from a
    /// keybinding.
    ///
    /// Separate closures rather than a flag, because the two are separate
    /// protocols under a compositor and the host wires whichever it has: left
    /// nil, primary simply does nothing, and middle-click pastes nothing.
    nonisolated(unsafe) public static var primaryReader: (() -> String)?
    nonisolated(unsafe) public static var primaryWriter: ((String) -> Void)?

    public static func read() -> String { reader?() ?? "" }
    public static func write(_ text: String) { writer?(text) }
    public static func readImage() -> [UInt8]? { imageReader?() }
    public static func readPrimary() -> String { primaryReader?() ?? "" }
    public static func writePrimary(_ text: String) { primaryWriter?(text) }
}

/// The primary selection for a process with no display server behind it.
///
/// `LavaApp` points `ClipboardBridge`'s primary closures here, so a windowed
/// app has the middle-click paste its client-mode twin gets from the seat —
/// within itself, which is as far as a lone window can see.
enum LocalPrimarySelection {
    nonisolated(unsafe) static var text: String = ""
}
