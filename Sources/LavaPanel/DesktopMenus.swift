import Foundation
import LavaExplorerCore
import LavaIDL
import LavaMenu
import LavaUI

/// What the menu bar says when nothing has focus.
///
/// macOS fills the empty bar with Finder's menus because Finder never quits.
/// The explorer here is quick to start and has no business staying resident,
/// so the panel — which is resident anyway, and draws its menus through the
/// compositor for nothing — offers the parts of a desktop's menus that need
/// no application behind them: places to open, workspaces to switch to, the
/// shortcuts the compositor takes. Each launches or asks for something;
/// nothing here keeps state of its own beyond what the compositor reports.
enum DesktopMenus {
    static let desktop = MenuID("desktop.app")
    static let showDesktop = MenuID("desktop.app.show")
    static let background = MenuID("desktop.app.background")
    static let displays = MenuID("desktop.app.displays")
    static let go = MenuID("desktop.go")
    static let workspaces = MenuID("desktop.workspaces")
    static let help = MenuID("desktop.help")
    static let shortcuts = MenuID("desktop.help.shortcuts")

    /// A place in Go, by what LavaExplorer is handed.
    static let goPrefix = "desktop.go:"
    /// A workspace, from 0.
    static let workspacePrefix = "desktop.workspace:"

    /// What the compositor last said about workspaces: which is on screen,
    /// and how many windows each has.
    struct Workspaces: Equatable {
        var current: UInt32 = 0
        var windows: [Int] = Array(repeating: 0, count: count)

        static let count = 9
    }

    /// The menus of an empty bar.
    static func menus(workspaces: Workspaces, modKey: String) -> [MenuNode] {
        let modifier: KeyShortcutModifier = modKey == "super" ? .command : .option
        return [desktopMenu(modifier), goMenu(), workspacesMenu(workspaces, modifier), helpMenu()]
    }

    /// In the slot an application's name takes, so the bar says what has
    /// focus even when the answer is nothing.
    private static func desktopMenu(_ modifier: KeyShortcutModifier) -> MenuNode {
        MenuNode(id: desktop, title: "Desktop", items: [
            .item(MenuItemModel(id: background, title: "Change wallpaper…",
                                icon: MenuGlyphs.image)),
            .item(MenuItemModel(id: displays, title: "Display settings…",
                                icon: MenuGlyphs.monitor)),
            .separator,
            .item(MenuItemModel(id: showDesktop, title: "Show desktop",
                                shortcut: KeyShortcut(KeyCode.d, modifier),
                                icon: MenuGlyphs.minimize)),
        ])
    }

    /// The explorer's own places, read when the menu is built: a folder made
    /// or removed since shows up the next time.
    private static func goMenu() -> MenuNode {
        let places = Places.standard()
        var items: [MenuEntry] = []
        for place in places {
            // Computer and Trash after a rule, as the explorer's sidebar has
            // them below the folders.
            if place.path == "/" { items.append(.separator) }
            items.append(.item(MenuItemModel(
                id: MenuID(goPrefix + place.path), title: place.title,
                icon: MenuGlyphs.place(place.title)
            )))
        }
        return MenuNode(id: go, title: "Go", items: items)
    }

    /// As many workspaces as the bar shows dots for, under a caption.
    private static func workspacesMenu(
        _ w: Workspaces, _ modifier: KeyShortcutModifier
    ) -> MenuNode {
        let shown = WorkspaceDots.shownCount(w)
        var items: [MenuEntry] = [.heading("Switch to")]
        for i in 0..<shown {
            items.append(.item(MenuItemModel(
                id: MenuID(workspacePrefix + String(i)),
                title: "Workspace \(i + 1)",
                isChecked: UInt32(i) == w.current,
                shortcut: KeyShortcut(KeyCode.key1 + Int32(i), modifier)
            )))
        }
        return MenuNode(id: workspaces, title: "Workspaces", items: items)
    }

    private static func helpMenu() -> MenuNode {
        MenuNode(id: help, title: "Help", items: [
            .item(MenuItemModel(id: shortcuts, title: "Keyboard shortcuts",
                                icon: MenuGlyphs.keyboard)),
            .separator,
            .item(MenuItemModel(id: DesktopMenuID.about, title: "About Lava",
                                icon: MenuGlyphs.info)),
        ])
    }

