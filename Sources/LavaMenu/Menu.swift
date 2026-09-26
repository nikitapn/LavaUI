import Foundation

// Application menu description → platform-agnostic IR + action table.
//
// Pure Swift (no Yoga, Vulkan, or C++). LavaUI re-exports this module.
// Phase 1: no OS / Vulkan hosts yet — see docs/native-menus.md.
//
// Key numbers and mod bits match LavaUI `KeyCode` / `KeyMods` (GLFW).

// MARK: - Key mods (GLFW; keep in sync with LavaUI `KeyMods`)

/// Modifier bitfield used by `KeyShortcut`. Same values as GLFW / LavaUI `KeyMods`.
public enum MenuKeyMods {
    /// Shift.
    public static let shift: Int32 = 0x0001
    /// Control.
    public static let control: Int32 = 0x0002
    /// Alt.
    public static let alt: Int32 = 0x0004
    /// Super (the Windows or Command key).
    public static let superKey: Int32 = 0x0008
}

// MARK: - IDs

/// Stable identity for a menu or menu item across rebuilds.
///
/// Prefer explicit ids when actions or automation care about a leaf
/// (`MenuItem("Save", id: "file.save")`). When omitted, resolve assigns a path
/// from titles (`file/save`) and de-duplicates with a numeric suffix.
public struct MenuID: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The id as a string, such as `file/save`.
    public var raw: String

    /// Wraps a string id.
    public init(_ raw: String) {
        self.raw = raw
    }

    /// The raw string.
    public var description: String { raw }
}

/// Picture for a top-level menu title.
///
/// LavaMenu has no GPU types, so this is a path and a size. The Vulkan
/// strip loads it (or is handed a decoded `UIImage` keyed by `MenuID`).
/// DBus / Cocoa hosts ignore it and keep using `title` as the name.
public struct MenuIcon: Equatable, Sendable, Hashable {
    /// Suggested draw size, in points.
    public var size: Float
    /// File the LavaUI strip can load when it was not given pixels.
    public var path: String?

    /// Creates an icon of `size` points, loaded from `path` if one is given.
    public init(size: Float = 18, path: String? = nil) {
        self.size = size
        self.path = path
    }
}

// MARK: - Shortcuts

/// Modifier flags for `KeyShortcut`, resolved to GLFW-style `KeyMods` bits.
public struct KeyShortcutModifier: OptionSet, Sendable, Hashable {
    /// The flag bits.
    public let rawValue: Int

    /// Creates a set from its bits.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Command on macOS, Control on Linux/Windows.
    public static let primary = KeyShortcutModifier(rawValue: 1 << 0)
    /// Shift.
    public static let shift = KeyShortcutModifier(rawValue: 1 << 1)
    /// Alt (Option on macOS).
    public static let option = KeyShortcutModifier(rawValue: 1 << 2)
    /// Explicit Control (also on macOS, in addition to or instead of primary).
    public static let control = KeyShortcutModifier(rawValue: 1 << 3)
    /// Super (Command on macOS), explicitly.
    public static let command = KeyShortcutModifier(rawValue: 1 << 4)
}

/// Keyboard shortcut attached to a menu item.
///
/// Use `KeyShortcut(KeyCode.s, .primary)` for the platform save chord. Matching
/// against live key events uses `matches(key:mods:)` with the same GLFW
/// numbering as `InputEvent`.
public struct KeyShortcut: Equatable, Sendable, Hashable {
    /// The key, as a GLFW / LavaUI `KeyCode`.
    public var key: Int32
    /// The modifiers held with it.
    public var modifiers: KeyShortcutModifier

