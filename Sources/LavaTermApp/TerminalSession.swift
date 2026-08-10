import Foundation
import LavaUI
import LavaTermCore
import Observation

/// Observable terminal state the LavaUI view tree reads.
///
/// `@unchecked Sendable` so the PTY reader thread can hop through
/// `MainQueue.async` (same pattern as TraceLoom's assistant session).
@Observable
public final class TerminalSession: @unchecked Sendable {
    public let screen = TerminalScreen(cols: 80, rows: 24)
    public private(set) var title = "LavaTerm"
    public private(set) var exited = false
    public private(set) var exitCode: Int32 = 0
    public private(set) var statusLine = "starting…"

    /// Incremented on every PTY batch so observation notices content changes.
    public private(set) var generation: UInt64 = 0

    /// Stable focus target for `FocusManager` (Canvas does not expose its leaf id).
    public let focusID = NodeID.generate()

    /// What the pointer has chosen, and where the grid is on screen.
    ///
    /// `@ObservationIgnored` on purpose, and it is the same lesson `EditorView`
    /// records: a drag-select changes this on every pointer move, and if
    /// observation saw it the whole body would be rebuilt sixty times a second
    /// for something only the paint pass reads. The paint pass reads the
    /// current value because it runs at emit; `markNeedsRedraw` is what asks
    /// for the frame.
    @ObservationIgnored var selection = TerminalSelection()
    /// Written by the paint pass, read by the pointer handlers — the mapping
    /// only the layout knows, and the same variable `LauncherLayout.columns`
    /// is for. Both run on the frame loop, which is the whole of the
    /// synchronisation.
    @ObservationIgnored var geometry: TerminalGeometry?

    private var pty: PtySession?
    private var lastCols = 80
    private var lastRows = 24

    public init() {}

    public func start() {
        statusLine = "opening PTY…"
        let session = PtySession(
            onData: { [weak self] data in
                guard let self else { return }
                MainQueue.async { [self] in
                    self.ingest(data)
                }
            },
            onExit: { [weak self] code in
                guard let self else { return }
                MainQueue.async { [self] in
                    self.exited = true
                    self.exitCode = code
                    self.statusLine = "shell exited (\(code))"
                    self.bump()
                }
            }
        )
        if session.start(cols: screen.cols, rows: screen.rows) {
            pty = session
            statusLine = "shell · \(screen.cols)×\(screen.rows)"
            bump()
        } else {
            statusLine = "failed to open PTY"
            feedLocal("LavaTerm: failed to open PTY / fork shell.\n")
        }
    }

    public func stop() {
        pty?.stop()
        pty = nil
    }

    public func write(_ data: Data) {
        pty?.write(data)
    }

    public func write(_ string: String) {
        pty?.write(string)
    }

    // MARK: - Selection

    /// Begins a selection under the pointer. `clicks` is 1, 2 or 3 — character,
    /// word, or the whole row.
    public func beginSelection(atX x: Float, y: Float, clicks: Int) {
        guard let geometry else { return }
        let granularity: TerminalSelection.Granularity =
            clicks >= 3 ? .line : (clicks == 2 ? .word : .character)
        selection.begin(
            at: geometry.cell(atX: x, y: y), granularity: granularity, in: screen)
        ViewInvalidation.markNeedsRedraw()
    }

    public func extendSelection(toX x: Float, y: Float) {
        guard let geometry else { return }
        selection.extend(to: geometry.cell(atX: x, y: y), in: screen)
        ViewInvalidation.markNeedsRedraw()
    }

    /// A press that never moved is a click, and a click puts the selection
    /// away — the same thing clicking in a text editor does.
    public func endSelection() {
        if !selection.dragged, selection.granularity == .character {
            selection.clear()
        } else {
            // Selecting *is* the copy, for the primary selection. No shortcut,
            // no menu: this is the whole of the Unix convention that middle
            // click pastes what you last highlighted, and it is why it has to
            // happen here rather than anywhere a user might press something.
            let text = selection.text(from: screen)
            if !text.isEmpty { ClipboardBridge.writePrimary(text) }
        }
        ViewInvalidation.markNeedsRedraw()
    }

    public func clearSelection() {
        guard !selection.isEmpty else { return }
        selection.clear()
        ViewInvalidation.markNeedsRedraw()
    }

    /// The selection to the clipboard. False when there was nothing selected,
    /// so the caller can let the key through to the shell instead.
    @discardableResult
    public func copySelection() -> Bool {
        let text = selection.text(from: screen)
        guard !text.isEmpty else { return false }
        ClipboardBridge.writer?(text)
        return true
    }

    /// The primary selection to the shell — what middle-click does.
    public func pastePrimary() {
        insert(ClipboardBridge.readPrimary())
    }

