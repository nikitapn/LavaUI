import Foundation
import LavaClient
import LavaShell
import LavaUI

/// Everything that is not a click: Escape, Enter, and the arrows.
///
/// Handled raw rather than through the search field, because they belong to
/// the *grid* while the caret is in the box. That is the arrangement every
/// launcher has — you type without aiming, and the arrows move a selection
/// somewhere else on the screen. Returning true consumes the key, which is
/// what stops Down from putting a character in the field.
func handleKey(_ event: LavaUI.InputEvent) -> Bool {
    guard event.kind == .key, event.keyAction != KeyAction.release else {
        return false
    }

    switch event.keyCode {
    case KeyCode.escape:
        // Dismissed. A launcher is a question, and this is declining to answer.
        // `LavaClient.quit`, not bare `exit`: that tears the surface down so
        // the window does not linger for NPRPC's peer-death poll (Mod+Q is
        // instant because the compositor closes the surface itself).
        LavaClient.quit()
    case KeyCode.enter:
        model.launchSelected()
        return true
    case KeyCode.left:
        model.move(by: -1)
        return true
    case KeyCode.right:
        model.move(by: 1)
        return true
    case KeyCode.up:
        model.move(by: -LauncherLayout.columns)
        return true
    case KeyCode.down:
        model.move(by: LauncherLayout.columns)
        return true
    case KeyCode.tab:
        model.move(by: KeyMods.contains(event.keyMods, KeyMods.shift) ? -1 : 1)
        return true
    default:
        return false
    }
}

/// How many cards are across, as of the last frame.
///
/// Up and Down mean "one row", and a row is only as long as the window is
/// wide — which the key handler cannot know and the layout can. Written by the
/// ruler below, read by the handler; both run on the frame loop, so one
/// variable is the whole of the synchronisation.
enum LauncherLayout {
    nonisolated(unsafe) static var columns: Int = 1

    /// Physical pixels to decode an app icon at, for the width the grid
    /// actually got. Seeded from the screen in `main` before the first emit,
    /// then kept honest by the ruler if the surface turns out different.
    nonisolated(unsafe) static var iconPixels: UInt32 = 192

    /// Tile names, counts, the sidebar's caption. Loaded in `main` once the
    /// compositor is there to register it with; nil falls back to the
    /// default face.
    nonisolated(unsafe) static var smallFont: UIFont?
}

struct LauncherView: View {
    var body: some View {
        // A panel in the middle of a lightly dimmed desktop. The dim says the
        // launcher has the keyboard; light, because the desktop is still the
        // thing being launched into and nothing about it needs hiding.
        //
        // Centred with spacers rather than a fixed frame on the surface, so
        // the panel gives way on a screen smaller than it is: its width is on
        // the row's main axis and its height on the column's, and both shrink.
        VStack(
            flexGrow: 1, padding: Grid.screenMargin, spacing: 0,
            // Beside the panel is "not this": the same as Escape.
            onClick: { LavaClient.quit() }
        ) {
            Spacer()
            HStack(padding: 0, spacing: 0) {
                Spacer()
                LauncherPanel().flexShrink(1)
                Spacer()
            }
            .frame(height: .pt(Grid.panelHeight))
            .flexShrink(1)
            Spacer()
        }
        .background(Color(r: 0, g: 0, b: 0, a: 0.22))
    }
}

/// The launcher proper: shelves on the left, the search and the tiles on the
/// right.
///
/// Opaque. It used to be frosted glass over a full-screen scrim, and a wall
/// of coloured icons and labels over a blurred wallpaper is three layers of
/// noise competing for the same eye; a plain surface lets the icons be the
/// only colour on it.
private struct LauncherPanel: View {
    var body: some View {
        // The size on the stack itself, not in a `.frame` after the styling:
        // that lands on a wrapper, and the stack inside it grows to the height
        // of every tile instead of scrolling them.
        //
        // A click here must not fall through to the dismissing backdrop.
        HStack(
            width: .pt(Grid.panelWidth), height: .pct(100),
            padding: 0, spacing: 0, onClick: {}
        ) {
            // Inset rather than flush: a fill reaching the panel's edge would
            // need the panel's corner on two of its corners and not the other
            // two, and a background cannot be rounded per corner — nor does
            // `cornerRadius` clip what is inside it. A card of its own, a few
            // points in, has four corners the same and keeps the lighter tone
            // that tells the shelves from the tiles without a rule between.
            HStack(padding: Grid.sidebarInset, spacing: 0) {
                Shelves()
            }
            // The pill covers the top of the view: a selection moved there by
            // the arrows belongs below it, and the first row's belongs at the
            // very top — where it started — not tucked under the field.
            ScrollView(
                indicatorInset: Grid.panelRadius,
                revealInset: Grid.padding + Grid.searchClearance
            ) {
                VStack(padding: Grid.padding, spacing: 0) {
                    // Keeps the first row clear of the floating search; when
                    // the user scrolls, the tiles pass under the pill and it
                    // enlarges them.
                    HStack(height: .pt(Grid.searchClearance), padding: 0) {}
                    Ruler()
                    Results()
                }
            }
            .flexGrow(1)
            // On the scroll view, not the panel: anchored there it would
            // centre over the sidebar and the tiles together, off the axis of
            // the grid it floats over. `style: nil` because the field is its
            // own glass — a plate around it would be a pane behind the pane.
            //
            // The composed overlay is what makes the lens work at all. It is
            // emitted after the scroll view, so the tiles are already in the
            // framebuffer when the field's backdrop captures them.
            .overlay(alignment: .top, inset: Grid.searchGap, style: nil) {
                SearchField()
            }
        }
        .background(Theme.current.background)
        .border(Theme.current.border)
        .cornerRadius(Grid.panelRadius)
    }
}

