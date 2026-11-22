import Foundation
import LavaUI
import LavaTermCore
import LavaTerminal

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

    public init(session: TerminalSession, mono: UIFont) {
        self.session = session
        self.mono = mono
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
                .windowChrome()

            TerminalGrid(session: session, mono: mono)
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
        HStack(padding: 0, alignment: .center, spacing: 10) {
            if WindowBridge.drawsOwnChrome {
                WindowControls()
            }
            Text(path, color: Theme.current.textSecondary)
            Spacer()
        }
        // Horizontal only — 10 on every edge of a 36pt strip was 10px of
        // empty header under the controls, the same hole the panel hit
        // when it padded a 32pt bar on all sides.
        .padding(.horizontal, 10)
        .frame(height: .pt(36))
    }
}

