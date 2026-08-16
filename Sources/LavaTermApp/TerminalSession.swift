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
    /// Window / tab label from OSC title, or "LavaTerm" until the shell says.
    public private(set) var title = "LavaTerm"
    /// Path shown in the chrome. Prefers OSC 7 cwd, then a title that looks
    /// like a path, then a short idle label.
    public private(set) var pathLabel = "~"
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
        // Seed the chrome with this process's cwd — the shell usually starts
        // there, and OSC 7 will refine it once the shell reports in.
        pathLabel = Self.displayPath(
            cwd: FileManager.default.currentDirectoryPath, title: "")
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
            publishSelection()
        }
        ViewInvalidation.markNeedsRedraw()
    }

    /// Selecting *is* the copy. Claude Code and most modern terminals put
    /// the highlight on the clipboard on release, so Ctrl+V already has it.
    /// Primary is filled too — middle-click still pastes, and `wl-paste
    /// --primary` still sees the drag.
    private func publishSelection() {
        let text = selection.text(from: screen)
        guard !text.isEmpty else { return }
        ClipboardBridge.write(text)
        ClipboardBridge.writePrimary(text)
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
    ///
    /// Text first. A screenshot (Print Screen / Flameshot crop) has no
    /// text MIME — that used to paste nothing. The PNG is written to a
    /// temp file and the path is inserted, which is what a shell can use
    /// and what Grok treats as a file. Grok's own image-chip paste is
    /// Ctrl+V sent through to the app (not this method).
    public func paste() {
        let text = ClipboardBridge.read()
        if !text.isEmpty {
            insert(text)
            return
        }
        if let png = ClipboardBridge.readImage(), !png.isEmpty {
            insert(writePasteImage(png))
        }
    }

    /// Writes `png` under `$TMPDIR` and returns the path, or empty on failure.
    private func writePasteImage(_ png: [UInt8]) -> String {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("lava-clip-\(UUID().uuidString).png")
        do {
            try Data(png).write(to: url, options: .atomic)
            return url.path
        } catch {
            return ""
        }
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
        // Shift+Insert is the other terminal-native paste. Leave Ctrl+V
        // for the application — Grok reads the seat clipboard on that
        // chord to attach a screenshot, and intercepting it (as the
        // Edit menu used to) pastes empty text and swallows the key.
        if event.shift, !event.control, event.key == KeyCode.insert {
            paste()
            return true
        }

        // What this key sends, decided before anything is done about it.
        //
        // Worked out first because a key that sends nothing must change
        // nothing: pressing Ctrl is the first half of Ctrl+Shift+C, and a
        // version of this that cleared the selection on the way past — as this
        // one did — makes the shortcut impossible to reach. Modifiers arrive
        // as key events of their own, and they are typed by definition before
        // every chord.
        // Shift+PageUp/Down scrolls *our* history, the way xterm does — plain
        // PageUp/Down go to the application so tmux's Ctrl+b then PageUp can
        // enter copy-mode. Without the plain mapping those keys vanished.
        if event.shift, !event.control {
            switch event.key {
            case KeyCode.pageUp:
                if scrollHistory(by: screen.rows) { return true }
            case KeyCode.pageDown:
                if scrollHistory(by: -screen.rows) { return true }
            default:
                break
            }
        }

        let payload: Data? = {
            // Ctrl+letter is a C0 control byte, not a modified CSI. Must run
            // before the cursor-key path or Ctrl+C would become CSI 1;5 something.
            if event.control, !event.alt, !event.shift,
               let b = controlByte(for: event.key)
            {
                return Data([b])
            }
            switch event.key {
            case KeyCode.enter: return Data("\r".utf8)
            case KeyCode.backspace:
                // Plain Backspace is DEL (0x7F), which most modern shells
                // expect. Alt+Backspace is Meta-DEL (`ESC DEL`): readline and
                // zsh bind that to backward-kill-word — delete the token to
                // the left, not one character. Ctrl+W is the other common
                // spelling of the same idea and already goes out as ^W.
                if event.alt {
                    return Data([0x1B, 0x7F])
                }
                return Data([0x7F])
            case KeyCode.tab: return Data("\t".utf8)
            case KeyCode.escape: return Data([0x1B])
            case KeyCode.up: return cursorKey(final: "A", event: event)
            case KeyCode.down: return cursorKey(final: "B", event: event)
            case KeyCode.right: return cursorKey(final: "C", event: event)
            case KeyCode.left: return cursorKey(final: "D", event: event)
            case KeyCode.home: return cursorKey(final: "H", event: event)
            case KeyCode.end: return cursorKey(final: "F", event: event)
            case KeyCode.insert: return functionKey(code: 2, event: event)
            case KeyCode.delete: return functionKey(code: 3, event: event)
            case KeyCode.pageUp: return functionKey(code: 5, event: event)
            case KeyCode.pageDown: return functionKey(code: 6, event: event)
            default: return nil
            }
        }()

        guard let payload else { return false }

        // Typing puts the selection away: the highlight describes text that is
        // about to be scrolled off or overwritten, and leaving it on screen
        // would point at whatever happened to land there next.
        clearSelection()
        // And jumps the viewport to the live bottom — you are about to type
        // into a prompt you cannot see if still scrolled into history.
        if screen.isScrolledUp {
            screen.scrollToBottom()
            ViewInvalidation.markNeedsRedraw()
        }
        write(payload)
        return true
    }

    /// Wheel / Shift+Page* history navigation. Positive `delta` looks further
    /// into the past. On the alternate screen there is no history; notches
    /// become arrow keys so less/vim/tmux still move.
    @discardableResult
    public func scrollHistory(by delta: Int) -> Bool {
        guard delta != 0 else { return false }
        if screen.onAlternateScreen {
            // One CSI arrow per notch. Same DECCKM spelling as the real keys.
            let seq = delta > 0
                ? (screen.applicationCursorKeys ? "\u{1B}OA" : "\u{1B}[A")
                : (screen.applicationCursorKeys ? "\u{1B}OB" : "\u{1B}[B")
            let steps = abs(delta)
            var bytes = Data()
            bytes.reserveCapacity(seq.utf8.count * steps)
            for _ in 0..<steps {
                bytes.append(contentsOf: seq.utf8)
            }
            write(bytes)
            return true
        }
        guard screen.scrollView(by: delta) else { return false }
        clearSelection()
        ViewInvalidation.markNeedsRedraw()
        return true
    }

    public func handleChar(_ ch: Character) -> Bool {
        // Control characters come via keys; ignore here.
        if ch.asciiValue.map({ $0 < 0x20 || $0 == 0x7F }) == true {
            return false
        }
        clearSelection()
        if screen.isScrolledUp {
            screen.scrollToBottom()
        }
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
        if let clip = screen.pendingClipboard {
            screen.pendingClipboard = nil
            ClipboardBridge.write(clip)
        }
        syncChromeFromScreen()
        bump()
    }

    private func feedLocal(_ message: String) {
        screen.feed(message)
        syncChromeFromScreen()
        bump()
    }

    private func bump() {
        generation &+= 1
        ViewInvalidation.markDirty()
    }

    /// Pull title / cwd off the screen after a feed. Only dirty when something
    /// the chrome shows actually changed — OSC traffic is frequent and most
    /// of it is a title rewrite of the same path.
    private func syncChromeFromScreen() {
        if !screen.windowTitle.isEmpty, screen.windowTitle != title {
            title = screen.windowTitle
        }
        let next = Self.displayPath(
            cwd: screen.workingDirectory, title: screen.windowTitle)
        if next != pathLabel {
            pathLabel = next
        }
    }

    /// What the title strip should say. Home is collapsed to `~` so a long
    /// path still fits; OSC 7 wins over the title string when both exist.
    private static func displayPath(cwd: String, title: String) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        func shorten(_ path: String) -> String {
            if !home.isEmpty, path == home { return "~" }
            if !home.isEmpty, path.hasPrefix(home + "/") {
                return "~" + path.dropFirst(home.count)
            }
            return path
        }
        if !cwd.isEmpty { return shorten(cwd) }
        if title.hasPrefix("/") || title.hasPrefix("~") {
            return shorten(title)
        }
        // Titles like `user@host: ~/proj` — take the part after the last ": ".
        if let range = title.range(of: ": ", options: .backwards) {
            let tail = String(title[range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if tail.hasPrefix("/") || tail.hasPrefix("~") {
                return shorten(tail)
            }
            if !tail.isEmpty { return tail }
        }
        return title.isEmpty ? "~" : title
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

    // MARK: - Cursor / function keys (xterm)

    /// xterm modifier parameter: 1 + shift + 2·alt + 4·ctrl.
    ///
    /// So plain = 1 (omitted), Shift = 2, Alt = 3, Ctrl = 5, Ctrl+Shift = 6.
    /// Ctrl+Left/Right become `CSI 1;5 D/C`, which is what bash/zsh/readline
    /// bind to word-wise motion — the sequence bare CSI D never carried.
    private func xtermModifier(for event: KeyEvent) -> Int {
        var mod = 1
        if event.shift { mod += 1 }
        if event.alt { mod += 2 }
        if event.control { mod += 4 }
        return mod
    }

    /// Arrows / Home / End. Unmodified honour DECCKM (application cursor
    /// keys); any modifier forces the CSI form with the xterm mod parameter,
    /// because `ESC O A` has no place to put one.
    private func cursorKey(final: String, event: KeyEvent) -> Data {
        let mod = xtermModifier(for: event)
        if mod == 1 {
            if screen.applicationCursorKeys {
                return Data("\u{1B}O\(final)".utf8)
            }
            return Data("\u{1B}[\(final)".utf8)
        }
        // CSI 1 ; mod final — the leading 1 is the "default" of CUP-style
        // params that xterm uses for modified cursor keys.
        return Data("\u{1B}[1;\(mod)\(final)".utf8)
    }

    /// Insert / Delete / PageUp / PageDown: `CSI n ~` or `CSI n ; mod ~`.
    private func functionKey(code: Int, event: KeyEvent) -> Data {
        let mod = xtermModifier(for: event)
        if mod == 1 {
            return Data("\u{1B}[\(code)~".utf8)
        }
        return Data("\u{1B}[\(code);\(mod)~".utf8)
    }
}
