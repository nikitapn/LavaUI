// A menubar read as a list of commands: what a command palette (Emacs's
// M-x, VS Code's Ctrl+Shift+P) offers and runs.
//
// The menu already is the app's command registry — every item has an id that
// its action is registered under, a title, a shortcut and whether it can run
// now — so the palette is a second way into the same table rather than a
// second table to keep in step with the first.

/// One menu item as a command: its id and title, and the menus it sits in.
public struct MenuCommand: Equatable, Sendable, Identifiable {
    /// The item's id, which `MenuActionTable.activate` runs.
    public var id: MenuID
    /// The item's own text.
    public var title: String
    /// The titles of the menus above it, outermost first: `["Git"]`.
    public var path: [String]
    /// The item's shortcut, to show beside it.
    public var shortcut: KeyShortcut?
    /// `nil` for an ordinary item; on or off for a checkable one.
    public var isChecked: Bool?
    /// Whether it can run now.
    public var isEnabled: Bool

    /// Creates a command.
    public init(
        id: MenuID, title: String, path: [String] = [], shortcut: KeyShortcut? = nil,
        isChecked: Bool? = nil, isEnabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.shortcut = shortcut
        self.isChecked = isChecked
        self.isEnabled = isEnabled
    }

    /// What it is called in a list of every command: `Git: Next Change`.
    /// The menu is part of the name — "Search" is a menu and a view, and
    /// several menus have a "Close".
    public var label: String {
        path.isEmpty ? title : path.joined(separator: " › ") + ": " + title
    }
}

extension MenuModel {
    /// Every item in the bar as a command, in menu order, with the trailing
    /// "…" taken off titles — it says a dialog follows, which a palette's
    /// list does not need to be told.
    public var commands: [MenuCommand] {
        var out: [MenuCommand] = []
        func walk(_ node: MenuNode, path: [String]) {
            let path = path + [node.title]
            for entry in node.items {
                switch entry {
                case .item(let item):
                    var title = item.title
                    if title.hasSuffix("…") { title.removeLast() }
                    out.append(MenuCommand(
                        id: item.id, title: title, path: path, shortcut: item.shortcut,
                        isChecked: item.isChecked, isEnabled: item.isEnabled
                    ))
                case .submenu(let child):
                    walk(child, path: path)
                case .separator, .heading:
                    break
                }
            }
        }
        for menu in menus { walk(menu, path: []) }
        return out
    }
}

/// Narrows and orders commands by what has been typed, the way a minibuffer
/// completes: every space-separated word must match, in any order.
///
/// A word matches a command when it is a substring of its label, or — what
/// makes three letters enough — when its letters appear in order, with a
/// strong preference for word starts: `tsw` is Toggle Soft Wrap. Matches in
/// the title count more than matches in the menu's name, an earlier and
/// tighter match more than a scattered one, and something used recently is
/// lifted above things that scored the same.
public enum CommandFilter {
    /// `commands` that match `query`, best first. With nothing typed, the
    /// `recent` ones in that order (most recent first) and then the rest in
    /// menu order — what M-x shows before a key is pressed.
    public static func rank(
        _ commands: [MenuCommand], query: String, recent: [MenuID] = []
    ) -> [MenuCommand] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let recency = Dictionary(
            recent.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first }
        )
        if words.isEmpty {
            let used = commands.filter { recency[$0.id] != nil }
                .sorted { recency[$0.id]! < recency[$1.id]! }
            return used + commands.filter { recency[$0.id] == nil }
        }
        var scored: [(command: MenuCommand, score: Double, order: Int)] = []
        for (order, command) in commands.enumerated() {
            let title = command.title.lowercased()
            let menus = command.path.joined(separator: " ").lowercased()
            var total = 0.0
            var matched = true
            for word in words {
                let inTitle = score(word, in: title)
                let inMenus = score(word, in: menus).map { $0 * 0.6 }
                guard let best = [inTitle, inMenus].compactMap({ $0 }).max() else {
                    matched = false
                    break
                }
                total += best
            }
            guard matched else { continue }
            if let rank = recency[command.id] { total += max(0, 30 - Double(rank) * 2) }
            // Of two equal matches the shorter title is the closer one.
            total -= Double(title.count) * 0.1
            scored.append((command, total, order))
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        return scored.map(\.command)
    }

    /// How well `word` matches `text`, both lowercased; nil for not at all.
    static func score(_ word: String, in text: String) -> Double? {
        let hay = Array(text), needle = Array(word)
        guard !needle.isEmpty, needle.count <= hay.count else { return needle.isEmpty ? 0 : nil }
        func isWordStart(_ i: Int) -> Bool {
            i == 0 || !(hay[i - 1].isLetter || hay[i - 1].isNumber)
        }
        // A substring: best at a word start, and earlier is better.
        var best: Double?
        for start in 0...(hay.count - needle.count) where hay[start] == needle[0] {
            guard Array(hay[start..<(start + needle.count)]) == needle else { continue }
            var s = 100.0 + Double(needle.count) * 4
            if isWordStart(start) { s += 50 }
            if start == 0 { s += 20 }
            s -= Double(start) * 0.5
            best = max(best ?? -.infinity, s)
        }
        if let best { return best }
        // Letters in order. A letter continues the run before it when it
        // can, else takes the next word start that has it — initials are
        // what people type — else the next occurrence anywhere.
        var position = 0
        var atStarts = 0
        var gaps = 0
        for (k, letter) in needle.enumerated() {
            var found: Int?
            if k > 0, position < hay.count, hay[position] == letter {
                found = position
            } else {
                found = (position..<hay.count).first { hay[$0] == letter && isWordStart($0) }
                    ?? (position..<hay.count).first { hay[$0] == letter }
            }
            guard let at = found else { return nil }
            if isWordStart(at) { atStarts += 1 }
            gaps += at - position
            position = at + 1
        }
        return 40 + Double(atStarts) * 12 - Double(gaps) * 0.5
    }
}

