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

    @Test("A workspace's name finds its profile, ignoring case and spaces")
    func namedByWorkspace() throws {
        var profiles = ExplorerProfiles()
        let created = profiles.create(name: "Work")
        #expect(created)
        let work = try #require(profiles.profiles.last)
        #expect(profiles.named("work")?.id == work.id)
        #expect(profiles.named("  WORK ")?.id == work.id)
        #expect(profiles.named("Home")?.id == profiles.profiles[0].id)
        #expect(profiles.named("Games") == nil)
        #expect(profiles.named("") == nil)
    }

    /// Two windows, Home on one workspace and Work on another, both saving
    /// into one `profiles` key. Each writes its own profile and leaves the
    /// other's as the file has it.
    @Test("A window saves its own profile over the file and keeps the others")
    func savingKeepsOtherWindows() throws {
        var start = ExplorerProfiles()
        let created = start.create(name: "Work")
        #expect(created)
        let homeID = start.profiles[0].id
        let workID = try #require(start.profiles.last?.id)

        // Both windows loaded `start`. The Work window saves a favourite.
        var workWindow = start
        let selected = workWindow.select(id: workID)
        #expect(selected)
        var work = workWindow.selected
        work.favorites = ["/work/reports"]
        let afterWork = workWindow.saving(work, select: false, over: start)

        // The Home window saves its own change on top of what is on disk now.
        var home = start.selected
        home.favorites = ["/home/music"]
        let afterHome = start.saving(home, select: false, over: afterWork)

        #expect(afterHome.profiles.first { $0.id == workID }?.favorites == ["/work/reports"])
        #expect(afterHome.profiles.first { $0.id == homeID }?.favorites == ["/home/music"])
        // Only a choice the user made moves the default.
        #expect(afterHome.selectedID == homeID)
        #expect(start.saving(work, select: true, over: afterHome).selectedID == workID)
    }

    @Test("A profile one window made is added; a missing or broken file is this window's list")
    func savingNewAndFirst() throws {
        // What is on disk is what this window loaded, before it made one.
        let disk = ExplorerProfiles()
        var mine = disk
        let created = mine.create(name: "Games")
        #expect(created)
        let games = try #require(mine.profiles.last)
        let saved = mine.saving(games, select: true, over: disk)
        #expect(saved.profiles.map(\.name) == ["Home", "Games"])
        #expect(saved.selectedID == games.id)
        #expect(saved.isValid)
        // Made here but not the one shown — `createProfile` saves the old
        // profile before it switches — still survives the save.
        let home = mine.profiles[0]
        #expect(mine.saving(home, select: false, over: disk).profiles.map(\.name) == ["Home", "Games"])
        // Another window's first-ever "Home", under another id, is not a
        // second Home.
        let theirs = ExplorerProfiles()
        #expect(mine.saving(games, select: false, over: theirs).profiles.map(\.name) == ["Home", "Games"])
        // First save ever: nothing on disk yet.
        #expect(mine.saving(games, select: false, over: nil).profiles.map(\.name) == ["Home", "Games"])
    }
}
