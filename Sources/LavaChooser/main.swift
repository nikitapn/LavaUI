import Foundation
import LavaClient
import LavaIDL
import LavaUI
import Observation

// The screen picker xdg-desktop-portal-wlr asks for before a screen share.
//
//   OBS / Teams → xdg-desktop-portal → xdpw → chooser_cmd → this
//
// xdpw's own choosers (slurp, wofi, rofi, bemenu, fuzzel) all draw through
// `zwlr_layer_shell_v1`, which this compositor does not implement — slurp
// exits, xdpw reports "no output found", and the share dies before the user
// sees anything. This is that picker as an ordinary Lava client.
//
// The protocol is a pipe, not a library. xdpw writes one line per output on
// stdin:
//
//     Monitor: DP-3 Lenovo Group Limited D24-20 UR60D77A (DP-3)
//
// and reads back exactly one of those lines. Nothing on stdout means the
// user declined, and any exit code but 127 is fine (127 is xdpw's "no such
// command"). It runs during `SelectSources`, with the D-Bus call held open,
// so this window is on the critical path of somebody's meeting: open, be
// clicked, exit.
//
// **The answer never goes to stdout from here.** `chooser_cmd` is a wrapper
// that reads `$LAVA_CHOOSER_OUT` and prints that; the framework writes frame
// probes to stdout when they are enabled (see LavaWindow.swift) and one
// stray line would corrupt a screen share into "user declined". Diagnostics
// go to stderr, which xdpw ignores.

/// One row: what xdpw called it, and what a person calls it.
struct Screen {
    /// The stdin line, returned verbatim. xdpw matches on the whole string.
    let line: String
    /// Connector: "DP-3", "eDP-1".
    let connector: String
    /// "1920 × 1080 · 75 Hz", or empty when the compositor has not heard of
    /// this output — a screen unplugged between xdpw's list and this window.
    let mode: String
}

/// Strips the `Monitor: ` prefix and takes the connector, which is the first
/// word after it. The rest of the line is the display's own description and
/// is not shown: the user asked for connector and resolution.
func connectorName(of line: String) -> String? {
    let prefix = "Monitor: "
    guard line.hasPrefix(prefix) else { return nil }
    let rest = line.dropFirst(prefix.count)
    guard let word = rest.split(separator: " ", maxSplits: 1).first else {
        return nil
    }
    return String(word)
}

/// mHz, as wlroots counts them: 74973 is 74.973 Hz, and rounding to whole Hz
/// is what makes a mode fail to match. For a label, whole Hz is what a person
/// wants to read.
func modeLabel(_ info: OutputInfo) -> String {
    let hz = Int((Double(info.refresh) / 1000).rounded())
    let size = "\(info.width) × \(info.height)"
    return hz > 0 ? "\(size) · \(hz) Hz" : size
}

/// xdpw's list, before the compositor has been asked anything. Resolutions
/// arrive later — see `loadModes` — because the control plane does not exist
/// until `LavaClient.open` has run.
func readScreens() -> [Screen] {
    let input = String(
        data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8
    ) ?? ""
    return input.split(separator: "\n").map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .map { line in
            Screen(line: line, connector: connectorName(of: line) ?? line,
                   mode: "")
        }
}

/// Writes the answer where the wrapper will find it, then drops the surface.
///
/// `LavaClient.quit`, not bare `exit`: NPRPC only notices a dead peer on a
/// ~500 ms poll, so a process that just exits leaves its window on screen for
/// that long — half a second of a picker sitting over the meeting it was
/// supposed to get out of the way of.
func answer(_ screen: Screen?) -> Never {
    if let screen, let path = ProcessInfo.processInfo.environment["LAVA_CHOOSER_OUT"] {
        // Trailing newline: the wrapper `cat`s this straight into xdpw.
        try? (screen.line + "\n").write(
            toFile: path, atomically: true, encoding: .utf8
        )
    }
    LavaClient.quit()
}

@Observable
final class ChooserModel {
    var screens: [Screen]
    var selected: Int = 0
    var hovered: Int = -1

    init(screens: [Screen]) {
        self.screens = screens
    }

