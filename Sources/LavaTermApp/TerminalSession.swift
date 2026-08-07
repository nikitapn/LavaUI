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

    /// Key → PTY bytes (CSI where appropriate).
    public func handleKey(_ event: KeyEvent) -> Bool {
        if event.control {
            if let b = controlByte(for: event.key) {
                write(Data([b]))
                return true
            }
        }

        switch event.key {
        case KeyCode.enter:
            write("\r")
        case KeyCode.backspace:
            write(Data([0x7F]))  // DEL — what most modern shells expect
        case KeyCode.tab:
            write("\t")
        case KeyCode.escape:
            write(Data([0x1B]))
        case KeyCode.up:
            write("\u{1B}[A")
        case KeyCode.down:
            write("\u{1B}[B")
        case KeyCode.right:
            write("\u{1B}[C")
        case KeyCode.left:
            write("\u{1B}[D")
        case KeyCode.home:
            write("\u{1B}[H")
        case KeyCode.end:
            write("\u{1B}[F")
        case KeyCode.delete:
            write("\u{1B}[3~")
        default:
            return false
        }
        return true
    }

    public func handleChar(_ ch: Character) -> Bool {
        // Control characters come via keys; ignore here.
        if ch.asciiValue.map({ $0 < 0x20 || $0 == 0x7F }) == true {
            return false
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