    /// Creates a shortcut from a key and a set of modifiers.
    public init(_ key: Int32, _ modifiers: KeyShortcutModifier = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Creates a shortcut from a key and any number of modifiers: `KeyShortcut(KeyCode.s, .primary, .shift)`.
    public init(_ key: Int32, _ modifiers: KeyShortcutModifier...) {
        var combined: KeyShortcutModifier = []
        for m in modifiers { combined.formUnion(m) }
        self.key = key
        self.modifiers = combined
    }

    /// Platform primary modifier bit (Super/Cmd on macOS, Control elsewhere).
    /// Values match GLFW / LavaUI `KeyMods`.
    public static var platformPrimaryMod: Int32 {
        #if os(macOS)
        MenuKeyMods.superKey
        #else
        MenuKeyMods.control
        #endif
    }

    /// GLFW-style mod bitfield for this shortcut.
    public func resolvedMods(primary: Int32 = KeyShortcut.platformPrimaryMod) -> Int32 {
        var bits: Int32 = 0
        if modifiers.contains(.primary) { bits |= primary }
        if modifiers.contains(.shift) { bits |= MenuKeyMods.shift }
        if modifiers.contains(.option) { bits |= MenuKeyMods.alt }
        if modifiers.contains(.control) { bits |= MenuKeyMods.control }
        if modifiers.contains(.command) { bits |= MenuKeyMods.superKey }
        return bits
    }

    /// Whether a physical key event matches this shortcut exactly on the mod bits.
    public func matches(
        key: Int32,
        mods: Int32,
        primary: Int32 = KeyShortcut.platformPrimaryMod
    ) -> Bool {
        self.key == key && resolvedMods(primary: primary) == mods
    }
}

// MARK: - IR (platform-facing, Equatable, no actions)

/// A resolved menubar: every menu, submenu and item with a final `MenuID`,
/// and no closures. What a backend draws or exports, and cheap to compare.
public struct MenuModel: Equatable, Sendable {
    /// The top-level menus, left to right.
    public var menus: [MenuNode]

    /// Creates a model.
    public init(menus: [MenuNode] = []) {
        self.menus = menus
    }

    /// Depth-first leaf items (skips separators; includes submenu leaves).
    public var allItems: [MenuItemModel] {
        menus.flatMap { $0.allItems }
    }

    /// The item with id `id`, searched through every menu and submenu.
    public func item(id: MenuID) -> MenuItemModel? {
        for menu in menus {
            if let found = menu.item(id: id) { return found }
        }
        return nil
    }

    /// First enabled item whose shortcut matches the key event, if any.
    public func item(
        matchingKey key: Int32,
        mods: Int32,
        primary: Int32 = KeyShortcut.platformPrimaryMod
    ) -> MenuItemModel? {
        allItems.first { item in
            guard item.isEnabled, let shortcut = item.shortcut else { return false }
            return shortcut.matches(key: key, mods: mods, primary: primary)
        }
    }
}

/// A resolved menu or submenu.
public struct MenuNode: Equatable, Sendable, Identifiable {
    /// The menu's id.
    public var id: MenuID
    /// The menu's title.
    public var title: String
    /// When set, the Vulkan strip draws this instead of the title. `title`
    /// stays the accessible name (and what a DBus host exports).
    public var icon: MenuIcon?
    /// The menu's rows, in order.
    public var items: [MenuEntry]

    /// Creates a menu node.
    public init(
        id: MenuID,
        title: String,
        icon: MenuIcon? = nil,
        items: [MenuEntry]
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.items = items
    }

    /// Every item in this menu and its submenus, depth first. Separators are skipped.
    public var allItems: [MenuItemModel] {
        items.flatMap { entry -> [MenuItemModel] in
            switch entry {
            case .item(let model): return [model]
            case .separator: return []
            case .submenu(let node): return node.allItems
            }
        }
    }

    /// The item with id `id` in this menu or its submenus.
    public func item(id: MenuID) -> MenuItemModel? {
        if self.id == id { return nil }
        for entry in items {
            switch entry {
            case .item(let model) where model.id == id:
                return model
            case .submenu(let node):
                if let found = node.item(id: id) { return found }
            default:
                break
            }
        }
        return nil
    }
}

/// One row of a resolved menu.
public enum MenuEntry: Equatable, Sendable {
    /// An item that runs an action.
    case item(MenuItemModel)
    /// A separator line.
    case separator
    /// A submenu, opening from this row.
    case submenu(MenuNode)
}

/// A resolved menu item.
public struct MenuItemModel: Equatable, Sendable, Identifiable {
    /// The item's id, which its action is registered under.
    public var id: MenuID
    /// The item's text.
    public var title: String
    /// Whether it can be activated.
    public var isEnabled: Bool
    /// `nil` = not a checkable item; `true`/`false` = checked state.
    public var isChecked: Bool?
    /// The item's keyboard shortcut, shown beside it and matched against key events.
    public var shortcut: KeyShortcut?

