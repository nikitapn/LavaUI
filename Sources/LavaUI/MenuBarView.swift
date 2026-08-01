#if canImport(CxxCanvas)
import Foundation
import LavaMenu

// Vulkan (in-window) menubar chrome. Framework-owned: composed above the app
// root by `LavaApp` when a `menu:` builder is supplied. See docs/native-menus.md.

/// Wraps app content with an in-window menu strip when `model` is non-empty.
public struct MenuChromeRoot<Content: View>: View {
    public var model: MenuModel
    public var onActivate: (MenuID) -> Void
    public var content: Content

    @State private var openMenuID: MenuID? = nil

    public init(
        model: MenuModel,
        onActivate: @escaping (MenuID) -> Void,
        content: Content
    ) {
        self.model = model
        self.onActivate = onActivate
        self.content = content
    }

    public var body: some View {
        VStack(flexGrow: 1, padding: 0) {
            if !model.menus.isEmpty {
                MenuBarStrip(
                    model: model,
                    openMenuID: $openMenuID,
                    onActivate: onActivate
                )
            }
            content.flexGrow(1)
        }
    }
}

/// Top-level titles in a fixed-height strip; each opens a dropdown overlay.
public struct MenuBarStrip: View {
    public var model: MenuModel
    public var openMenuID: Binding<MenuID?>
    public var onActivate: (MenuID) -> Void

    public init(
        model: MenuModel,
        openMenuID: Binding<MenuID?>,
        onActivate: @escaping (MenuID) -> Void
    ) {
        self.model = model
        self.openMenuID = openMenuID
        self.onActivate = onActivate
    }

    public var body: some View {
        let theme = Environment.current.theme
        let openID = openMenuID.wrappedValue
        // Fixed height + clip: title hover fills use natural text+padding size
        // and would otherwise paint past the strip into the content below.
        HStack(
            height: .pt(MenuHost.barHeight),
            padding: 0,
            alignment: .center
        ) {
            ForEach(model.menus) { menu in
                topLevelTitle(menu, theme: theme, openID: openID)
            }
            Spacer()
        }
        .background(theme.panel)
        .clipped()
        .agentId("menu.bar")
    }

    @ViewBuilder
    private func topLevelTitle(
        _ menu: MenuNode,
        theme: Theme,
        openID: MenuID?
    ) -> some View {
        let isOpen = openID == menu.id
        let binding = openMenuID
        let activate = onActivate
        Text(
            menu.title,
            color: isOpen ? theme.accent : theme.textPrimary,
            onClick: {
                if binding.wrappedValue == menu.id {
                    binding.wrappedValue = nil
                } else {
                    binding.wrappedValue = menu.id
                }
            }
        )
        // Horizontal room for a comfortable hit target; keep vertical padding
        // small so the label fits inside `MenuHost.barHeight` (see `.clipped()`).
        .padding(4)
        .hoverBackground(theme.hover)
        .cornerRadius(3)
        .agentId("menu.\(menu.id.raw)")
        .overlay(
            isPresented: Binding(
                get: { binding.wrappedValue == menu.id },
                set: { presented in
                    if presented {
                        binding.wrappedValue = menu.id
                    } else if binding.wrappedValue == menu.id {
                        binding.wrappedValue = nil
                    }
                }
            ),
            style: OverlayStyle(padding: 4, minWidth: 160)
        ) {
            MenuDropdownPanel(
                entries: menu.items,
                onActivate: { id in
                    activate(id)
                    binding.wrappedValue = nil
                }
            )
        }
    }
}

/// Popup body for one top-level menu (items, separators, nested submenus).
public struct MenuDropdownPanel: View {
    public var entries: [MenuEntry]
    public var onActivate: (MenuID) -> Void

    public init(entries: [MenuEntry], onActivate: @escaping (MenuID) -> Void) {
        self.entries = entries
        self.onActivate = onActivate
    }

    public var body: some View {
        VStack(padding: 2) {
            ForEach(Self.rows(from: entries), id: \.id) { row in
                rowView(row)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: MenuRow) -> some View {
        let theme = Environment.current.theme
        let indent = String(repeating: "  ", count: row.indent)
        switch row.kind {
        case .separator:
            Divider()
                .padding(2)
        case .header(let title):
            Text(indent + title, color: theme.textSecondary)
                .padding(4)
                .agentId("menu.\(row.id.raw)")
        case .item(let item):
            itemRow(item, indentPrefix: indent, theme: theme)
        }
    }

    @ViewBuilder
    private func itemRow(_ item: MenuItemModel, indentPrefix: String, theme: Theme) -> some View {
        let enabled = item.isEnabled
        let color = enabled ? theme.textPrimary : theme.textDim
        let check: String = {
            guard let checked = item.isChecked else { return "" }
            return checked ? "✓ " : "  "
        }()
        let title = indentPrefix + check + item.title
        let shortcut = item.shortcut.map(MenuShortcutLabel.format) ?? ""
        let activate = onActivate

        let row = HStack(padding: 0, alignment: .center) {
            Text(
                title,
                color: color,
                onClick: enabled ? { activate(item.id) } : nil
            )
            if !shortcut.isEmpty {
                Spacer()
                Text(shortcut, color: theme.textDim)
            }
        }
        .padding(4)
        .cornerRadius(3)
        .agentId("menu.\(item.id.raw)")

        if enabled {
            row.hoverBackground(theme.hover)
        } else {
            row
        }
    }

    // MARK: Flatten entries → rows

    struct MenuRow: Identifiable {
        enum Kind {
            case item(MenuItemModel)
            case separator
            case header(String)
        }

        var id: MenuID
        var indent: Int
        var kind: Kind
    }

    static func rows(from entries: [MenuEntry], indent: Int = 0, path: String = "") -> [MenuRow] {
        var out: [MenuRow] = []
        for (i, entry) in entries.enumerated() {
            switch entry {
            case .separator:
                let id = MenuID(path.isEmpty ? "sep-\(i)" : "\(path)/sep-\(i)")
                out.append(MenuRow(id: id, indent: indent, kind: .separator))
            case .item(let item):
                out.append(MenuRow(id: item.id, indent: indent, kind: .item(item)))
            case .submenu(let node):
                out.append(MenuRow(id: node.id, indent: indent, kind: .header(node.title)))
                out += rows(from: node.items, indent: indent + 1, path: node.id.raw)
            }
        }
        return out
    }
}

/// Human-readable shortcut for menu rows (Ctrl+S, etc.).
enum MenuShortcutLabel {
    static func format(_ shortcut: KeyShortcut) -> String {
        var parts: [String] = []
        let mods = shortcut.resolvedMods()
        if mods & MenuKeyMods.control != 0 { parts.append("Ctrl") }
        if mods & MenuKeyMods.superKey != 0 {
            #if os(macOS)
            parts.append("⌘")
            #else
            parts.append("Super")
            #endif
        }
        if mods & MenuKeyMods.alt != 0 { parts.append("Alt") }
        if mods & MenuKeyMods.shift != 0 { parts.append("Shift") }
        parts.append(keyName(shortcut.key))
        return parts.joined(separator: "+")
    }

    private static func keyName(_ key: Int32) -> String {
        // GLFW printable range and common keys.
        if key >= 32 && key <= 126, let s = UnicodeScalar(UInt32(key)) {
            return String(Character(s)).uppercased()
        }
        switch key {
        case KeyCode.enter: return "Enter"
        case KeyCode.tab: return "Tab"
        case KeyCode.escape: return "Esc"
        case KeyCode.backspace: return "Backspace"
        case KeyCode.delete: return "Del"
        default: return "Key\(key)"
        }
    }
}

#endif
