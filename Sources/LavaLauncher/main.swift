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
// come from" turns out to have a longer answer than it looks. Empty-query
// order is by launch frequency (`LaunchHistory`, rofi's druncache idea);
// typing still ranks by match score, with history as the tiebreaker.
//
// It closes as soon as it has done something: launched an application, or been
// dismissed with Escape. A launcher that stayed open after launching would be
// a window between the user and the thing they just asked for.

@Observable
final class LauncherModel {
    /// Everything installed, read once at startup.
    var all: [DesktopEntry] = []
    /// How often each app has been launched — what puts frequent apps first,
    /// the way rofi's druncache does.
    var history = LaunchHistory()
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            matches = DesktopEntry.search(query, in: all, history: history)
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
        history = LaunchHistory.load()
        all = DesktopEntry.installed()
        // Empty query: most-used first, never-used alphabetical underneath.
        matches = DesktopEntry.search("", in: all, history: history)
        // The icon lookup would otherwise read every entry on the machine
        // again the first time something asks for an icon by app id.
        IconLookup.useEntries(all)
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
        // Count before quit: once the surface tears down this process is on
        // its way out, and a write after that is a race against exit.
        history.record(entry.id)
        history.save()
        // Quit through the client so the surface is destroyed before we die —
        // bare `exit` left the fullscreen dimmer up for ~half a second.
        if entry.launch() { LavaClient.quit() }
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
    /// The *smallest* a card may be, and the proportions every card keeps.
    ///
    /// Not the size it is drawn at: `maxColumns` makes the grid divide the row
    /// into exactly this many cards, so the width follows the display and the
    /// height follows the width. A fixed card on a 4K screen leaves a gutter
    /// the size of another column; seven bigger cards use the space it was
    /// given.
    static let cardWidth: Float = 152
    static let cardHeight: Float = 148
    /// Never more than this many across, however wide the screen is. A wall of
    /// applications is read by scanning rows, and a row of fourteen is not
    /// scanned, it is searched.
    static let maxColumns: Int = 7
    static let spacing: Float = 10
    static let iconSize: Float = 64
    /// Icon edge as a fraction of the card, so it scales with the cell the
    /// grid hands out. Matches `iconSize / cardWidth` at the minimum size.
    static let iconFraction: Float = iconSize / cardWidth

    /// Sizes an app icon may be decoded at, in physical pixels.
    ///
    /// A ladder rather than the exact drawn size, for two reasons. The value
    /// is part of the decode cache key (`path@N`), so a card that resolves one
    /// pixel wider between frames would otherwise decode every icon on the
    /// machine a second time and hold both copies. And these are `ImageAtlas`
    /// cell sizes, so an icon fills the cell it lands in rather than sitting
    /// in the corner of a larger one — atlas pages have no mip chain, and an
    /// icon decoded far above its drawn size is minified with bilinear alone.
    static let iconPixelRungs: [UInt32] = [64, 128, 192, 256]

    /// The card grid's own box, for a surface `surface` points wide: the
    /// screen inset and the panel padding come off both sides.
    static func gridWidth(surface: Float) -> Float {
        max(cardWidth, surface - (screenInset + padding) * 2)
    }

    /// Card edge for a grid box `width` points wide.
    ///
    /// Repeats `LazyGridNode.laidOutCellWidth` rather than reading it, because
    /// an icon has to choose a decode size at *emit* — before Yoga runs, and
    /// so before the grid knows its own cell. Must agree with it, for the same
    /// reason `columns(width:)` must.
    static func cardEdge(in width: Float) -> Float {
        let fit = max(1, Int((width + spacing) / (cardWidth + spacing)))
        let cols = Float(min(maxColumns, fit))
        return max(1, (width - spacing * (cols - 1)) / cols)
    }