    /// Creates an item model.
    public init(
        id: MenuID,
        title: String,
        isEnabled: Bool = true,
        isChecked: Bool? = nil,
        shortcut: KeyShortcut? = nil
    ) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.shortcut = shortcut
    }
}

// MARK: - Action table

/// Closures keyed by `MenuID`. Not `Equatable` — compared only by key set in tests.
///
/// UI construction and activation are main-thread (same as `Button` actions).
public struct MenuActionTable {
    private var actions: [MenuID: () -> Void]

    /// Creates an empty table.
    public init() {
        self.actions = [:]
    }

    /// How many actions are registered.
    public var count: Int { actions.count }

    /// The ids that have actions.
    public var ids: Set<MenuID> { Set(actions.keys) }

    /// Whether `id` has an action.
    public func contains(_ id: MenuID) -> Bool {
        actions[id] != nil
    }

    /// Runs the action for `id` if present. Returns whether an action ran.
    @discardableResult
    public func activate(_ id: MenuID) -> Bool {
        guard let action = actions[id] else { return false }
        action()
        return true
    }

    fileprivate mutating func register(_ id: MenuID, action: @escaping () -> Void) {
        actions[id] = action
    }
}

// MARK: - Declarative description

/// A menu item in a menubar description: text, an action, and optionally an
/// id, a shortcut and a checkmark.
public struct MenuItem {
    /// The item's text.
    public var title: String
    /// The item's id, or `nil` to derive one from the menu path and title (`file/save`).
    public var id: MenuID?
    /// The item's keyboard shortcut.
    public var shortcut: KeyShortcut?
    /// Whether it can be activated.
    public var isEnabled: Bool
    /// `nil` for an ordinary item; `true` or `false` for a checkable one.
    public var isChecked: Bool?
    /// What choosing the item does.
    public var action: () -> Void

    /// Creates a menu item.
    public init(
        _ title: String,
        id: MenuID? = nil,
        shortcut: KeyShortcut? = nil,
        isEnabled: Bool = true,
        isChecked: Bool? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.id = id
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.action = action
    }

    /// String id convenience.
    public init(
        _ title: String,
        id: String,
        shortcut: KeyShortcut? = nil,
        isEnabled: Bool = true,
        isChecked: Bool? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            title,
            id: MenuID(id),
            shortcut: shortcut,
            isEnabled: isEnabled,
            isChecked: isChecked,
            action: action
        )
    }
}

/// A separator line between groups of items.
public struct MenuSeparator {
    /// Creates a separator.
    public init() {}
}

/// One top-level menu ("File", "Edit") or a nested submenu.
public struct Menu {
    /// The menu's title.
    public var title: String
    /// The menu's id, or `nil` to derive one from its title and its parent's path.
    public var id: MenuID?
    /// A picture drawn instead of the title in the in-window strip.
    public var icon: MenuIcon?
    /// The menu's rows, in order.
    public var content: [MenuContent]

    /// Creates a menu from a `@MenuBuilder` block of items, separators and submenus.
    public init(
        _ title: String,
        id: MenuID? = nil,
        icon: MenuIcon? = nil,
        @MenuBuilder content: () -> [MenuContent]
    ) {
        self.title = title
        self.id = id
        self.icon = icon
        self.content = content()
    }

    /// Creates a menu with a string id.
    public init(
        _ title: String,
        id: String,
        icon: MenuIcon? = nil,
        @MenuBuilder content: () -> [MenuContent]
    ) {
        self.init(title, id: MenuID(id), icon: icon, content: content)
    }
}

/// One row of a menu description, before resolving.
public enum MenuContent {
    /// An item.
    case item(MenuItem)
    /// A separator.
    case separator
    /// A submenu.
    case submenu(Menu)
}

/// Root menubar description.
public struct MenuBar {
    /// The top-level menus, left to right.
    public var menus: [Menu]

    /// Creates a menubar from a `@MenuBarBuilder` block of menus.
    public init(@MenuBarBuilder content: () -> [Menu]) {
        self.menus = content()
    }

