import Foundation

/// Named Explorer setups. Passwords remain in the keyring, outside profiles.
public struct ExplorerProfile: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var workspace: PaneLayout.Workspace?
    public var sidebarFraction: Float = 0.22
    public var placesExpanded = true
    public var favoritesExpanded = true
    public var serversExpanded = true
    public var favorites: [String] = []
    public var servers: [String] = []
    public var folderViews = FolderViewMemory()

    public init(name: String, id: String = UUID().uuidString) {
        self.id = id
        self.name = name
    }
}

public struct ExplorerProfiles: Codable, Equatable, Sendable {
    public private(set) var profiles: [ExplorerProfile]
    public private(set) var selectedID: String
    public var selected: ExplorerProfile {
        profiles.first { $0.id == selectedID } ?? profiles[0]
    }

    public init(initial: ExplorerProfile = ExplorerProfile(name: "Home")) {
        profiles = [initial]
        selectedID = initial.id
    }

    public var isValid: Bool {
        !profiles.isEmpty && Set(profiles.map(\.id)).count == profiles.count
            && profiles.contains { $0.id == selectedID }
    }

    @discardableResult
    public mutating func create(name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
        else { return false }
        let profile = ExplorerProfile(name: name)
        profiles.append(profile)
        return true
    }

    @discardableResult
    public mutating func select(id: String) -> Bool {
        guard profiles.contains(where: { $0.id == id }) else { return false }
        selectedID = id
        return true
    }

    public mutating func update(_ profile: ExplorerProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
    }
}
