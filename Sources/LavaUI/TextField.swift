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
            guard widthMoved || textNow != lastWrappedText else { return }
            lastMeasuredWidth = availableWidth
            lastWrappedText = textNow

            // The gutter is not part of the wrap width. Zero for a text
            // field, which is why this expression serves both.
            let inner = max(8, availableWidth - gutterWidth - textInset * 2)
            // A different width breaks every line somewhere else, so nothing
            // survives it. An edit leaves all but one line alone.
            let reusableLines = widthMoved ? [] : wrapCacheLines
            let reusableRows = widthMoved ? [] : wrapCacheRows

            let lines = editing.lines
            var rows: [Range<Int>] = []
            var logicalLine: [Int] = []
            var columnStart: [Int] = []
            var nextRows: [[Range<Int>]] = []
            nextRows.reserveCapacity(lines.count)
            var base = 0
            for (index, line) in lines.enumerated() {
                let broken: [Range<Int>]
                if index < reusableLines.count, index < reusableRows.count,
                   reusableLines[index] == line
                {
                    broken = reusableRows[index]
                } else {
                    // Shaping is what this whole cache exists to avoid: it is
                    // the cost of the line, and there are as many lines as
                    // there are lines.
                    let s = String(line)
                    let advances = f.shapedRun(s).characterAdvances
                    broken = SoftWrap.rows(text: s, advances: advances, maxWidth: inner)
                }
                nextRows.append(broken)
                for r in broken {
                    rows.append((base + r.lowerBound)..<(base + r.upperBound))
                    logicalLine.append(index)
                    columnStart.append(r.lowerBound)
                }
                base += line.count + 1  // + the newline that separated them
            }
            editing.setVisualRows(rows)
            rowLogicalLine = logicalLine
            rowColumnStart = columnStart
            wrapCacheLines = lines
            wrapCacheRows = nextRows
            return
        }

        // No wrapping: one row per logical line, cached the same way.
        guard editing.text != lastLogicalRowsText else { return }
        seedLogicalRows()
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
        editing.setVisualRows(VisualLayout.logicalRows(editing.text))
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
        // Force soft-wrap to recompute even when the box width is unchanged.
        lastMeasuredWidth = -1
        lastWrappedText = ""
        lastLogicalRowsText = nil
        // Immediate logical-row table so followCaret / measure do not rescan
        // the buffer on every layout access while wrap is pending.
        seedLogicalRows()
        markMeasureDirty()
        CaretBlink.noteEdit()
        ViewInvalidation.markDirty()
    }

    /// What Tab inserts in an editor. See the `KeyCode.tab` case.
    static let indentUnit = "    "

    private func handleKey(
        _ event: KeyEvent, binding: Binding<String>, onSubmit: (() -> Void)?
    ) -> Bool {
        let shift = event.shift
        let before = editing.text

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

        if editing.text != before { binding.wrappedValue = editing.text }
        // Refresh row cache *before* followCaret: deletion leaves visualRows
        // nil (see TextEditingState.replace), and scroll clamping shapes the
        // widest rows from `layout`.
        afterEdit()
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