    /// Creates a menubar from a list of menus.
    public init(menus: [Menu]) {
        self.menus = menus
    }

    /// Builds the platform IR and action table.
    public func resolve() -> (model: MenuModel, actions: MenuActionTable) {
        var actions = MenuActionTable()
        var used = Set<String>()
        let nodes = menus.enumerated().map { index, menu in
            MenuResolve.node(
                menu,
                pathHint: MenuResolve.slug(menu.title),
                index: index,
                actions: &actions,
                used: &used
            )
        }
        return (MenuModel(menus: nodes), actions)
    }
}

// MARK: - Result builders

/// Builds the rows of a `Menu` from items, separators and submenus, with
/// `if`, `if`/`else` and `for` supported. Items built in a loop get distinct
/// derived ids even when their titles repeat.
@resultBuilder
public enum MenuBuilder {
    /// A menu item.
    public static func buildExpression(_ item: MenuItem) -> [MenuContent] {
        [.item(item)]
    }

    /// A separator.
    public static func buildExpression(_ _: MenuSeparator) -> [MenuContent] {
        [.separator]
    }

    /// A submenu.
    public static func buildExpression(_ menu: Menu) -> [MenuContent] {
        [.submenu(menu)]
    }

    /// Rows built elsewhere, spliced in.
    public static func buildExpression(_ contents: [MenuContent]) -> [MenuContent] {
        contents
    }

    /// Joins the rows of each statement, in order.
    public static func buildBlock(_ parts: [MenuContent]...) -> [MenuContent] {
        parts.flatMap { $0 }
    }

    /// An `if` without `else`: its rows, or none.
    public static func buildOptional(_ part: [MenuContent]?) -> [MenuContent] {
        part ?? []
    }

    /// The `if` branch of an `if`/`else`.
    public static func buildEither(first part: [MenuContent]) -> [MenuContent] {
        part
    }

    /// The `else` branch of an `if`/`else`.
    public static func buildEither(second part: [MenuContent]) -> [MenuContent] {
        part
    }

    /// A `for` loop: every iteration's rows, in order.
    public static func buildArray(_ parts: [[MenuContent]]) -> [MenuContent] {
        parts.flatMap { $0 }
    }

    /// An `if #available` block: its rows unchanged.
    public static func buildLimitedAvailability(_ part: [MenuContent]) -> [MenuContent] {
        part
    }
}

/// Builds the menus of a `MenuBar`, with `if`, `if`/`else` and `for` supported.
@resultBuilder
public enum MenuBarBuilder {
    /// A menu.
    public static func buildExpression(_ menu: Menu) -> [Menu] {
        [menu]
    }

    /// Menus built elsewhere, spliced in.
    public static func buildExpression(_ menus: [Menu]) -> [Menu] {
        menus
    }

    /// Joins the menus of each statement, in order.
    public static func buildBlock(_ parts: [Menu]...) -> [Menu] {
        parts.flatMap { $0 }
    }

    /// An `if` without `else`: its menus, or none.
    public static func buildOptional(_ part: [Menu]?) -> [Menu] {
        part ?? []
    }

    /// The `if` branch of an `if`/`else`.
    public static func buildEither(first part: [Menu]) -> [Menu] {
        part
    }

    /// The `else` branch of an `if`/`else`.
    public static func buildEither(second part: [Menu]) -> [Menu] {
        part
    }

    /// A `for` loop: every iteration's menus, in order.
    public static func buildArray(_ parts: [[Menu]]) -> [Menu] {
        parts.flatMap { $0 }
    }

    /// An `if #available` block: its menus unchanged.
    public static func buildLimitedAvailability(_ part: [Menu]) -> [Menu] {
        part
    }
}

// MARK: - Resolve

enum MenuResolve {
    static func slug(_ title: String) -> String {
        let scalars = title.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .lowercased()
        return collapsed.isEmpty ? "item" : collapsed
    }

    static func uniqueID(preferred: String, used: inout Set<String>) -> MenuID {
        var candidate = preferred
        if used.contains(candidate) {
            var n = 2
            while used.contains("\(preferred)-\(n)") { n += 1 }
            candidate = "\(preferred)-\(n)"
        }
        used.insert(candidate)
        return MenuID(candidate)
    }

