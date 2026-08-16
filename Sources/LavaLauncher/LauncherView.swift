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
}

struct LauncherView: View {
    var body: some View {
        // Three layers, outside in: an undimmed desktop ring, the card panel,
        // and the search pill floating over it.
        //
        // The ring is the window's own inset — `WindowBackdrop.none` means the
        // surface is clear, so whatever the padding does not cover is desktop.
        // The panel is opaque enough to read a wall of icons and labels
        // against, which is the one thing it is for: it cannot frost the
        // desktop behind it (see below), so what legibility it has, it has to
        // paint.
        let scrim = Theme.current.background.opacity(0.80)

        VStack(flexGrow: 1, padding: Grid.screenInset) {
            VStack(flexGrow: 1, padding: 0) {
                ScrollView {
                    VStack(padding: Grid.padding, spacing: 12) {
                        // Keeps the first row clear of the floating search;
                        // when the user scrolls, cards pass under the pill.
                        HStack(height: .pt(Grid.searchClearance), padding: 0) {}
                        Ruler()
                        Results()
                    }
                }
                .flexGrow(1)
            }
            .background(scrim)
            .cornerRadius(Grid.panelRadius)
            // On the panel, not on the padded box around it, so the gap is
            // measured from the panel's own edge — anchored outside, the pill
            // floats in the desktop ring and straddles the border.
            //
            // The style hugs the pill rather than a row containing it: this
            // panel *is* the glass, so it has to be exactly the shape of the
            // thing being frosted. `padding: 0` keeps it to the pill's own
            // 480×50, and the radius is half the height, which is what rounds
            // the ends into a capsule rather than merely softening them.
            .overlay(
                alignment: .top,
                inset: Grid.searchGap,
                style: OverlayStyle(
                    background: Theme.current.panel.opacity(0.55),
                    border: Theme.current.accent.opacity(0.35),
                    cornerRadius: Grid.searchHeight * 0.5,
                    padding: 0,
                    backdropBlurRadius: 12
                )
            ) {
                SearchField()
            }
        }
    }
}

/// The search box, focused from the first frame.
///
/// Focused because that is the entire interaction: the window opens and you
/// type. A launcher that needed a click in the box first would be asking the
/// user to aim at something before saying what they want.
///
/// The pill and nothing else.
///
/// No surrounding row: the panel drawn by `overlay(alignment:style:)` is sized
/// to whatever this returns, and a full-width row would make the glass the
/// full width of the screen. Centring is the overlay anchor's job, not a pair
/// of `Spacer`s here — which is the same reason there is no plate: this view
/// is the *contents* of a surface, not a surface.
private struct SearchField: View {
    var body: some View {
        HStack(
            width: .pt(Grid.searchWidth), height: .pt(Grid.searchHeight),
            padding: 12, alignment: .center, spacing: 8
        ) {
            Magnifier(
                color: Theme.current.textSecondary, surface: Theme.current.inset
            )
            TextField(
                text: Binding(model, \.query),
                placeholder: "What do you want to launch?",
                autoFocus: true,
                focusRing: FocusRingStyle.none,
                onSubmit: { model.launchSelected() }
            )
            .flexGrow(1)
            .frame(height: .pct(100))
            // The field's own surface would be a second plate inside the
            // glass, and there is only one surface here.
            .background(.clear)
        }
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
            }
        )
    }
}

/// The wall of applications (inside the outer scroll — no nested ScrollView).
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
            // Centred: the cards are the only thing on the screen, so the
            // width left over after the last whole column belongs on both
            // sides of them rather than all down the right.
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

/// One application: its icon, its name, and what kind of thing it is.
private struct AppCard: View {
    let entry: DesktopEntry

    @DrawState private var hovered = false

    var body: some View {
        // Read here so the card re-renders when the selection moves onto or
        // off it; `matches` is stable while the query is.
        let isSelected = model.matches.indices.contains(model.selected)
            && model.matches[model.selected].id == entry.id

        // Percentages, not points: the grid divides the row into `maxColumns`
        // and hands each cell whatever that came to, so a card that stated its
        // own size would sit in the corner of the space it was given.
        return VStack(
            width: .pct(100),
            height: .pct(100),
            padding: 10,
            alignment: .center,
            spacing: 6,
            onClick: { model.launch(entry) },
            onHover: { hovered = $0 }
        ) {
            Spacer()
            Icon(entry: entry)
            Text(entry.name, color: Theme.current.textPrimary, lineLimit: 1)
            if !entry.genericName.isEmpty {
                Text(entry.genericName, color: Theme.current.textDim, lineLimit: 1)
            }
            Spacer()
        }
        .background(
            isSelected ? tint(saturation: 0.75, lightness: 0.24)
                       : tint(saturation: 0.55, lightness: hovered ? 0.16 : 0.10)
        )
        .cornerRadius(14)
    }
}

extension AppCard {
    /// A colour that belongs to this application and no other.
    ///
    /// Hue from the entry id, everything else fixed — which is the whole trick:
    /// vary one axis and a wall of two hundred cards reads as one palette
    /// rather than as two hundred decisions. It also means a card's colour is
    /// stable across launches and across queries, so the eye learns where an
    /// application is by more than its position in a list that keeps changing.
    ///
    /// FNV-1a rather than `hashValue`: Swift's hashing is seeded per process,
    /// so the same application would be a different colour every time the
    /// launcher opened.
    func tint(saturation: Float, lightness: Float) -> Color {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in entry.id.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return Color(
            hue: Float(hash % 3600) / 3600,
            saturation: saturation,
            lightness: lightness
        )
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
            Image(
                path: path,
                width: .pct(Grid.iconFraction * 100),
                height: .pct(Grid.iconFraction * 100),
                decodePixels: 192,
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