    /// Decode size for an icon in a grid box `width` points wide: what it will
    /// actually be drawn at, rounded up to the next rung. 1080p lands on 128,
    /// 1440p on 192, 4K on 256.
    static func iconPixels(in width: Float) -> UInt32 {
        let edge = cardEdge(in: width) * iconFraction * FontStore.scale.multiplier
        return iconPixelRungs.first { Float($0) >= edge } ?? iconPixelRungs[iconPixelRungs.count - 1]
    }
    /// Inset from the screen edge — the gap that leaves the desktop visible
    /// around the launcher instead of a hard full-bleed dim.
    static let screenInset: Float = 36
    /// Side padding inside the content area (around the card grid).
    static let padding: Float = 16
    /// Height reserved under the floating search so the first row of cards
    /// starts clear of it; scrolling still draws cards through the transparent
    /// header.
    static let searchClearance: Float = 72
    /// A deliberate reading width rather than the full screen. The app grid
    /// is centred below it, so the two controls share one visual axis even on
    /// an ultrawide display.
    static let searchWidth: Float = 480
    /// Pill height. Its corner radius is half of this, which is what rounds
    /// the ends into a capsule instead of merely softening them.
    static let searchHeight: Float = 50
    /// Gap between the top of the card panel and the pill floating over it.
    static let searchGap: Float = 14
    /// Corner radius of the card panel.
    static let panelRadius: Float = 18

    /// How many cards fit across a surface `width` wide. At least one, so a
    /// silly window size cannot divide by zero.
    ///
    /// Must agree with `LazyGridNode.settleWindow`, including the cap — this is
    /// what Up and Down move by, and a key handler that disagrees with the
    /// layout about the row length moves the selection somewhere the user did
    /// not point at.
    static func columns(width: Float) -> Int {
        let usable = max(cardWidth, width - padding * 2)
        let fit = max(1, Int((usable + spacing) / (cardWidth + spacing)))
        return min(maxColumns, fit)
    }
}

// ─── Bring-up ───────────────────────────────────────────────────────────────

// Window itself is clear so the *edge gaps* show the desktop undimmed. The
// floating content card paints its own translucent scrim (see LauncherView) —
// a full-surface backdrop would fill the margins too and kill the gap.
WindowBackdrop.current = .none

// Indigo rather than the editor greys. A launcher is nearly all surface, and a
// neutral panel over somebody's wallpaper reads as a smudge on it. See
// `Theme.nebula`.
Theme.current = .nebula

// `LAVA_BOOT_TRACE=1` says where the time before the first frame went. This is
// the client that most needs it: everything else opens a window and draws,
// while a launcher first has to find out what is installed on the machine.
BootTrace.mark("main")

model.load()
BootTrace.mark("desktop entries read (\(model.all.count))")

// Full-screen: the compositor is asked how big its screens are and clamps this
// to the work area, sending the real size back as the opening resize. Asking
// for something deliberately bigger than any screen would do as well for the
// *request* and lays the grid out at 4K first — which materialises every card
// on the machine, and looks up every icon, before the window turns out to be a
// quarter of that. `.client` because a launcher with a title bar is a dialog.
guard let editor = LavaClient.open(
    title: "Launcher", frame: .client, fillScreen: true
) else { exit(1) }
BootTrace.mark("compositor connected")

// Seeded here rather than left to the ruler, which only runs at paint and so
// would be a frame late. A frame late is not a cosmetic problem: the decode
// size is part of the cache key, so a first frame at the wrong rung decodes
// every visible icon twice and holds both. `requestedSize` is the screen after
// `fillScreen`, which is what the surface is about to be.
LauncherLayout.iconPixels = Grid.iconPixels(
    in: Grid.gridWidth(surface: LavaClient.requestedSize.width)
)

// Drained right after the first present, so this runs with a frame genuinely
// on screen rather than merely built.
FrameTasks.after {
    BootTrace.mark("first frame presented")
    BootTrace.report()
}

LavaClient.run(editor: editor, onRawKey: handleKey) { LauncherView() }
