import Foundation
import Testing

@testable import LavaExplorerCore

/// Reports collected off the watcher's thread.
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Set<String>] = []
    private let arrived = DispatchSemaphore(value: 0)

    func add(_ report: Set<String>) {
        lock.lock()
        all.append(report)
        lock.unlock()
        arrived.signal()
    }

    var list: [Set<String>] {
        lock.lock()
        defer { lock.unlock() }
        return all
    }

    /// The next report, or nil after `seconds`.
    func next(within seconds: Double = 3) -> Set<String>? {
        guard arrived.wait(timeout: .now() + seconds) == .success else { return nil }
        return list.last
    }
}

private func scratch() throws -> String {
    let root = NSTemporaryDirectory() + "lava-watch-" + UUID().uuidString.prefix(8)
    try FileManager.default.createDirectory(atPath: root + "/a", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: root + "/b", withIntermediateDirectories: true)
    return root
}

@Suite(.serialized) struct FolderWatcherTests {
    @Test func aNewFileReportsItsFolder() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let reports = Reports()
        let watcher = try #require(FolderWatcher(onChange: reports.add))
        defer { watcher.stop() }
        watcher.watch([root + "/a", root + "/b"])

        FileManager.default.createFile(atPath: root + "/a/new.txt", contents: Data("x".utf8))
        #expect(reports.next() == [root + "/a"])
    }

    @Test func aBurstIsOneReport() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let reports = Reports()
        let watcher = try #require(FolderWatcher(quiet: 0.2, onChange: reports.add))
        defer { watcher.stop() }
        watcher.watch([root + "/a"])

        for i in 0..<300 {
            FileManager.default.createFile(atPath: root + "/a/\(i)", contents: nil)
        }
        #expect(reports.next() == [root + "/a"])
        // Nothing more trickles in once the burst is reported.
        #expect(reports.next(within: 0.5) == nil)
        #expect(reports.list.count == 1)
    }

    @Test func aFolderNoLongerWatchedIsQuiet() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let reports = Reports()
        let watcher = try #require(FolderWatcher(onChange: reports.add))
        defer { watcher.stop() }
        watcher.watch([root + "/a", root + "/b"])
        watcher.watch([root + "/b"])
        #expect(watcher.watched == [root + "/b"])

        FileManager.default.createFile(atPath: root + "/a/x", contents: nil)
        #expect(reports.next(within: 0.5) == nil)
        FileManager.default.createFile(atPath: root + "/b/x", contents: nil)
        #expect(reports.next() == [root + "/b"])
    }

    @Test func aDeletedFolderIsReportedAndForgotten() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let reports = Reports()
        let watcher = try #require(FolderWatcher(onChange: reports.add))
        defer { watcher.stop() }
        watcher.watch([root + "/a"])

        try FileManager.default.removeItem(atPath: root + "/a")
        #expect(reports.next() == [root + "/a"])
        #expect(watcher.watched.isEmpty, "the watch went with the folder")

        // Made again, it is watched again by the next `watch` that wants it.
        try FileManager.default.createDirectory(atPath: root + "/a", withIntermediateDirectories: false)
        watcher.watch([root + "/a"])
        FileManager.default.createFile(atPath: root + "/a/back", contents: nil)
        #expect(reports.next() == [root + "/a"])
    }

    @Test func aFolderThatIsNotThereIsSkipped() throws {
        let reports = Reports()
        let watcher = try #require(FolderWatcher(onChange: reports.add))
        defer { watcher.stop() }
        watcher.watch(["/nonexistent/lava/folder"])
        #expect(watcher.watched.isEmpty)
    }
}