extension KeyShortcut {
    /// How the shortcut is written beside a command: `Ctrl+Shift+F`, `Alt+X`,
    /// `F7`. Primary is Ctrl here; on macOS it is ⌘ and written as such.
    public var label: String {
        var parts: [String] = []
        #if os(macOS)
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.primary) || modifiers.contains(.command) { parts.append("⌘") }
        #else
        if modifiers.contains(.primary) || modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.command) { parts.append("Super") }
        if modifiers.contains(.option) { parts.append("Alt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        #endif
        parts.append(Self.keyName(key))
        return parts.joined(separator: "+")
    }

    /// GLFW key numbering: printable keys are their ASCII code.
    static func keyName(_ key: Int32) -> String {
        switch key {
        case 32: return "Space"
        case 33...126:
            if key == 96 { return "`" }
            return String(UnicodeScalar(UInt8(key)))
        case 256: return "Esc"
        case 257: return "Enter"
        case 258: return "Tab"
        case 259: return "Backspace"
        case 260: return "Insert"
        case 261: return "Delete"
        case 262: return "Right"
        case 263: return "Left"
        case 264: return "Down"
        case 265: return "Up"
        case 266: return "PageUp"
        case 267: return "PageDown"
        case 268: return "Home"
        case 269: return "End"
        case 290...314: return "F\(key - 289)"
        default: return "#\(key)"
        }
    }
}

extension KeyShortcut {
    /// Reads a shortcut written the way `label` writes one — `Ctrl+Alt+J`,
    /// `Shift+F7`, `Ctrl+Shift+Enter` — for a shortcut that comes from a
    /// file, such as an extension's manifest. Case does not matter; `Ctrl`
    /// is the platform's primary modifier, as it is in the menu.
    ///
    /// Nil for anything else, and for a printable key with no modifier
    /// other than Shift: bound, it could not be typed any more.
    public init?(label: String) {
        let parts = label.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // "Ctrl++" names the plus key: the last part is empty.
        var names = parts
        var keyName = names.removeLast()
        if keyName.isEmpty, names.last == "" {
            names.removeLast()
            keyName = "+"
        }
        guard !keyName.isEmpty else { return nil }
        var modifiers: KeyShortcutModifier = []
        for name in names {
            switch name.lowercased() {
            case "ctrl", "control", "primary", "cmd", "command", "⌘": modifiers.insert(.primary)
            case "alt", "option", "opt", "⌥": modifiers.insert(.option)
            case "shift", "⇧": modifiers.insert(.shift)
            case "super", "meta", "win": modifiers.insert(.command)
            default: return nil
            }
        }
        guard let key = Self.keyCode(named: keyName) else { return nil }
        let printable = (32...126).contains(key)
        if printable, modifiers.subtracting(.shift).isEmpty { return nil }
        self.init(key, modifiers)
    }

    /// GLFW numbering for a key's name; letters are upper case there.
    static func keyCode(named name: String) -> Int32? {
        let lower = name.lowercased()
        let named: [String: Int32] = [
            "space": 32, "esc": 256, "escape": 256, "enter": 257, "return": 257, "tab": 258,
            "backspace": 259, "insert": 260, "delete": 261, "del": 261, "right": 262, "left": 263,
            "down": 264, "up": 265, "pageup": 266, "pagedown": 267, "home": 268, "end": 269,
        ]
        if let code = named[lower] { return code }
        if lower.hasPrefix("f"), let n = Int(lower.dropFirst()), (1...25).contains(n) { return Int32(289 + n) }
        guard name.unicodeScalars.count == 1, let scalar = name.uppercased().unicodeScalars.first,
              (33...126).contains(scalar.value), !(97...122).contains(scalar.value) else { return nil }
        return Int32(scalar.value)
    }
}
