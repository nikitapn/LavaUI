import Foundation
import Testing
@testable import LavaExplorerCore

@Suite("Explorer profiles")
struct ProfileTests {
    @Test("Switching profiles keeps separate workspaces and sidebar settings")
    func isolation() throws {
        var home = ExplorerProfile(name: "Home")
        home.workspace = PaneLayout.Workspace(root: .pane(paths: ["/home", "/pictures"], selected: 1), activePane: 0)
        home.favorites = ["/pictures"]
        home.placesExpanded = false
        var profiles = ExplorerProfiles(initial: home)
        let result1 = profiles.create(name: "Work")
        #expect(result1)
        let workID = try #require(profiles.profiles.last?.id)
        let result2 = profiles.select(id: workID)
        #expect(result2)
        #expect(profiles.selected.workspace == nil)
        #expect(profiles.selected.favorites.isEmpty)
        #expect(profiles.selected.placesExpanded)
        var work = profiles.selected
        work.workspace = PaneLayout.Workspace(root: .pane(paths: ["ftp://alice@example.com/projects"], selected: 0), activePane: 0)
        work.favorites = ["ftp://alice@example.com/projects"]
        work.servers = ["ftp://alice@example.com/"]
        work.sidebarFraction = 0.3
        work.folderViews.remember(.icons, for: "/reports")
        profiles.update(work)
        let result3 = profiles.select(id: home.id)
        #expect(result3)
        #expect(profiles.selected == home)
        let result4 = profiles.select(id: workID)
        #expect(result4)
        #expect(profiles.selected == work)
        let decoded = try JSONDecoder().decode(ExplorerProfiles.self, from: JSONEncoder().encode(profiles))
        #expect(decoded.isValid)
        #expect(decoded == profiles)
        #expect(decoded.selected == work)
    }

    @Test("Profile names are trimmed, unique without case, and cannot be empty")
    func names() {
        var profiles = ExplorerProfiles()
        let result5 = profiles.create(name: "  ")
        #expect(!result5)
        let result6 = profiles.create(name: " home ")
        #expect(!result6)
        let result7 = profiles.create(name: " Work ")
        #expect(result7)
        #expect(profiles.profiles.last?.name == "Work")
        let result8 = profiles.create(name: "WORK")
        #expect(!result8)
        let before = profiles
        let result9 = profiles.select(id: "missing")
        #expect(!result9)
        #expect(profiles == before)
    }

    @Test("An invalid saved selection is rejected before use")
    func invalidSelection() throws {
        let data = Data("{\"profiles\":[],\"selectedID\":\"missing\"}".utf8)
        let decoded = try JSONDecoder().decode(ExplorerProfiles.self, from: data)
        #expect(!decoded.isValid)
    }
}