/// The categories, each with how many applications it holds.
///
/// Counts because they answer the question the sidebar raises — "is it worth
/// looking in Education?" — before the click rather than after it.
private struct Shelves: View {
    var body: some View {
        // While a search is typed it spans every shelf, and the sidebar says
        // so by having All selected (`LauncherModel.query`).
        let current = model.shelf
        // `.frame(width:)`, not `VStack(width:)`: a column that states its
        // own width is painted `theme.panel` by `StackNode`, square-cornered,
        // whatever the radius around it says.
        return VStack(padding: 10, spacing: 2) {
            Text("Applications", color: Theme.current.textDim,
                 font: LauncherLayout.smallFont)
                .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            ShelfRow(title: "All", count: model.all.count,
                     selected: current == nil) { model.shelf = nil }
            ForEach(model.shelves, id: \.category) { shelf in
                ShelfRow(title: shelf.category.title, count: shelf.count,
                         selected: current == shelf.category) {
                    model.shelf = shelf.category
                }
            }
            Spacer()
        }
        .frame(width: .pt(Grid.sidebarWidth - Grid.sidebarInset * 2))
        .background(Theme.current.panel)
        .cornerRadius(Grid.panelRadius - Grid.sidebarInset)
    }
}

private struct ShelfRow: View {
    let title: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        HStack(padding: 0, alignment: .center, spacing: 8, onClick: action) {
            Text(title, color: selected ? Theme.current.textPrimary
                                        : Theme.current.textSecondary)
            Spacer()
            Text("\(count)", color: selected ? Theme.current.textSecondary
                                              : Theme.current.textDim,
                 font: LauncherLayout.smallFont)
        }
        .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
        // `selectionFill`, not `selected`: see `SidebarRow` in LavaSettings.
        .background(selected ? Theme.current.selectionFill : .clear)
        .hoverBackground(selected ? Theme.current.selectionFill : Theme.current.hover)
        .cornerRadius(8)
    }
}

/// The search box, focused from the first frame.
///
/// Focused because that is the entire interaction: the window opens and you
/// type. A launcher that needed a click in the box first would be asking the
/// user to aim at something before saying what they want.
private struct SearchField: View {
    var body: some View {
        HStack(
            width: .pt(Grid.searchWidth), height: .pt(Grid.searchHeight),
            padding: 12, alignment: .center, spacing: 6
        ) {
            Magnifier(
                color: Theme.current.textDim, surface: Theme.current.inset
            )
            TextField(
                text: Binding(model, \.query),
                placeholder: "Search applications",
                autoFocus: true,
                focusRing: FocusRingStyle.none,
                onSubmit: { model.launchSelected() }
            )
            .flexGrow(1)
            .frame(height: .pct(100))
            // The box is the field's surface; a second one inside it would
            // be a plate on a plate.
            .background(.clear)
        }
        // A lens over the tiles: sharp, no blur — what is under a magnifier
        // is meant to be read — with a tint just deep enough to keep the
        // placeholder and the typed query legible over a coloured icon.
        .background(Theme.current.inset.opacity(0.55))
        .border(Theme.current.border)
        .cornerRadius(Grid.searchHeight * 0.5)
        .glassEffect(refraction: 10, rim: 0.8, magnification: 1.35)
    }
}

/// Drawn rather than borrowed from a font: the mark stays circular and crisp
/// at every content scale, independent of which symbol glyphs are installed.
private struct Magnifier: View {
    let color: Color
    let surface: Color

    var body: some View {
        Canvas(
            label: "Search icon", width: .pt(24), height: .pt(24),
            paint: { draw, frame in
                let cx = frame.x + 10
                let cy = frame.y + 10
                draw.circle(cx: cx, cy: cy, radius: 7.5, color: color)
                draw.circle(cx: cx, cy: cy, radius: 5.5, color: surface)
                draw.line(
                    x1: cx + 5, y1: cy + 5,
                    x2: frame.x + 21, y2: frame.y + 21,
                    color: color, width: 2
                )
            }
        )
    }
}

