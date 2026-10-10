import Foundation
import Testing

@testable import LavaExplorerCore

@Suite struct FolderViewMemoryTests {
    @Test func aChoiceIsRememberedPerFolderAndTheNewestWins() {
        var memory = FolderViewMemory()
        #expect(memory.mode(for: "/home/me/Pictures") == nil)
        memory.remember(.icons, for: "/home/me/Pictures/")
        memory.remember(.list, for: "/home/me/src")
        #expect(memory.mode(for: "/home/me/Pictures") == .icons, "trailing slash or not, one folder")
        #expect(memory.mode(for: "/home/me/src") == .list)
        memory.remember(.list, for: "/home/me/Pictures")
        #expect(memory.mode(for: "/home/me/Pictures") == .list)
        #expect(memory.choices.map(\.path) == ["/home/me/src", "/home/me/Pictures"])
    }

    @Test func theOldestChoicesGoFirst() {
        var memory = FolderViewMemory()
        for i in 0..<(FolderViewMemory.capacity + 5) {
            memory.remember(.icons, for: "/f/\(i)")
        }
        #expect(memory.choices.count == FolderViewMemory.capacity)
        #expect(memory.mode(for: "/f/0") == nil)
        #expect(memory.mode(for: "/f/\(FolderViewMemory.capacity + 4)") == .icons)
    }

    @Test func aMovedFolderTakesItsChoicesAlong() {
        var memory = FolderViewMemory()
        memory.remember(.icons, for: "/a/photos")
        memory.remember(.list, for: "/a/photos/raw")
        memory.remember(.icons, for: "/a/photosX")
        memory.rebase(from: "/a/photos", to: "/b/pics")
        #expect(memory.mode(for: "/b/pics") == .icons)
        #expect(memory.mode(for: "/b/pics/raw") == .list)
        #expect(memory.mode(for: "/a/photosX") == .icons, "a name that only starts the same stays")
    }

    @Test func itRoundTripsThroughJSON() throws {
        var memory = FolderViewMemory()
        memory.remember(.icons, for: "/a")
        let data = try JSONEncoder().encode(memory)
        #expect(try JSONDecoder().decode(FolderViewMemory.self, from: data) == memory)
    }
}
