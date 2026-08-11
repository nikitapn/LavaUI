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
        VStack(flexGrow: 1, padding: Grid.padding, spacing: 12) {
            SearchField()
            Ruler()
            Results()
        }
    }
}

/// The search box, focused from the first frame.
///
/// Focused because that is the entire interaction: the window opens and you
/// type. A launcher that needed a click in the box first would be asking the
/// user to aim at something before saying what they want.
private struct SearchField: View {
    var body: some View {
        let surface = Theme.current.inset
        let outline = Theme.current.textSecondary.opacity(0.78)

        // The full-width row centres the bounded field on the same axis as
        // LazyVGrid. Two nested fills make a crisp rounded outline without a
        // separate stroke primitive.
        HStack(width: .pct(100), alignment: .center) {
            Spacer()
            HStack(
                width: .pt(Grid.searchWidth), height: .pt(50), padding: 2,
                alignment: .center
            ) {
                HStack(
                    flexGrow: 1, height: .pt(46), padding: 10,
                    alignment: .center, spacing: 8
                ) {
                    Magnifier(color: Theme.current.textSecondary, surface: surface)
                    TextField(
                        text: Binding(model, \.query),
                        placeholder: "What do you want to launch?",
                        autoFocus: true,
                        focusRing: FocusRingStyle.none,
                        onSubmit: { model.launchSelected() }
                    )
                    .flexGrow(1)
                    .frame(height: .pct(100))
                }
                .background(surface)
                .cornerRadius(23)
            }
            .background(outline)
            .cornerRadius(25)
            Spacer()
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

/// The wall of applications.
private struct Results: View {
    @ViewBuilder
    var body: some View {
        let entries = model.matches
        if entries.isEmpty {
            VStack(flexGrow: 1, padding: 40, alignment: .center, spacing: 8) {
                Text("Nothing matches “\(model.query)”.",
                     color: Theme.current.textDim)
                Spacer()
            }
        } else {
            ScrollView {
                // Centred: the cards are the only thing on the screen, so the
                // width left over after the last whole column belongs on both
                // sides of them rather than all down the right.
                LazyVGrid(
                    entries,
                    cellWidth: Grid.cardWidth,
                    cellHeight: Grid.cardHeight,
                    spacing: Grid.spacing,
                    alignment: .center,
                    scrollTarget: model.selected
                ) { entry in
                    AppCard(entry: entry)
                }
            }
            .flexGrow(1)
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

        return VStack(
            width: .pt(Grid.cardWidth),
            height: .pt(Grid.cardHeight),
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
            isSelected ? Theme.current.selectionFill
                       : (hovered ? Theme.current.hover : Theme.current.panel)
        )
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
            Image(
                path: path,
                width: .pt(Grid.iconSize),
                height: .pt(Grid.iconSize),
                contentMode: .fit
            )
        } else {
            Text(String(entry.name.prefix(1)).uppercased(),
                 color: Theme.current.textSecondary)
                .frame(width: .pt(Grid.iconSize), height: .pt(Grid.iconSize))
        }
    }

    /// The entry's own `Icon=` first, since that is what it says it wants; the
    /// id second, for the entries that name no icon and ship one anyway.
    ///
    /// Both go through `themePath(forIconName:)` rather than
    /// `iconPath(forAppId:)`. The app-id lookup exists for a caller holding a
    /// window, and starts by reading every desktop entry on the machine to
    /// find the one whose `Icon=` line this code is already looking at.
    private func iconPath() -> String? {
        IconLookup.themePath(forIconName: entry.icon)
            ?? IconLookup.themePath(forIconName: entry.id)
    }
}
