import Foundation
import LavaClient
import LavaIDL
import LavaShell
import LavaUI
import Observation

// The application launcher: everything installed, on shelves by category,
// with a search box.
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
            // Typing searches everything. Someone who has started to spell a
            // name knows what they want, and a match hidden on another shelf
            // would read as "not installed".
            if !query.isEmpty { shelf = nil }
            refresh()
        }
    }
    /// The sidebar's choice; nil is All.
    var shelf: AppCategory? = nil {
        didSet {
            guard shelf != oldValue else { return }
            refresh()
        }
    }
    /// The shelves that have anything on them, in sidebar order, with counts.
    var shelves: [(category: AppCategory, count: Int)] = []
    var matches: [DesktopEntry] = []
    /// Index into `matches`. Enter launches this one.
    var selected = 0

    func load() {
        history = LaunchHistory.load()
        all = DesktopEntry.installed()
        var counts: [AppCategory: Int] = [:]
        for entry in all { counts[entry.category, default: 0] += 1 }
        shelves = AppCategory.allCases.compactMap { category in
            counts[category].map { (category, $0) }
        }
        // Empty query: most-used first, never-used alphabetical underneath.
        refresh()
        // The icon lookup would otherwise read every entry on the machine
        // again the first time something asks for an icon by app id.
        IconLookup.useEntries(all)
    }

    private func refresh() {
        let pool = shelf.map { shelf in all.filter { $0.category == shelf } } ?? all
        matches = DesktopEntry.search(query, in: pool, history: history)
        // A new list, and the old cursor pointed into one that no longer
        // exists. Anywhere but the top would be a selection the user did not
        // make.
        selected = 0
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
    /// The launcher is a panel in the middle of the screen, not the screen.
    ///
    /// It used to fill the work area, which on a 1080p display made every card
    /// 250 points wide to hold a 64-point icon — a wall of empty tiles, read
    /// from across the room. A fixed panel keeps the icons at a size an eye
    /// scans and puts all of them within one short glance of the search box.
    /// It shrinks on a screen smaller than this; it never grows.
    static let panelWidth: Float = 940
    static let panelHeight: Float = 640
    /// The least desktop left around the panel on a small screen.
    static let screenMargin: Float = 24
    static let panelRadius: Float = 16
    static let sidebarWidth: Float = 196
    /// The sidebar card's distance from the panel's edges; its radius is the
    /// panel's less this, so the two curves stay concentric.
    static let sidebarInset: Float = 6

    /// The *smallest* a tile may be, and the proportions every tile keeps.
    /// The grid stretches the columns that fit to the row's width.
    static let cardWidth: Float = 112
    static let cardHeight: Float = 108
    static let maxColumns: Int = 6
    static let spacing: Float = 6
    static let iconSize: Float = 48
    /// Icon edge as a fraction of the tile, so it scales with the cell the
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

    /// The tile grid's own box, for a surface `surface` points wide: the
    /// panel, less the sidebar and the padding either side of the grid.
    static func gridWidth(surface: Float) -> Float {
        let panel = min(panelWidth, surface - screenMargin * 2)
        return max(cardWidth, panel - sidebarWidth - padding * 2)
    }

    /// Card edge for a grid box `width` points wide.
    ///
    /// Repeats `LazyGridNode.laidOutCellWidth` rather than reading it, because
    /// an icon has to choose a decode size at *emit* — before Yoga runs, and
    /// so before the grid knows its own cell. Must agree with it, for the same
    /// reason `columns(width:)` must.
    static func cardEdge(in width: Float) -> Float {
        let cols = Float(columns(width: width))
        return max(1, (width - spacing * (cols - 1)) / cols)
    }

    /// Decode size for an icon in a grid box `width` points wide: what it will
    /// actually be drawn at, rounded up to the next rung.
    static func iconPixels(in width: Float) -> UInt32 {
        let edge = cardEdge(in: width) * iconFraction * FontStore.scale.multiplier
        return iconPixelRungs.first { Float($0) >= edge } ?? iconPixelRungs[iconPixelRungs.count - 1]
    }
    /// Padding around the tile grid, inside the panel.
    static let padding: Float = 14
    /// The floating search pill, and the room the tiles leave above their
    /// first row for it.
    static let searchWidth: Float = 440
    static let searchHeight: Float = 42
    static let searchGap: Float = 12
    static let searchClearance: Float = searchHeight + searchGap * 2 - padding

    /// How many cards fit across a grid box `width` wide. At least one, so a
    /// silly window size cannot divide by zero.
    ///
    /// Must agree with `LazyGridNode.settleWindow`, including the cap — this is
    /// what Up and Down move by, and a key handler that disagrees with the
    /// layout about the row length moves the selection somewhere the user did
    /// not point at. `width` is the grid's own box (the ruler's), so nothing
    /// comes off it here.
    static func columns(width: Float) -> Int {
        let fit = max(1, Int((width + spacing) / (cardWidth + spacing)))
        return min(maxColumns, fit)
    }
}

// ─── Bring-up ───────────────────────────────────────────────────────────────

// The surface covers the work area so a click beside the panel can dismiss
// it; it paints only a light dim, and the panel paints itself.
WindowBackdrop.current = .none

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
// One at a time — the key pressed twice brings the first one back — above
// everything, and not a window anyone can drag off the work area it covers.
guard let editor = LavaClient.open(
    title: "Launcher", frame: .client, fillScreen: .maximized,
    options: [.singleInstance, .alwaysOnTop, .fixedFrame]
) else { exit(1) }
BootTrace.mark("compositor connected")

// After `open`: a face is registered with the compositor, which only now
// exists to register it with.
LauncherLayout.smallFont = UIFont.loadUI(assetsRoot: LavaResources.root, pixelSize: 13)

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
