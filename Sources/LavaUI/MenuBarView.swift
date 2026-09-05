import Foundation
import LavaMenu

// Vulkan (in-window) menubar chrome. Framework-owned: composed above the app
// root by `LavaApp` when a `menu:` builder is supplied. See docs/native-menus.md.

/// How a menubar strip and its dropdowns look.
///
/// The IR (`MenuModel`) is just titles and actions; this is the paint. An
/// in-window bar wants a filled strip and a `theme.panel` popup. A desktop
/// panel already paints its own gradient and wants the titles to sit on it
/// with a matching, compact dropdown — pass `.panel()` there rather than
/// restyle every row.
public struct MenuBarStyle: Equatable, Sendable {
    /// Fill behind the title strip. `nil` leaves whatever is already there.
    public var stripFill: Color?
    /// Forced strip height. `nil` sizes to the titles, which is what a
    /// panel wants when the strip itself is already a fixed 32pt.
    public var stripHeight: Float?
    public var titlePadding: EdgeInsets
    /// Inset around an icon-only title. Tighter than `titlePadding` so a
    /// 18pt mark does not sit in a text-sized chip.
    public var iconPadding: EdgeInsets
    public var titleCornerRadius: Float
    public var titleHover: Color
    /// Fill under an open title, so the chip stays lit after the pointer
    /// has moved into the dropdown.
    public var titleOpenFill: Color
    public var itemPadding: EdgeInsets
    public var itemCornerRadius: Float
    public var itemHover: Color
    public var itemSpacing: Float
    public var dropdownPadding: Float
    public var dropdownMinWidth: Float
    public var dropdownBackground: Color
    public var dropdownBorder: Color?
    public var dropdownCornerRadius: Float
    public var dropdownBlur: Float?

    public init(
        stripFill: Color?,
        stripHeight: Float?,
        titlePadding: EdgeInsets,
        iconPadding: EdgeInsets,
        titleCornerRadius: Float,
        titleHover: Color,
        titleOpenFill: Color,
        itemPadding: EdgeInsets,
        itemCornerRadius: Float,
        itemHover: Color,
        itemSpacing: Float,
        dropdownPadding: Float,
        dropdownMinWidth: Float,
        dropdownBackground: Color,
        dropdownBorder: Color?,
        dropdownCornerRadius: Float,
        dropdownBlur: Float?
    ) {
        self.stripFill = stripFill
        self.stripHeight = stripHeight
        self.titlePadding = titlePadding
        self.iconPadding = iconPadding
        self.titleCornerRadius = titleCornerRadius
        self.titleHover = titleHover
        self.titleOpenFill = titleOpenFill
        self.itemPadding = itemPadding
        self.itemCornerRadius = itemCornerRadius
        self.itemHover = itemHover
        self.itemSpacing = itemSpacing
        self.dropdownPadding = dropdownPadding
        self.dropdownMinWidth = dropdownMinWidth
        self.dropdownBackground = dropdownBackground
        self.dropdownBorder = dropdownBorder
        self.dropdownCornerRadius = dropdownCornerRadius
        self.dropdownBlur = dropdownBlur
    }

    /// Overlay chrome for the dropdown (and anything else that should
    /// match it — a panel clock or volume popover).
    public var overlayStyle: OverlayStyle {
        OverlayStyle(
            background: dropdownBackground,
            border: dropdownBorder,
            cornerRadius: dropdownCornerRadius,
            padding: dropdownPadding,
            minWidth: dropdownMinWidth,
            backdropBlurRadius: dropdownBlur
        )
    }