    /// Fills in the resolutions, once there is a compositor to ask.
    ///
    /// One RPC for the whole list rather than one per row, and a failure
    /// costs the labels rather than the picker: the connector name came from
    /// xdpw and is already on screen. A screen unplugged between xdpw's list
    /// and this window simply has no mode to show.
    func loadModes() {
        var modes: [String: String] = [:]
        do {
            for info in try DesktopSettings.outputs() {
                modes[info.name] = modeLabel(info)
            }
        } catch {
            FileHandle.standardError.write(Data(
                "chooser: no output list from the compositor: \(error)\n".utf8
            ))
            return
        }
        screens = screens.map {
            Screen(line: $0.line, connector: $0.connector,
                   mode: modes[$0.connector] ?? "")
        }
    }

    func move(by delta: Int) {
        guard !screens.isEmpty else { return }
        selected = min(max(selected + delta, 0), screens.count - 1)
    }

    func commit() {
        guard screens.indices.contains(selected) else { answer(nil) }
        answer(screens[selected])
    }
}

nonisolated(unsafe) let model = ChooserModel(screens: readScreens())

/// Escape declines, which for this protocol means exiting with nothing
/// written — not an error code. Enter and the arrows are the keyboard half of
/// the same choice a click makes.
func handleKey(_ event: LavaUI.InputEvent) -> Bool {
    guard event.kind == .key, KeyAction.isDown(event.keyAction) else {
        return false
    }
    switch event.keyCode {
    case KeyCode.escape:
        answer(nil)
    case KeyCode.enter:
        model.commit()
        return true
    case KeyCode.up, KeyCode.left:
        model.move(by: -1)
        return true
    case KeyCode.down, KeyCode.right:
        model.move(by: 1)
        return true
    case KeyCode.tab:
        model.move(by: KeyMods.contains(event.keyMods, KeyMods.shift) ? -1 : 1)
        return true
    default:
        return false
    }
}

private enum Layout {
    static let width: Float = 420
    static let rowHeight: Float = 56
    static let inset: Float = 16
    static let radius: Float = 10
}

struct Row: View {
    let index: Int
    let screen: Screen

    var body: some View {
        let theme = Theme.current
        let isSelected = model.selected == index
        let fill = isSelected
            ? theme.selectionFill
            : (model.hovered == index ? theme.hover : theme.inset)

        return HStack(
            height: .pt(Layout.rowHeight),
            padding: 12,
            alignment: .center,
            spacing: 10,
            onClick: { model.selected = index; model.commit() },
            onHover: { inside in model.hovered = inside ? index : -1 }
        ) {
            VStack(flexGrow: 1, padding: 0, spacing: 2) {
                Text(screen.connector, color: theme.textPrimary)
                if !screen.mode.isEmpty {
                    Text(screen.mode, color: theme.textSecondary)
                }
            }
            if isSelected {
                Text("Share", color: theme.accent)
            }
        }
        .background(fill)
        .cornerRadius(Layout.radius)
    }
}

struct ChooserView: View {
    var body: some View {
        let theme = Theme.current
        return VStack(
            flexGrow: 1, padding: Layout.inset, spacing: 10
        ) {
            Text("Share which screen?", color: theme.textPrimary)
            // A share with nothing to share: say so rather than showing an
            // empty box the user has to guess about.
            if model.screens.isEmpty {
                Text("No screen is available to share.", color: theme.textSecondary)
            }
            ForEach(Array(model.screens.enumerated()), id: \.offset) { pair in
                Row(index: pair.offset, screen: pair.element)
            }
            Spacer()
            Text("Escape cancels the share.", color: theme.textMuted)
        }
        .background(theme.background)
    }
}

// ─── Bring-up ───────────────────────────────────────────────────────────────

// Tall enough for the rows it actually has, so a single-monitor desk gets a
// small dialog rather than a mostly empty one.
let height = Layout.inset * 2 + 60
    + Float(max(model.screens.count, 1)) * (Layout.rowHeight + 10)

guard let editor = LavaClient.open(
    title: "Share which screen?",
    width: Layout.width,
    height: height,
    frame: .server
) else {
    // No compositor, no picker. Exiting without writing the answer file is
    // "declined", which is the safe reading: better a share the user has to
    // start again than one aimed at a screen nobody chose.
    FileHandle.standardError.write(Data("chooser: cannot open a window\n".utf8))
    exit(1)
}

// After `open`, which is what brings the control plane up, and before the
// first frame — so the rows come up with their resolutions rather than
// growing them a frame later.
model.loadModes()

LavaClient.run(editor: editor, onRawKey: handleKey) { ChooserView() }
