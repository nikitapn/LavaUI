import Foundation

public struct FontChoice: Equatable, Sendable {
    public var family: String
    public var style: FontStyle
    public var size: Int

    public init(family: String, style: FontStyle = .regular, size: Int) {
        self.family = family
        self.style = style
        self.size = size
    }
}

package enum FontFilter: String, CaseIterable {
    case all = "All"
    case favorites = "Favorites"
    case sans = "Sans"
    case serif = "Serif"
    case monospace = "Monospace"

    func includes(_ font: FontFamily, favorites: Set<String>) -> Bool {
        switch self {
        case .all: true
        case .favorites: favorites.contains(font.name)
        case .sans: font.category == .sans
        case .serif: font.category == .serif
        case .monospace: font.category == .monospace
        }
    }
}

package struct FontGroup: Equatable {
    package let label: String
    package let families: [FontFamily]
}

package struct FontChooserModel {
    package static let sizes = 6...96
    package static let presets = [9, 10, 11, 12, 13, 14, 16, 18, 24, 32, 48, 72]
    package static let defaults = FontChoice(family: "JetBrains Mono", size: 14)

    package let showsStyle: Bool
    package var query = ""
    package var filter = FontFilter.all
    package var favorites: Set<String>
    package private(set) var choice: FontChoice

    package init(selection: FontChoice, showsStyle: Bool, favorites: Set<String>) {
        choice = selection
        self.showsStyle = showsStyle
        self.favorites = favorites
        if !showsStyle { choice.style = .regular }
        setSize(selection.size)
    }

    package func groups(in catalog: FontCatalog) -> [FontGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visible = catalog.families.filter {
            filter.includes($0, favorites: favorites) &&
                (needle.isEmpty || $0.name.lowercased().contains(needle))
        }
        if !needle.isEmpty {
            guard !visible.isEmpty else { return [] }
            return [FontGroup(label: "\(visible.count) result\(visible.count == 1 ? "" : "s")", families: visible)]
        }
        if filter != .all {
            return visible.isEmpty ? [] : [FontGroup(label: filter.rawValue, families: visible)]
        }
        let starred = visible.filter { favorites.contains($0.name) }
        let rest = visible.filter { !favorites.contains($0.name) }
        return [starred.isEmpty ? nil : FontGroup(label: "Favorites", families: starred),
                rest.isEmpty ? nil : FontGroup(label: "All fonts", families: rest)].compactMap { $0 }
    }

    package mutating func toggleFavorite(_ family: String) {
        if favorites.remove(family) == nil { favorites.insert(family) }
    }

    package mutating func pick(_ family: FontFamily) {
        choice.family = family.name
        if showsStyle, !family.availableStyles.contains(choice.style) {
            choice.style = FontStyle.allCases.first(where: family.availableStyles.contains) ?? .regular
        }
    }

    package mutating func pickStyle(_ style: FontStyle, in family: FontFamily) {
        guard showsStyle, family.availableStyles.contains(style) else { return }
        choice.style = style
    }

    package mutating func setSize(_ size: Int) {
        choice.size = min(max(size, Self.sizes.lowerBound), Self.sizes.upperBound)
    }

    package mutating func pickPreset(_ size: Int) {
        if Self.presets.contains(size) { setSize(size) }
    }

    package mutating func reset(in catalog: FontCatalog) {
        choice = Self.defaults
        if let family = catalog.family(named: choice.family)
            ?? catalog.family(named: "Noto Sans Mono")
            ?? catalog.families.first(where: \.isMonospaced)
            ?? catalog.families.first {
            pick(family)
        }
    }
}
