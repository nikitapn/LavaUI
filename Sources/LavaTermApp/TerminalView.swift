import Foundation
import LavaUI
import LavaTermCore

/// Full-window terminal: a slim client chrome (controls + path) over the grid.
///
/// No compositor title bar when run as a client (`frame: .client`). The strip
/// at the top is the window's own: min/max/close on the left, the current
/// working directory after them, and the whole strip is a drag handle so
/// there is still somewhere to grab without a server-drawn frame.
public struct TerminalView: View {
    let session: TerminalSession
    /// Monospace face loaded once in `main`.
    let mono: UIFont
    let cellW: Float
    let cellH: Float

    public init(session: TerminalSession, mono: UIFont) {
        self.session = session
        self.mono = mono
        let run = mono.shapedRun("M")
        self.cellW = max(1, run.width > 0 ? run.width : mono.pixelSize * 0.6)
        self.cellH = max(1, mono.lineHeight)
    }

    public var body: some View {
        // Path / generation so the chrome and the grid both rebuild when the
        // shell reports a new cwd or paints new cells.
        let _ = session.pathLabel
        let _ = session.generation

        let theme = Theme.current
        return VStack(padding: 0, spacing: 0) {
            TitleStrip(path: session.pathLabel)
                .background(theme.panel.opacity(TerminalPalette.windowAlpha))

            TerminalCanvas(
                session: session,
                mono: mono,
                cellW: cellW,
                cellH: cellH
            )
            .frame(width: .pct(100), height: .pt(30))
            .flexGrow(1)
        }
        .frame(width: .pct(100), height: .pct(100))
        // Empty space in the strip moves the window; the controls and the
        // canvas still take their own hits first.
        .windowDrag()
    }
}

/// Client chrome: window controls, then the path. Replaces the old "LavaTerm
/// / shell · cols×rows" header and the decorative footer.
private struct TitleStrip: View {
    let path: String

    var body: some View {
        HStack(padding: 10, alignment: .center, spacing: 10) {
            if WindowBridge.drawsOwnChrome {
                WindowControls()
            }
            Text(path, color: Theme.current.textSecondary)
            Spacer()
        }
        .frame(height: .pt(36))
    }
}

/// Interactive grid. `Canvas` paints cells; keyboard is routed via
/// `FocusManager` with a stable synthetic `NodeID` (Canvas does not expose its
/// leaf id to the view body).
struct TerminalCanvas: View {
    let session: TerminalSession
    let mono: UIFont
    let cellW: Float
    let cellH: Float

    @State private var focused = false

    var body: some View {
        // Track generation so observation rebuilds after PTY output.
        let _ = session.generation
        let _ = focused

        // A terminal is the only thing in its window worth typing into, so it
        // says so once and stops depending on a click to find that out. Two
        // parts, and both are needed:
        //
        //   * the default target, so a key arriving while nothing holds focus
        //     still reaches the shell — which is the state the window opens
        //     in, and the state anything that clears focus leaves it in;
        //   * taking focus outright when it is free, so the caret is drawn and
        //     the grid is visibly live rather than merely working.
        //
        // Neither overrides a real claim: a field that takes focus keeps it,
        // and gets it back the moment it asks.
        registerAsDefaultTarget()
        if FocusManager.focusedID == nil, !focused { takeFocus() }

        return Canvas(
            label: "terminal",
            flexGrow: 1,
            // No continuous redraw: the caret is a solid block, not a blink.
            // PTY output still dirties the frame via `session.generation`.
            continuousRedraw: false,
            onTap: {
                takeFocus()
            },
            onGesture: { gesture in
                switch gesture.phase {
                case .began:
                    takeFocus()
                    // Middle button: paste what was last selected, anywhere,
                    // and leave this terminal's own selection alone. Older
                    // than the clipboard and still the fastest thing in a
                    // terminal — highlight there, middle-click here.
                    if gesture.button == PointerButton.middle {
                        session.pastePrimary()
                        return
                    }
                    guard gesture.button == PointerButton.left else { return }
                    session.beginSelection(
                        atX: gesture.localX + gesture.frame.x,
                        y: gesture.localY + gesture.frame.y,
                        clicks: gesture.clickCount
                    )
                case .moved:
                    // Local coordinates go negative and past the edges once a
                    // drag leaves the box, which is exactly what selecting to
                    // the end of a line means — `TerminalGeometry` clamps.
                    session.extendSelection(
                        toX: gesture.localX + gesture.frame.x,
                        y: gesture.localY + gesture.frame.y
                    )
                case .ended:
                    session.endSelection()
                }
            },
            onWheel: { _, dy, _, _ in
                // Positive dy is wheel-up (GLFW), which means "look further
                // into history". A few lines per notch feels like a terminal
                // rather than a document.
                let notches = Int(dy.rounded())
                guard notches != 0 else { return }
                takeFocus()
                _ = session.scrollHistory(by: notches * 3)
            },
            paint: { list, frame in
                paint(list: list, frame: frame)
            }
        )
    }

    private func takeFocus() {
        focused = true
        FocusManager.focus(
            session.focusID,
            onKey: { [session] event in session.handleKey(event) },
            onChar: { [session] ch in session.handleChar(ch) }
        )
        ViewInvalidation.markDirty()
    }