    static func node(
        _ menu: Menu,
        pathHint: String,
        index: Int,
        actions: inout MenuActionTable,
        used: inout Set<String>
    ) -> MenuNode {
        let preferred = menu.id?.raw ?? pathHint
        let id = uniqueID(preferred: preferred, used: &used)
        let basePath = id.raw
        let entries: [MenuEntry] = menu.content.enumerated().map { itemIndex, content in
            entry(
                content,
                parentPath: basePath,
                index: itemIndex,
                actions: &actions,
                used: &used
            )
        }
        return MenuNode(id: id, title: menu.title, icon: menu.icon, items: entries)
    }

    static func entry(
        _ content: MenuContent,
        parentPath: String,
        index: Int,
        actions: inout MenuActionTable,
        used: inout Set<String>
    ) -> MenuEntry {
        switch content {
        case .separator:
            return .separator
        case .item(let item):
            let preferred = item.id?.raw ?? "\(parentPath)/\(slug(item.title))"
            let id = uniqueID(preferred: preferred, used: &used)
            let action = item.action
            actions.register(id, action: action)
            return .item(
                MenuItemModel(
                    id: id,
                    title: item.title,
                    isEnabled: item.isEnabled,
                    isChecked: item.isChecked,
                    shortcut: item.shortcut
                )
            )
        case .submenu(let menu):
            let hint = menu.id?.raw ?? "\(parentPath)/\(slug(menu.title))"
            return .submenu(
                node(
                    menu,
                    pathHint: hint,
                    index: index,
                    actions: &actions,
                    used: &used
                )
            )
        }
    }
}

// MARK: - Controller (phase 1: retain model + actions, no platform)

/// Owns the last resolved menubar and dispatches activations.
///
/// Phase 1 does not talk to the OS or Vulkan; later phases call a backend when
/// `update` reports a model change. Main-thread only (frame loop).
public final class MenuController {
    /// The menubar as last resolved.
    public private(set) var model: MenuModel
    private var actions: MenuActionTable

    /// Creates a controller with an empty menubar.
    public init() {
        self.model = MenuModel()
        self.actions = MenuActionTable()
    }

    /// Creates a controller holding `bar`, resolved.
    public init(_ bar: MenuBar) {
        let resolved = bar.resolve()
        self.model = resolved.model
        self.actions = resolved.actions
    }

    /// Creates a controller from a `@MenuBarBuilder` block.
    public init(@MenuBarBuilder _ content: () -> [Menu]) {
        let resolved = MenuBar(content: content).resolve()
        self.model = resolved.model
        self.actions = resolved.actions
    }

    /// Rebuild from a menubar. Returns whether the platform-facing model changed.
    @discardableResult
    public func update(_ bar: MenuBar) -> Bool {
        let resolved = bar.resolve()
        let changed = resolved.model != model
        model = resolved.model
        actions = resolved.actions
        return changed
    }

    /// Rebuilds from a `@MenuBarBuilder` block. Returns whether the model changed.
    @discardableResult
    public func update(@MenuBarBuilder _ content: () -> [Menu]) -> Bool {
        update(MenuBar(content: content))
    }

    /// Invoke the action for `id` if present (even if the item is disabled in
    /// the model — callers should check `model.item(id:)` when enforcing UI).
    @discardableResult
    public func activate(_ id: MenuID) -> Bool {
        actions.activate(id)
    }

    /// Runs the action registered under the string id `id`. Returns whether one ran.
    @discardableResult
    public func activate(_ id: String) -> Bool {
        activate(MenuID(id))
    }

    /// Activate the first enabled item matching the key event.
    @discardableResult
    public func activate(
        matchingKey key: Int32,
        mods: Int32,
        primary: Int32 = KeyShortcut.platformPrimaryMod
    ) -> Bool {
        guard let item = model.item(matchingKey: key, mods: mods, primary: primary) else {
            return false
        }
        return activate(item.id)
    }

    /// The ids that have actions, for tests and diagnostics.
    public var actionIDs: Set<MenuID> { actions.ids }
}
