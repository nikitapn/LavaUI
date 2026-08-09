import Foundation
import LavaClient
import LavaIDL
import LavaShell
import LavaUI
import Observation

// The application launcher: everything installed, as a wall of icons, with a
// search box.
//
//   Alt+P, or: swift run LavaLauncher
//
// Spawned per invocation rather than kept running, which is what rofi does and
// what the numbers allow — a LavaUI client reaches its first frame in about
// 200 ms, and the alternative is a resident process holding an arena and a
// surface for the ninety-nine per cent of the time nobody is launching
// anything.
//
// The list comes from freedesktop desktop entries; `LavaShell.DesktopEntry`
// is where that is explained, because "where does the list of applications
// come from" turns out to have a longer answer than it looks.
//
// It closes as soon as it has done something: launched an application, or been
// dismissed with Escape. A launcher that stayed open after launching would be
// a window between the user and the thing they just asked for.

@Observable
final class LauncherModel {
    /// Everything installed, read once at startup.
    var all: [DesktopEntry] = []
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            matches = DesktopEntry.search(query, in: all)
            // A new search is a new list, and the old cursor pointed into a
            // list that no longer exists. Anywhere but the top would be a
            // selection the user did not make.
            selected = 0
        }
    }
    var matches: [DesktopEntry] = []
    /// Index into `matches`. Enter launches this one.
    var selected = 0

    func load() {
        all = DesktopEntry.installed()
        matches = all
    }

    /// Runs the selection and ends the process. Nothing after this returns.
    func launchSelected() {
        guard matches.indices.contains(selected) else { return }
        launch(matches[selected])
    }

    func launch(_ entry: DesktopEntry) {
        // Said before it happens: a launcher that dies without a word when the
        // Exec line is broken is indistinguishable from one that ignored the
        // click.
        FileHandle.standardError.write(Data("launching \(entry.id)\n".utf8))
        if entry.launch() { exit(0) }
    }

    /// Moves the cursor by `columns` per row, clamped rather than wrapped:
    /// running off the end of a grid and reappearing at the start is a
    /// surprise, not a convenience.
    func move(by delta: Int) {
        guard !matches.isEmpty else { return }
        selected = min(max(0, selected + delta), matches.count - 1)
    }
}

nonisolated(unsafe) let model = LauncherModel()

/// The grid's geometry, in one place so the card and the arrow keys agree
/// about what "one row down" means.
enum Grid {
    static let cardWidth: Float = 152
    static let cardHeight: Float = 148
    static let spacing: Float = 10
    static let iconSize: Float = 64
    /// Side padding around the grid, which the column count is measured after.
    static let padding: Float = 16

    /// How many cards fit across a surface `width` wide. At least one, so a
    /// silly window size cannot divide by zero.
    static func columns(width: Float) -> Int {
        let usable = max(cardWidth, width - padding * 2)
        return max(1, Int((usable + spacing) / (cardWidth + spacing)))
    }
}

// ─── Bring-up ───────────────────────────────────────────────────────────────

// Translucent, and the reason this is a whole-screen window rather than a
// small centred one: what is behind it stays visible and dimmed, so launching
// something reads as a layer over the desktop rather than a context switch.
WindowBackdrop.current = .color(Color(r: 0.06, g: 0.07, b: 0.09, a: 0.86))

model.load()

// Full-screen by asking for something bigger than any screen: the compositor
// clamps to the work area and sends the real size back as the opening resize.
// `.client` because a launcher with a title bar would be a dialog.
guard let editor = LavaClient.open(
    title: "Launcher", width: 3840, height: 2160, frame: .client
) else { exit(1) }

LavaClient.run(editor: editor, onRawKey: handleKey) { LauncherView() }