    /// In-window bar: filled strip, theme colours, room for shortcuts.
    public static func standard(theme: Theme = Theme.current) -> MenuBarStyle {
        MenuBarStyle(
            stripFill: theme.panel,
            stripHeight: MenuHost.barHeight,
            titlePadding: EdgeInsets(top: 2, leading: 7, bottom: 2, trailing: 7),
            iconPadding: EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4),
            titleCornerRadius: 5,
            titleHover: theme.hover,
            titleOpenFill: theme.hover,
            itemPadding: EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8),
            itemCornerRadius: 5,
            // `hover` is a one-step lift, right for a dense list and easy to
            // miss on a two-item dropdown. `selectionFill` is the chip a
            // selected settings row already wears — the same "this one"
            // language, under the pointer instead of as a choice.
            itemHover: theme.selectionFill,
            itemSpacing: 1,
            dropdownPadding: 4,
            dropdownMinWidth: 140,
            dropdownBackground: theme.panel,
            dropdownBorder: theme.border,
            dropdownCornerRadius: 8,
            dropdownBlur: nil
        )
    }

    /// Desktop panel: no strip fill (the bar already painted one), compact
    /// rows, and a popup that wears the desktop theme rather than a
    /// hard-coded indigo wash.
    ///
    /// The old fill was `0.10, 0.10, 0.24` at alpha 0.88. Linear blending
    /// lets ~0.30 of the desktop through at that alpha, which is why the
    /// menu read as a stained-glass pane instead of a surface — see
    /// `docs/colour-and-blending.md`. Without compositor frost the useful
    /// band is 0.97–1.0. With frost (a client that filled
    /// `BackdropBridge.frostOverlay`) the wash can drop so the blur shows.
    public static func panel(theme: Theme = Theme.current) -> MenuBarStyle {
        let frosted = BackdropBridge.frostOverlay != nil
        let radius = WindowBridge.desktopCornerRadius > 0
            ? WindowBridge.desktopCornerRadius
            : max(theme.cornerRadius, 8)
        return MenuBarStyle(
            stripFill: nil,
            stripHeight: nil,
            titlePadding: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
            iconPadding: EdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5),
            titleCornerRadius: 6,
            titleHover: theme.hover,
            titleOpenFill: theme.hover,
            itemPadding: EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10),
            itemCornerRadius: 6,
            itemHover: theme.selectionFill,
            itemSpacing: 1,
            dropdownPadding: 4,
            dropdownMinWidth: 0,
            dropdownBackground: theme.panel.opacity(frosted ? 0.97 : 0.98),
            dropdownBorder: theme.border,
            dropdownCornerRadius: radius,
            dropdownBlur: frosted ? 12 : nil
        )
    }
}

/// Wraps app content with an in-window menu strip when `model` is non-empty.
public struct MenuChromeRoot<Content: View>: View {
    public var model: MenuModel
    public var onActivate: (MenuID) -> Void
    public var style: MenuBarStyle
    public var content: Content

    @State private var openMenuID: MenuID? = nil

    public init(
        model: MenuModel,
        onActivate: @escaping (MenuID) -> Void,
        style: MenuBarStyle = .standard(),
        content: Content
    ) {
        self.model = model
        self.onActivate = onActivate
        self.style = style
        self.content = content
    }

