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
    public static let shift: Int32 = 0x0001
    public static let control: Int32 = 0x0002
    public static let alt: Int32 = 0x0004
    public static let superKey: Int32 = 0x0008
}

// MARK: - IDs

/// Stable identity for a menu or menu item across rebuilds.
///
/// Prefer explicit ids when actions or automation care about a leaf
/// (`MenuItem("Save", id: "file.save")`). When omitted, resolve assigns a path
/// from titles (`file/save`) and de-duplicates with a numeric suffix.
public struct MenuID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public var description: String { raw }
}

// MARK: - Shortcuts

/// Modifier flags for `KeyShortcut`, resolved to GLFW-style `KeyMods` bits.
public struct KeyShortcutModifier: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Command on macOS, Control on Linux/Windows.
    public static let primary = KeyShortcutModifier(rawValue: 1 << 0)
    public static let shift = KeyShortcutModifier(rawValue: 1 << 1)
    public static let option = KeyShortcutModifier(rawValue: 1 << 2)
    /// Explicit Control (also on macOS, in addition to or instead of primary).
    public static let control = KeyShortcutModifier(rawValue: 1 << 3)
    public static let command = KeyShortcutModifier(rawValue: 1 << 4)
}

/// Keyboard shortcut attached to a menu item.
///
/// Use `KeyShortcut(KeyCode.s, .primary)` for the platform save chord. Matching
/// against live key events uses `matches(key:mods:)` with the same GLFW
/// numbering as `InputEvent`.
public struct KeyShortcut: Equatable, Sendable, Hashable {
    public var key: Int32
    public var modifiers: KeyShortcutModifier

    public init(_ key: Int32, _ modifiers: KeyShortcutModifier = []) {
        self.key = key
        self.modifiers = modifiers
    }

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

public struct MenuModel: Equatable, Sendable {
    public var menus: [MenuNode]

    public init(menus: [MenuNode] = []) {
        self.menus = menus
    }

    /// Depth-first leaf items (skips separators; includes submenu leaves).
    public var allItems: [MenuItemModel] {
        menus.flatMap { $0.allItems }
    }

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

public struct MenuNode: Equatable, Sendable, Identifiable {
    public var id: MenuID
    public var title: String
    public var items: [MenuEntry]

    public init(id: MenuID, title: String, items: [MenuEntry]) {
        self.id = id
        self.title = title
        self.items = items
    }

    public var allItems: [MenuItemModel] {
        items.flatMap { entry -> [MenuItemModel] in
            switch entry {
            case .item(let model): return [model]
            case .separator: return []
            case .submenu(let node): return node.allItems
            }
        }
    }

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

public enum MenuEntry: Equatable, Sendable {
    case item(MenuItemModel)
    case separator
    case submenu(MenuNode)
}

public struct MenuItemModel: Equatable, Sendable, Identifiable {
    public var id: MenuID
    public var title: String
    public var isEnabled: Bool
    /// `nil` = not a checkable item; `true`/`false` = checked state.
    public var isChecked: Bool?
    public var shortcut: KeyShortcut?

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

    public init() {
        self.actions = [:]
    }

    public var count: Int { actions.count }

    public var ids: Set<MenuID> { Set(actions.keys) }

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

public struct MenuItem {
    public var title: String
    public var id: MenuID?
    public var shortcut: KeyShortcut?
    public var isEnabled: Bool
    public var isChecked: Bool?
    public var action: () -> Void

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

public struct MenuSeparator {
    public init() {}
}

/// One top-level menu ("File", "Edit") or a nested submenu.
public struct Menu {
    public var title: String
    public var id: MenuID?
    public var content: [MenuContent]

    public init(
        _ title: String,
        id: MenuID? = nil,
        @MenuBuilder content: () -> [MenuContent]
    ) {
        self.title = title
        self.id = id
        self.content = content()
    }

    public init(
        _ title: String,
        id: String,
        @MenuBuilder content: () -> [MenuContent]
    ) {
        self.init(title, id: MenuID(id), content: content)
    }
}

public enum MenuContent {
    case item(MenuItem)
    case separator
    case submenu(Menu)
}

/// Root menubar description.
public struct MenuBar {
    public var menus: [Menu]

    public init(@MenuBarBuilder content: () -> [Menu]) {
        self.menus = content()
    }

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

@resultBuilder
public enum MenuBuilder {
    public static func buildExpression(_ item: MenuItem) -> [MenuContent] {
        [.item(item)]
    }

    public static func buildExpression(_ _: MenuSeparator) -> [MenuContent] {
        [.separator]
    }

    public static func buildExpression(_ menu: Menu) -> [MenuContent] {
        [.submenu(menu)]
    }

    public static func buildExpression(_ contents: [MenuContent]) -> [MenuContent] {
        contents
    }

    public static func buildBlock(_ parts: [MenuContent]...) -> [MenuContent] {
        parts.flatMap { $0 }
    }

    public static func buildOptional(_ part: [MenuContent]?) -> [MenuContent] {
        part ?? []
    }

    public static func buildEither(first part: [MenuContent]) -> [MenuContent] {
        part
    }

    public static func buildEither(second part: [MenuContent]) -> [MenuContent] {
        part
    }

    public static func buildArray(_ parts: [[MenuContent]]) -> [MenuContent] {
        parts.flatMap { $0 }
    }

    public static func buildLimitedAvailability(_ part: [MenuContent]) -> [MenuContent] {
        part
    }
}

@resultBuilder
public enum MenuBarBuilder {
    public static func buildExpression(_ menu: Menu) -> [Menu] {
        [menu]
    }

    public static func buildExpression(_ menus: [Menu]) -> [Menu] {
        menus
    }

    public static func buildBlock(_ parts: [Menu]...) -> [Menu] {
        parts.flatMap { $0 }
    }

    public static func buildOptional(_ part: [Menu]?) -> [Menu] {
        part ?? []
    }

    public static func buildEither(first part: [Menu]) -> [Menu] {
        part
    }

    public static func buildEither(second part: [Menu]) -> [Menu] {
        part
    }

    public static func buildArray(_ parts: [[Menu]]) -> [Menu] {
        parts.flatMap { $0 }
    }

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
        return MenuNode(id: id, title: menu.title, items: entries)
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
    public private(set) var model: MenuModel
    private var actions: MenuActionTable

    public init() {
        self.model = MenuModel()
        self.actions = MenuActionTable()
    }

    public init(_ bar: MenuBar) {
        let resolved = bar.resolve()
        self.model = resolved.model
        self.actions = resolved.actions
    }

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

    public var actionIDs: Set<MenuID> { actions.ids }
}