    static func counts(_ windows: [WindowInfo]) -> [Int] {
        var out = Array(repeating: 0, count: Workspaces.count)
        for window in windows where Int(window.workspace) < out.count {
            out[Int(window.workspace)] += 1
        }
        return out
    }
}

/// Every shortcut the compositor takes, as `ListKeyBindings` reports them —
/// the same list Settings' Keyboard page shows, without opening Settings.
struct ShortcutsWindow: View {
    var bindings: [KeyBinding]

    static let width: Float = 640
    static let rowHeight: Float = 30

    static func height(_ count: Int) -> Float {
        min(24 * 2 + 28 + Float(count) * rowHeight, 620)
    }

    var body: some View {
        let theme = Theme.current
        ScrollView(showsIndicator: true, indicatorInset: 12) {
            VStack(padding: 24, spacing: 0) {
                HStack() {
                    Spacer()
                    Text("Keyboard Shortcuts", color: theme.textPrimary)
                        .frame(height: .pt(28))
                    Spacer()
                }
                ForEach(Array(bindings.enumerated()), id: \.offset) { _, binding in
                    HStack(padding: 0, alignment: .center, spacing: 16) {
                        Text(Self.keys(binding), color: theme.textPrimary, lineLimit: 1)
                            .frame(width: .pt(190))
                        Text(binding.description, color: theme.textSecondary, lineLimit: 1)
                            .flexShrink(1)
                    }
                    .frame(height: .pt(Self.rowHeight))
                }
            }
        }
        .background(PanelChrome.popupWash)
        .agentId("shortcuts.window")
    }

    /// "Alt+Shift+1 … 9", "Print": the modifiers and the key, as a person
    /// presses them.
    static func keys(_ b: KeyBinding) -> String {
        b.modifiers.isEmpty || b.modifiers == "None" ? b.key : "\(b.modifiers)+\(b.key)"
    }
}

/// The menus' glyphs, from `Taskbar.dc.html`: SVG path data on a 24-unit
/// grid, stroked by the menu client in the row's colour.
enum MenuGlyphs {
    static let image = "M3 5h18v14H3zM3 16l5-5 4 4 3-3 6 6M15.5 8.5h.01"
    static let monitor = "M2 4h20v12H2zM8 20h8M12 16v4"
    static let minimize = "M3 4h18v16H3zM7 16h10"
    static let home = "M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1Z"
    static let docs = "M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7ZM14 2v4a2 2 0 0 0 2 2h4M8 13h8M8 17h5"
    static let down = "M12 3v12M7 10l5 5 5-5M5 21h14"
    static let computer = "M2 4h20v12H2zM6 20h12"
    static let keyboard = "M2 6h20v12H2zM6 10h.01M10 10h.01M14 10h.01M18 10h.01M7 14h10"
    static let info = "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18ZM12 16v-4M12 8h.01"
    static let lock = "M5 11h14v10H5zM8 11V7a4 4 0 0 1 8 0v4"
    static let logout = "M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"
    static let moon = "M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8Z"
    static let restart = "M3 12a9 9 0 1 0 3-6.7L3 8M3 3v5h5"
    static let power = "M12 3v9M6.4 6.6a8 8 0 1 0 11.2 0"
    // Not in the design, drawn to match it: the places it has no row for.
    static let folder = "M3 6a2 2 0 0 1 2-2h4l2 3h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"
    static let music = "M9 18V5l12-2v13M9 18a3 3 0 1 1-6 0 3 3 0 0 1 6 0ZM21 16a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"
    static let video = "M2 6h14v12H2zM16 10l6-4v12l-6-4Z"
    static let trash = "M3 6h18M8 6V4h8v2M6 6l1 15h10l1-15"

    /// A place in Go, by the explorer's name for it.
    static func place(_ title: String) -> String {
        switch title {
        case "Home": return home
        case "Desktop": return monitor
        case "Documents": return docs
        case "Downloads": return down
        case "Pictures": return image
        case "Music": return music
        case "Videos", "Video": return video
        case "Computer": return computer
        case "Trash": return trash
        default: return folder
        }
    }
}
