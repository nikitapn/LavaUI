import Foundation
import Testing

@testable import LavaExplorerCore

private struct MemorySource: FileSource {
    var byPath: [String: FileEntry]
    var children: [String: [String]]

    func entries(in directory: String) throws -> [FileEntry] {
        guard let names = children[directory] else {
            throw FileAccessError(path: directory, message: "Not found")
        }
        return names.compactMap { byPath[$0] }
    }

    func entry(at path: String) throws -> FileEntry {
        guard let entry = byPath[path] else {
            throw FileAccessError(path: path, message: "Not found")
        }
        return entry
    }

    func exists(_ path: String) -> Bool { byPath[path] != nil }
}

private func sample() -> MemorySource {
    let files: [FileEntry] = [
        FileEntry(path: "/", name: "/", isDirectory: true),
        FileEntry(path: "/home", name: "home", isDirectory: true),
        FileEntry(path: "/home/pics", name: "pics", isDirectory: true),
        FileEntry(
            path: "/home/pics/IMG_2.png", name: "IMG_2.png",
            isDirectory: false, size: 20
        ),
        FileEntry(
            path: "/home/pics/IMG_10.png", name: "IMG_10.png",
            isDirectory: false, size: 10
        ),
        FileEntry(
            path: "/home/pics/notes.txt", name: "notes.txt",
            isDirectory: false, size: 4
        ),
        FileEntry(
            path: "/home/pics/.secret", name: ".secret",
            isDirectory: false, size: 1, isHidden: true
        ),
        FileEntry(path: "/home/a", name: "a", isDirectory: true),
        FileEntry(
            path: "/home/readme", name: "readme",
            isDirectory: false, size: 8
        ),
    ]
    return MemorySource(
        byPath: Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) }),
        children: [
            "/": ["/home"],
            "/home": ["/home/pics", "/home/a", "/home/readme"],
            "/home/pics": [
                "/home/pics/IMG_2.png", "/home/pics/IMG_10.png",
                "/home/pics/notes.txt", "/home/pics/.secret",
            ],
            "/home/a": [],
        ]
    )
}

@Suite("Names")
struct NameTests {
    @Test("Digit runs compare as numbers")
    func digits() {
        let names = ["IMG_10.png", "IMG_9.png", "IMG_100.png", "IMG_2.png"]
        #expect(
            names.sorted(by: FileName.compare)
                == ["IMG_2.png", "IMG_9.png", "IMG_10.png", "IMG_100.png"]
        )
    }

    @Test("Case does not split a folder into two blocks")
    func folding() {
        #expect(
            ["beta", "Alpha", "alpha2"].sorted(by: FileName.compare)
                == ["Alpha", "alpha2", "beta"]
        )
    }
}

@Suite("Listing")
struct ListingTests {
    @Test("Folders come first, then names in natural order")
    func foldersFirst() {
        let listing = FolderListing.load(path: "/home", source: sample())
        #expect(listing.entries.map(\.name) == ["a", "pics", "readme"])
        #expect(listing.folderCount == 2)
        #expect(listing.fileCount == 1)
    }

    @Test("Hidden names stay out until asked for")
    func hidden() {
        let hidden = FolderListing.load(path: "/home/pics", source: sample())
        #expect(!hidden.entries.contains { $0.name == ".secret" })
        let shown = FolderListing.load(
            path: "/home/pics", source: sample(), showHidden: true
        )
        #expect(shown.entries.contains { $0.name == ".secret" })
    }

    @Test("IMG_2 sorts before IMG_10")
    func photoOrder() {
        let listing = FolderListing.load(path: "/home/pics", source: sample())
        #expect(
            listing.entries.map(\.name)
                == ["IMG_2.png", "IMG_10.png", "notes.txt"]
        )
    }

    @Test("Size sort keeps folders first")
    func sizeSort() {
        let listing = FolderListing.load(
            path: "/home", source: sample(), sort: .size, descending: true
        )
        let foldersFirst = listing.entries.prefix(2).allSatisfy(\.isDirectory)
        #expect(foldersFirst)
        #expect(listing.entries.last?.name == "readme")
    }

    @Test("A missing folder is an error, not a crash")
    func missing() {
        let listing = FolderListing.load(path: "/nope", source: sample())
        #expect(listing.entries.isEmpty)
        #expect(listing.error != nil)
        #expect(listing.path == "/nope")
    }
}

@Suite("History")
struct HistoryTests {
    @Test("Visit pushes back and clears forward")
    func visit() {
        var history = FolderHistory(path: "/home")
        #expect(!history.canGoBack)
        history.visit("/home/pics")
        #expect(history.path == "/home/pics")
        #expect(history.canGoBack)
        history.goBack()
        #expect(history.path == "/home")
        #expect(history.canGoForward)
        history.visit("/home/a")
        #expect(!history.canGoForward)
        #expect(history.path == "/home/a")
    }