    /// Says where keys go when nothing is focused.
    ///
    /// Re-asserted on every body pass rather than once at mount: it costs two
    /// stores, and the alternative is a lifecycle question — which pass was
    /// the first one, and whether the window scope existed yet — whose wrong
    /// answer is a terminal that silently ignores the keyboard.
    private func registerAsDefaultTarget() {
        FocusManager.setDefault(
            session.focusID,
            onKey: { [session] event in session.handleKey(event) },
            onChar: { [session] ch in session.handleChar(ch) }
        )
    }

    private func paint(list: DrawList, frame: CanvasFrame) {
        let pad: Float = 6
        let usableW = max(0, frame.w - pad * 2)
        let usableH = max(0, frame.h - pad * 2)
        let cols = max(1, Int(usableW / cellW))
        let rows = max(1, Int(usableH / cellH))
        session.ensureSize(cols: cols, rows: rows)

        let screen = session.screen
        let originX = frame.x + pad
        let originY = frame.y + pad

        // Published for the pointer handlers, which have a pixel and need a
        // cell. Written here because this is where the numbers are decided —
        // and they are decided per frame, since the grid moves when the window
        // resizes.
        session.geometry = TerminalGeometry(
            originX: originX, originY: originY,
            cellW: cellW, cellH: cellH,
            cols: screen.cols, rows: screen.rows
        )

        list.rect(
            x: frame.x, y: frame.y, w: frame.w, h: frame.h,
            color: TerminalPalette.terminalFill
        )

        // visibleCell honours scrollback offset so history, not only the live
        // screen, is what gets painted.
        for r in 0..<screen.rows {
            var c = 0
            while c < screen.cols {
                let cell = screen.visibleCell(row: r, col: c)
                let bg = cell.displayBg
                let fg = cell.displayFg
                let bold = cell.bold
                let underline = cell.underline

                var end = c + 1
                var text = String(Character(cell.scalar))
                while end < screen.cols {
                    let next = screen.visibleCell(row: r, col: end)
                    if next.displayBg != bg
                        || next.displayFg != fg
                        || next.bold != bold
                        || next.underline != underline
                    {
                        break
                    }
                    text.append(Character(next.scalar))
                    end += 1
                }

                let x = originX + Float(c) * cellW
                let y = originY + Float(r) * cellH
                let runW = Float(end - c) * cellW

                if bg != .default || cell.inverse {
                    let bgRGB = TerminalPalette.rgb(for: bg, isForeground: false)
                    list.rect(
                        x: x, y: y, w: runW, h: cellH,
                        color: TerminalPalette.color(bgRGB)
                    )
                }

                if text.contains(where: { $0 != " " && $0 != "\u{00A0}" }) {
                    let fgRGB = TerminalPalette.rgb(for: fg, isForeground: true)
                    // DrawList.text insets pen by 4px — undo so columns align.
                    list.text(
                        text,
                        x: x - 4,
                        y: y,
                        w: runW + 4,
                        h: cellH,
                        color: TerminalPalette.color(fgRGB),
                        font: mono
                    )
                }

                if underline {
                    let uRGB = TerminalPalette.rgb(for: fg, isForeground: true)
                    list.line(
                        x1: x, y1: y + cellH - 2,
                        x2: x + runW, y2: y + cellH - 2,
                        color: TerminalPalette.color(uRGB),
                        width: 1
                    )
                }

                c = end
            }
        }

        // Over the cells rather than under them, and translucent so the text
        // reads through. A highlight drawn *before* the run loop would be
        // painted over by the background of any cell that has one of its own,
        // which is most of a `ls` and all of a syntax-highlighted file.
        if !session.selection.isEmpty {
            for r in 0..<screen.rows {
                guard let columns = session.selection.columns(
                    inRow: r, cols: screen.cols) else { continue }
                let x = originX + Float(columns.lowerBound) * cellW
                let w = Float(columns.count) * cellW
                list.rect(
                    x: x, y: originY + Float(r) * cellH, w: w, h: cellH,
                    color: TerminalPalette.selectionFill
                )
            }
        }

        // Block cursor — the solid cell highlight Vim uses in normal mode,
        // not a blinking bar. Hidden while looking at history: it still sits
        // on the live screen, and drawing it over a different row would be a
        // lie. No blink: a steady block is easier to track on a grid, and it
        // also means we do not have to burn frames for a caret phase.
        if FocusManager.isActive(session.focusID), screen.cursorVisible,
           !screen.isScrolledUp {
            let col = min(screen.cursorCol, screen.cols - 1)
            let row = screen.cursorRow
            let cx = originX + Float(col) * cellW
            let cy = originY + Float(row) * cellH
            list.rect(
                x: cx, y: cy, w: cellW, h: cellH,
                color: TerminalPalette.cursorFill
            )
            // Redraw the glyph on top so the cell stays readable under the
            // fill — same idea as reverse video without swapping the palette.
            let under = screen.visibleCell(row: row, col: col)
            let ch = Character(under.scalar)
            if ch != " " && ch != "\u{00A0}" {
                let fgRGB = TerminalPalette.rgb(
                    for: under.displayFg, isForeground: true)
                list.text(
                    String(ch),
                    x: cx - 4,
                    y: cy,
                    w: cellW + 4,
                    h: cellH,
                    color: TerminalPalette.color(fgRGB),
                    font: mono
                )
            }
        }
    }
}