/// A view that draws nothing and measures the row.
///
/// Zero height, full width, and its paint records how many cards fit across.
/// It exists because the arrow keys need a number that only layout knows, and
/// the alternative — the launcher guessing from a surface size it is never
/// told — is the bug where Down moves by the wrong amount on every screen but
/// the developer's.
private struct Ruler: View {
    var body: some View {
        Canvas(
            label: "Ruler",
            width: .pct(100),
            height: .pt(0),
            paint: { _, frame in
                LauncherLayout.columns = Grid.columns(width: frame.w)
                // The ruler *is* the grid box, so this needs no inset maths —
                // unlike the seed in `main`, which starts from the screen.
                LauncherLayout.iconPixels = Grid.iconPixels(in: frame.w)
            }
        )
    }
}

/// The tiles (inside the panel's scroll — no nested ScrollView).
private struct Results: View {
    @ViewBuilder
    var body: some View {
        let entries = model.matches
        if entries.isEmpty {
            VStack(padding: 40, alignment: .center, spacing: 8) {
                Text("Nothing matches “\(model.query)”.",
                     color: Theme.current.textDim)
            }
        } else {
            // Centred: the width left over after the last whole column
            // belongs on both sides rather than all down the right.
            LazyVGrid(
                entries,
                cellWidth: Grid.cardWidth,
                cellHeight: Grid.cardHeight,
                spacing: Grid.spacing,
                maxColumns: Grid.maxColumns,
                alignment: .center,
                scrollTarget: model.selected
            ) { entry in
                AppCard(entry: entry)
            }
        }
    }
}

/// One application: its icon and its name.
///
/// No fill of its own. A tile per application, each a different colour, made
/// a screen of two hundred shapes before it made one of two hundred icons —
/// and the icons already are the colour. Only the selection and the pointer
/// put a plate behind one.
private struct AppCard: View {
    let entry: DesktopEntry

    var body: some View {
        // Read here so the card re-renders when the selection moves onto or
        // off it; `matches` is stable while the query is.
        let isSelected = model.matches.indices.contains(model.selected)
            && model.matches[model.selected].id == entry.id

        // Percentages, not points: the grid hands each cell whatever its share
        // of the row came to, and a card that stated its own size would sit in
        // the corner of the space it was given.
        return VStack(
            width: .pct(100),
            height: .pct(100),
            padding: 8,
            alignment: .center,
            spacing: 8,
            onClick: { model.launch(entry) }
        ) {
            Spacer()
            Icon(entry: entry)
            // The full width, centred inside it, so a long name is cut to
            // the tile rather than spilling over its neighbours.
            Text(entry.name, color: Theme.current.textPrimary,
                 font: LauncherLayout.smallFont, lineLimit: 1, align: .top)
                .frame(width: .pct(100))
            Spacer()
        }
        // A wash of the accent rather than `selectionFill`, which is a list
        // row's highlight and a slab of solid blue at this size.
        .background(isSelected ? Theme.current.accent.opacity(0.24) : .clear)
        // The renderer's tint; a hover equal to the fill leaves the selected
        // tile as it is.
        .hoverBackground(isSelected ? Theme.current.accent.opacity(0.24) : Theme.current.hover)
        .cornerRadius(12)
    }
}

/// The icon, or the application's initial when there is none to find.
private struct Icon: View {
    let entry: DesktopEntry

    @ViewBuilder
    var body: some View {
        // An absolute path in `Icon=` is used as given; a name goes through
        // the theme search. Both end as a file for the renderer to decode, and
        // `Image(path:)` resolves it at emit — so a screen of two hundred
        // icons costs two hundred decodes spread over the frames that show
        // them, not one stall before the first one.
        if let path = iconPath() {
            // A fraction of the card rather than a fixed 64pt, so the icon
            // grows with the cell the grid hands out. `decodePixels` has to be
            // said out loud once the box is a percentage: the cap is normally
            // derived from a definite size, and without one the file decodes
            // at whatever resolution it shipped at — which for a 512px icon
            // means it no longer fits an atlas cell and costs a texture
            // binding of its own. See `Image.decodePixels` and `ImageAtlas`.
            //
            // It was a flat 192, which is what a 4K screen wants and roughly
            // 3.3x the pixels a 1080p one draws — 106px there. Oversampling an
            // atlased image is not free twice over: the decode is larger, and
            // the pages carry no mips, so what is left is minified by the
            // bilinear filter alone.
            Image(
                path: path,
                width: .pct(Grid.iconFraction * 100),
                height: .pct(Grid.iconFraction * 100),
                decodePixels: LauncherLayout.iconPixels,
                contentMode: .fit
            )
        } else {
            Text(String(entry.name.prefix(1)).uppercased(),
                 color: Theme.current.textSecondary)
                .frame(
                    width: .pct(Grid.iconFraction * 100),
                    height: .pct(Grid.iconFraction * 100)
                )
        }
    }

    /// The entry's own `Icon=` first, then its id, then a sibling that
    /// launches the same binary — see `IconLookup.themePath(forEntry:)`.
    private func iconPath() -> String? {
        IconLookup.themePath(forEntry: entry)
    }
}