    /// Clipboard to the shell, as if it had been typed.
    public func paste() {
        insert(ClipboardBridge.read())
    }

    private func insert(_ text: String) {
        guard !text.isEmpty else { return }
        // Newlines included: pasting three lines into a shell runs three
        // commands, which is what every other terminal does and what anyone
        // pasting a snippet expects. Bracketed paste is the day this needs to
        // be able to say "this came from a clipboard".
        write(text)
    }

    /// Key → PTY bytes (CSI where appropriate).
    public func handleKey(_ event: KeyEvent) -> Bool {
        // Before the control-byte mapping below, which would otherwise turn
        // these into ^C and ^V. Shift is what separates them: Ctrl+C has to
        // stay the interrupt, because a terminal where it copied instead
        // would be a terminal that cannot stop a runaway process.
        if event.control, event.shift {
            switch event.key {
            case KeyCode.c:
                if copySelection() { return true }
            case KeyCode.v:
                paste()
                return true
            default:
                break
            }
        }

        // What this key sends, decided before anything is done about it.
        //
        // Worked out first because a key that sends nothing must change
        // nothing: pressing Ctrl is the first half of Ctrl+Shift+C, and a
        // version of this that cleared the selection on the way past — as this
        // one did — makes the shortcut impossible to reach. Modifiers arrive
        // as key events of their own, and they are typed by definition before
        // every chord.
        let payload: Data? = {
            if event.control, let b = controlByte(for: event.key) {
                return Data([b])
            }
            switch event.key {
            case KeyCode.enter: return Data("\r".utf8)
            case KeyCode.backspace: return Data([0x7F])  // DEL — what most modern shells expect
            case KeyCode.tab: return Data("\t".utf8)
            case KeyCode.escape: return Data([0x1B])
            // DECCKM: application mode (what tmux/vim ask for) uses SS3
            // rather than CSI. Sending the wrong spelling is why arrows in
            // tmux looked "pretty bad" even after the alternate screen worked.
            case KeyCode.up:
                return Data((screen.applicationCursorKeys ? "\u{1B}OA" : "\u{1B}[A").utf8)
            case KeyCode.down:
                return Data((screen.applicationCursorKeys ? "\u{1B}OB" : "\u{1B}[B").utf8)
            case KeyCode.right:
                return Data((screen.applicationCursorKeys ? "\u{1B}OC" : "\u{1B}[C").utf8)
            case KeyCode.left:
                return Data((screen.applicationCursorKeys ? "\u{1B}OD" : "\u{1B}[D").utf8)
            case KeyCode.home:
                return Data((screen.applicationCursorKeys ? "\u{1B}OH" : "\u{1B}[H").utf8)
            case KeyCode.end:
                return Data((screen.applicationCursorKeys ? "\u{1B}OF" : "\u{1B}[F").utf8)
            case KeyCode.delete: return Data("\u{1B}[3~".utf8)
            default: return nil
            }
        }()

        guard let payload else { return false }

        // Typing puts the selection away: the highlight describes text that is
        // about to be scrolled off or overwritten, and leaving it on screen
        // would point at whatever happened to land there next.
        clearSelection()
        write(payload)
        return true
    }

    public func handleChar(_ ch: Character) -> Bool {
        // Control characters come via keys; ignore here.
        if ch.asciiValue.map({ $0 < 0x20 || $0 == 0x7F }) == true {
            return false
        }
        clearSelection()
        write(String(ch))
        return true
    }

    /// Resize screen + PTY when the canvas geometry changes.
    public func ensureSize(cols: Int, rows: Int) {
        let c = max(1, cols)
        let r = max(1, rows)
        guard c != lastCols || r != lastRows else { return }
        lastCols = c
        lastRows = r
        screen.resize(cols: c, rows: r)
        pty?.resize(cols: c, rows: r)
        statusLine = exited
            ? "shell exited (\(exitCode)) · \(c)×\(r)"
            : "shell · \(c)×\(r)"
        bump()
    }

    // MARK: - Private

    private func ingest(_ data: Data) {
        screen.feed(data)
        bump()
    }

    private func feedLocal(_ message: String) {
        screen.feed(message)
        bump()
    }

    private func bump() {
        generation &+= 1
        ViewInvalidation.markDirty()
    }

    private func controlByte(for key: Int32) -> UInt8? {
        // Ctrl+A … Ctrl+Z → 1…26
        if key >= KeyCode.a && key <= KeyCode.z {
            return UInt8(key - KeyCode.a + 1)
        }
        switch key {
        case KeyCode.space: return 0  // Ctrl+Space
        case 92: return 0x1C         // Ctrl+\
        case 93: return 0x1D         // Ctrl+]
        default: return nil
        }
    }
}