    @Test("Visiting here is not a visit")
    func samePlace() {
        var history = FolderHistory(path: "/home")
        let stayed = history.visit("/home")
        #expect(!stayed)
        #expect(!history.canGoBack)
    }

    @Test("Up stops at the root")
    func up() {
        var history = FolderHistory(path: "/home/pics")
        history.goUp()
        #expect(history.path == "/home")
        history.goUp()
        #expect(history.path == "/")
        #expect(!history.canGoUp)
        history.goUp()
        #expect(history.path == "/")
    }

    @Test("Tilde and dots become an absolute path")
    func normalize() {
        #expect(FolderHistory.normalize("/home/./pics/..") == "/home")
        #expect(FolderHistory.normalize("") == "/")
    }

    @Test("A file argument lands in its folder, selected")
    func landingOnAFile() {
        let (directory, select) = FolderHistory.landing(
            argument: "/home/pics/notes.txt", source: sample()
        )
        #expect(directory == "/home/pics")
        #expect(select == "/home/pics/notes.txt")
    }

    @Test("A folder argument is the place")
    func landingOnAFolder() {
        let (directory, select) = FolderHistory.landing(
            argument: "/home/pics", source: sample()
        )
        #expect(directory == "/home/pics")
        #expect(select == nil)
    }
}

@Suite("Tabs")
struct TabTests {
    @Test("A new tab opens after the active one and takes the selection")
    func openInsertsAfter() {
        var tabs = ExplorerTabs(tab: ExplorerTab.open(
            id: 1, path: "/home", source: sample()
        ))
        tabs.open(path: "/home/pics", source: sample())
        #expect(tabs.tabs.map(\.title) == ["home", "pics"])
        #expect(tabs.current.title == "pics")
        tabs.select(id: 1)
        tabs.open(path: "/home/a", source: sample())
        #expect(tabs.tabs.map(\.title) == ["home", "a", "pics"])
        #expect(tabs.current.title == "a")
    }

    @Test("Closing a tab to the left keeps the same folder selected")
    func closeShiftsIndex() {
        var tabs = ExplorerTabs(tab: ExplorerTab.open(
            id: 1, path: "/home", source: sample()
        ))
        tabs.open(path: "/home/pics", source: sample())
        tabs.open(path: "/home/a", source: sample())
        tabs.select(id: 3)
        let kept = tabs.close(id: 1)
        #expect(kept)
        #expect(tabs.current.title == "a")
        #expect(tabs.tabs.map(\.id) == [2, 3])
    }

    @Test("The last tab is a window, not an empty strip")
    func lastTab() {
        var tabs = ExplorerTabs(tab: ExplorerTab.open(
            id: 1, path: "/home", source: sample()
        ))
        let last = tabs.close(id: 1)
        #expect(!last)
        #expect(tabs.tabs.isEmpty)
    }

    @Test("Cycling wraps")
    func cycle() {
        var tabs = ExplorerTabs(tab: ExplorerTab.open(
            id: 1, path: "/home", source: sample()
        ))
        tabs.open(path: "/home/pics", source: sample())
        tabs.cycle(by: 1)
        #expect(tabs.current.title == "home")
        tabs.cycle(by: -1)
        #expect(tabs.current.title == "pics")
    }

    @Test("Each tab keeps its own history")
    func historyIsPerTab() {
        var tabs = ExplorerTabs(tab: ExplorerTab.open(
            id: 1, path: "/home", source: sample()
        ))
        tabs.updateCurrent { $0.history.visit("/home/pics") }
        tabs.open(path: "/home/a", source: sample())
        #expect(tabs.current.history.path == "/home/a")
        #expect(!tabs.current.history.canGoBack)
        tabs.select(id: 1)
        #expect(tabs.current.history.path == "/home/pics")
        #expect(tabs.current.history.canGoBack)
    }
}

@Suite("Places")
struct PlaceTests {
    @Test("Home and Computer always appear")
    func always() {
        let places = Places.standard(
            home: "/home/somebody",
            userDirs: "",
            exists: { _ in false }
        )
        #expect(places.map(\.title) == ["Home", "Computer"])
        #expect(places.map(\.path) == ["/home/somebody", "/"])
    }

    @Test("XDG user dirs that exist are listed, $HOME expanded")
    func userDirs() {
        let text = """
            # comment
            XDG_DESKTOP_DIR="$HOME/Desktop"
            XDG_DOWNLOAD_DIR="$HOME/Downloads"
            XDG_DOCUMENTS_DIR="/mnt/papers"
            """
        let places = Places.standard(
            home: "/home/somebody",
            userDirs: text,
            exists: {
                $0 == "/home/somebody/Desktop" || $0 == "/mnt/papers"
                    || $0 == "/home/somebody" || $0 == "/"
            }
        )
        #expect(places.map(\.title) == ["Home", "Desktop", "Documents", "Computer"])
        #expect(places.contains { $0.path == "/mnt/papers" })
        #expect(!places.contains { $0.title == "Downloads" })
    }
}