    public var body: some View {
        VStack(flexGrow: 1, padding: 0, spacing: 0) {
            if !model.menus.isEmpty {
                MenuBarStrip(
                    model: model,
                    openMenuID: $openMenuID,
                    onActivate: onActivate,
                    style: style
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
    public var style: MenuBarStyle
    /// Already-decoded pictures for icon titles, keyed by menu id. A
    /// `MenuIcon.path` is used when this has nothing for that id.
    public var icons: [MenuID: UIImage]

    public init(
        model: MenuModel,
        openMenuID: Binding<MenuID?>,
        onActivate: @escaping (MenuID) -> Void,
        style: MenuBarStyle = .standard(),
        icons: [MenuID: UIImage] = [:]
    ) {
        self.model = model
        self.openMenuID = openMenuID
        self.onActivate = onActivate
        self.style = style
        self.icons = icons
    }

    public var body: some View {
        let theme = Environment.current.theme
        let openID = openMenuID.wrappedValue
        // Height is optional: an in-window bar is a 30pt chrome strip and
        // clips hover fills so they cannot spill into content. A panel
        // already has a 32pt row and wants the titles to size themselves
        // so they centre in it.
        HStack(
            height: style.stripHeight.map { .pt($0) } ?? .auto,
            padding: 0,
            alignment: .center,
            spacing: 2
        ) {
            ForEach(model.menus) { menu in
                topLevelTitle(menu, theme: theme, openID: openID)
            }
            Spacer()
        }
        .background(style.stripFill ?? .clear)
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
        let menuID = menu.id
        // Stack carries click + hover so the hit target is the padded title
        // chrome, not the text glyphs alone — and so hover can open the next
        // menu while one is already showing (native menubar behaviour).
        HStack(
            padding: 0,
            alignment: .center,
            onClick: {
                if binding.wrappedValue == menuID {
                    binding.wrappedValue = nil
                } else {
                    binding.wrappedValue = menuID
                }
            },
            onHover: { inside in
                guard inside else { return }
                // After the first click opens a menu, moving across titles
                // expands each one — without this, only a second click works.
                guard let current = binding.wrappedValue, current != menuID
                else { return }
                binding.wrappedValue = menuID
            }
        ) {
            titleLabel(menu, theme: theme, isOpen: isOpen)
        }
        .padding(menu.icon != nil ? style.iconPadding : style.titlePadding)
        .background(isOpen ? style.titleOpenFill : .clear)
        .hoverBackground(style.titleHover)
        .cornerRadius(style.titleCornerRadius)
        .agentId("menu.\(menu.id.raw)")
        .overlay(
            isPresented: Binding(
                get: { binding.wrappedValue == menuID },
                set: { presented in
                    if presented {
                        binding.wrappedValue = menuID
                    } else if binding.wrappedValue == menuID {
                        binding.wrappedValue = nil
                    }
                }
            ),
            style: style.overlayStyle
        ) {
            MenuDropdownPanel(
                entries: menu.items,
                onActivate: { id in
                    activate(id)
                    binding.wrappedValue = nil
                },
                style: style
            )
        }
    }

    @ViewBuilder
    private func titleLabel(
        _ menu: MenuNode, theme: Theme, isOpen: Bool
    ) -> some View {
        if let icon = menu.icon {
            let size = icon.size
            if let image = icons[menu.id] {
                Image(
                    image,
                    width: .pt(size), height: .pt(size), contentMode: .fit
                )
            } else if let path = icon.path {
                Image(
                    path: path,
                    width: .pt(size), height: .pt(size),
                    contentMode: .fit
                )
            } else {
                Text(
                    menu.title,
                    color: isOpen ? theme.accent : theme.textPrimary
                )
            }
        } else {
            Text(
                menu.title,
                color: isOpen ? theme.accent : theme.textPrimary
            )
        }
    }
}

/// Popup body for one top-level menu (items, separators, nested submenus).
public struct MenuDropdownPanel: View {
    public var entries: [MenuEntry]
    public var onActivate: (MenuID) -> Void
    public var style: MenuBarStyle
    /// The submenu flown out from this panel, if one is. One at a time: a
    /// menu is a path down a tree, not a set of open branches.
    @State private var openSubmenu: MenuID?

    public init(
        entries: [MenuEntry],
        onActivate: @escaping (MenuID) -> Void,
        style: MenuBarStyle = .standard()
    ) {
        self.entries = entries
        self.onActivate = onActivate
        self.style = style
    }

    public var body: some View {
        // Always a scroll container, never a plain column. A menu that fits
        // is laid out at its natural height and scrolls nowhere, so the
        // wrapper costs a node; a menu that does not fit is the reason this
        // is here at all. The bound comes from the overlay, which cuts the
        // panel down to the room beside its anchor — an applet menu listing
        // thirty wireless networks off a 32pt panel had no other way to
        // reach the bottom of itself.
        ScrollView {
            VStack(padding: 0, spacing: style.itemSpacing) {
                ForEach(Self.rows(from: entries), id: \.id) { row in
                    rowView(row)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: MenuRow) -> some View {
        let theme = Environment.current.theme
        switch row.kind {
        case .separator:
            Divider()
                .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
        case .item(let item):
            itemRow(item, theme: theme)
        case .submenu(let node):
            submenuRow(node, theme: theme)
        }
    }

    /// A row that opens a panel of its own beside this one.
    ///
    /// Hover opens it, the way a menu bar's titles open on hover once one is
    /// up: by the time the pointer is resting on a row with an arrow on it,
    /// the user has said which branch they want. Clicking does the same, for
    /// a pointer that arrived by keyboard-like jumps or a tap.
    @ViewBuilder
    private func submenuRow(_ node: MenuNode, theme: Theme) -> some View {
        let open = openSubmenu == node.id
        let nodeID = node.id
        let activate = onActivate
        let inner = style
        let row = HStack(
            padding: 0,
            alignment: .center,
            onClick: { openSubmenu = open ? nil : nodeID },
            onHover: { inside in if inside { openSubmenu = nodeID } }
        ) {
            Text(node.title, color: theme.textPrimary)
            Spacer()
            // The arrow is the only thing that says this row is a door rather
            // than a command, and it is what a person looks for.
            Text("›", color: open ? theme.textPrimary : theme.textDim)
        }
        .padding(style.itemPadding)
        .cornerRadius(style.itemCornerRadius)
        .hoverBackground(style.itemHover)
        .agentId("menu.\(node.id.raw)")

        row.overlay(
            isPresented: Binding(
                get: { openSubmenu == nodeID },
                set: { shown in
                    if !shown, openSubmenu == nodeID { openSubmenu = nil }
                }
            ),
            placement: Self.flyOut,
            style: style.overlayStyle
        ) {
            MenuDropdownPanel(
                entries: node.items,
                onActivate: { id in
                    // The whole path closes, not just the branch: choosing an
                    // item is the end of the interaction, and the panel above
                    // this one is dismissed by whoever presented it.
                    openSubmenu = nil
                    activate(id)
                },
                style: inner
            )
        }
    }

    /// Beside the row, not under it, with its top edge level with the row's.
    ///
    /// Two pixels of overlap on purpose: the pointer has to cross from the row
    /// into the panel, and a gap is a place for it to land on nothing and
    /// close what it was reaching for. Flips to the left when the right side
    /// is out of room, which on a panel menu near the screen's edge is the
    /// ordinary case rather than the exception.
    static let flyOut = OverlayPlacement { context in
        let width = context.idealSize.width
        let height = context.idealSize.height
        let right = context.anchor.x + context.anchor.width - 2
        let left = context.anchor.x - width + 2
        let x = right + width <= context.viewport.width
            ? right
            : max(0, left)
        // Level with the row it came from, pulled up when the panel would run
        // off the bottom — a submenu is read from its first item down.
        let y = min(
            max(0, context.anchor.y - 4),
            max(0, context.viewport.height - height)
        )
        return OverlayFrame(x: x, y: y, width: width, height: height)
    }

    @ViewBuilder
    private func itemRow(_ item: MenuItemModel, theme: Theme) -> some View {
        let enabled = item.isEnabled
        let color = enabled ? theme.textPrimary : theme.textDim
        let check: String = {
            guard let checked = item.isChecked else { return "" }
            return checked ? "✓ " : "  "
        }()
        let title = check + item.title
        let shortcut = item.shortcut.map(MenuShortcutLabel.format) ?? ""
        let activate = onActivate
        let itemID = item.id

        // Click and hover live on the row stack, not the label. Text-with-
        // onClick only highlights glyph bounds; the dropdown is stretch-width
        // under the parent VStack, so the stack fills the menu and the hover
        // tint covers the whole item (shortcut side included).
        let row = HStack(
            padding: 0,
            alignment: .center,
            onClick: enabled ? { activate(itemID) } : nil,
            // Crossing an ordinary row is leaving the branch: the fly-out it
            // opened goes with it, or the pointer ends up choosing from a
            // panel that belongs to a row it has walked past.
            onHover: { inside in if inside { openSubmenu = nil } }
        ) {
            Text(title, color: color)
            if !shortcut.isEmpty {
                Spacer()
                Text(shortcut, color: theme.textDim)
            }
        }
        .padding(style.itemPadding)
        .cornerRadius(style.itemCornerRadius)
        .agentId("menu.\(item.id.raw)")

        if enabled {
            row.hoverBackground(style.itemHover)
        } else {
            row
        }
    }

    // MARK: Flatten entries → rows

    struct MenuRow: Identifiable {
        enum Kind {
            case item(MenuItemModel)
            case separator
            case submenu(MenuNode)
        }

        var id: MenuID
        var kind: Kind
    }

    /// One level. A submenu stays a row and takes its children with it — it
    /// opens beside the panel rather than being spilled into it, which is
    /// what every desktop menu does and the only shape that survives a
    /// three-deep menu without turning into an indented essay.
    static func rows(from entries: [MenuEntry], path: String = "") -> [MenuRow] {
        var out: [MenuRow] = []
        for (i, entry) in entries.enumerated() {
            switch entry {
            case .separator:
                let id = MenuID(path.isEmpty ? "sep-\(i)" : "\(path)/sep-\(i)")
                out.append(MenuRow(id: id, kind: .separator))
            case .item(let item):
                out.append(MenuRow(id: item.id, kind: .item(item)))
            case .submenu(let node):
                out.append(MenuRow(id: node.id, kind: .submenu(node)))
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
