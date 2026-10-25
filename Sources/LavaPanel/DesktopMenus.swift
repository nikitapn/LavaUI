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

    /// The menus after the Lava one, for an empty bar.
    static func menus(workspaces: Workspaces, modKey: String) -> [MenuNode] {
        [desktopMenu(), goMenu(), workspacesMenu(workspaces, modKey: modKey), helpMenu()]
    }

    /// In the slot an application's name takes, so the bar says what has
    /// focus even when the answer is nothing.
    private static func desktopMenu() -> MenuNode {
        MenuNode(id: desktop, title: "Desktop", items: [
            .item(MenuItemModel(id: showDesktop, title: "Show Desktop")),
            .separator,
            .item(MenuItemModel(id: background, title: "Change Background…")),
            .item(MenuItemModel(id: displays, title: "Displays…")),
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
            items.append(.item(MenuItemModel(id: MenuID(goPrefix + place.path), title: place.title)))
        }
        return MenuNode(id: go, title: "Go", items: items)
    }

    private static func workspacesMenu(_ w: Workspaces, modKey: String) -> MenuNode {
        let modifier: KeyShortcutModifier = modKey == "super" ? .command : .option
        let items: [MenuEntry] = (0..<Workspaces.count).map { i in
            let n = i < w.windows.count ? w.windows[i] : 0
            let count = n == 0 ? "" : n == 1 ? " · 1 window" : " · \(n) windows"
            return .item(MenuItemModel(
                id: MenuID(workspacePrefix + String(i)),
                title: "Workspace \(i + 1)\(count)",
                isChecked: UInt32(i) == w.current,
                shortcut: KeyShortcut(KeyCode.key1 + Int32(i), modifier)
            ))
        }
        return MenuNode(id: workspaces, title: "Workspaces", items: items)
    }

    private static func helpMenu() -> MenuNode {
        MenuNode(id: help, title: "Help", items: [
            .item(MenuItemModel(id: shortcuts, title: "Keyboard Shortcuts")),
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
