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
    public var devicesExpanded = true
    public var favorites: [String] = []
    public var servers: [String] = []
    public var folderViews = FolderViewMemory()

    public init(name: String, id: String = UUID().uuidString) {
        self.id = id
        self.name = name
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, workspace, sidebarFraction, placesExpanded, favoritesExpanded
        case serversExpanded, devicesExpanded, favorites, servers, folderViews
    }

    // New controls must not invalidate profiles saved by an older Explorer.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        workspace = try values.decodeIfPresent(PaneLayout.Workspace.self, forKey: .workspace)
        sidebarFraction = try values.decodeIfPresent(Float.self, forKey: .sidebarFraction) ?? 0.22
        placesExpanded = try values.decodeIfPresent(Bool.self, forKey: .placesExpanded) ?? true
        favoritesExpanded = try values.decodeIfPresent(Bool.self, forKey: .favoritesExpanded) ?? true
        serversExpanded = try values.decodeIfPresent(Bool.self, forKey: .serversExpanded) ?? true
        devicesExpanded = try values.decodeIfPresent(Bool.self, forKey: .devicesExpanded) ?? true
        favorites = try values.decodeIfPresent([String].self, forKey: .favorites) ?? []
        servers = try values.decodeIfPresent([String].self, forKey: .servers) ?? []
        folderViews = try values.decodeIfPresent(FolderViewMemory.self, forKey: .folderViews) ?? FolderViewMemory()
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
