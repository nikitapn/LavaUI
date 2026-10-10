#if canImport(LavaIDL)
import Foundation
import LavaClient
import LavaFindCore
import LavaIDL
import LavaUI
import NPRPC
import Observation

/// What the window shows, and the one connection it shows it from.
///
/// Every answer comes from `lava-index`; this holds the latest of each and
/// nothing it could work out for itself. Replies arrive on NPRPC's threads and
/// are applied on the frame loop through `MainQueue`, each tagged with the
/// query it answers, so a reply to "rep" that lands after the user has typed
/// "report" is dropped rather than shown for a frame.
@Observable
final class FindModel {
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            // A new list; a cursor into the old one is a choice nobody made.
            selected = 0
            search()
        }
    }
    /// Answers to `query`. Empty while the query is.
    private(set) var hits: [Hit] = []
    /// More matched than were sent.
    private(set) var truncated = false
    /// What the user opened last, for the empty query.
    private(set) var recent: [Hit] = []
    /// Index into `rows`.
    var selected = 0
    /// The roots being searched that are online now, for the footer.
    private(set) var roots: [String] = []
    /// A root is mid-crawl, so an answer may be missing things.
    private(set) var indexing = false
    /// Why there is nothing to show, when the reason is not "no matches".
    private(set) var problem: String?
    /// Whether the current query has been answered yet — the difference
    /// between "searching" and "nothing matches".
    private(set) var answered = true

    @ObservationIgnored private var index: Index?
    @ObservationIgnored private var generation = 0

    var isSearching: Bool { !trimmedQuery.isEmpty }
    var rows: [Hit] { isSearching ? hits : recent }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    // MARK: Connection

    func start() {
        do {
            index = try FileIndex.connect()
        } catch {
            problem = "\(error)"
            return
        }
        refreshRecent()
        refreshStatus()
        subscribe()
    }

    /// Re-asks whatever is on screen when the index says it changed. Not a
    /// delta: a query is milliseconds, and asking again is always right.
    private func subscribe() {
        guard let index else { return }
        let stream: NPRPCBidiStream<IndexChangedAck, IndexChanged>
        do {
            stream = try index.subscribeChanges()
        } catch {
            return  // a window that does not live-update is still a search
        }
        Task.detached {
            do {
                for try await change in stream.reader {
                    let recentOnly = change.recentOnly
                    MainQueue.async {
                        if !recentOnly { model.search(keepSelection: true) }
                        model.refreshRecent()
                        model.refreshStatus()
                    }
                    try? await stream.writer.write(IndexChangedAck(serial: change.serial))
                }
            } catch {}
            stream.writer.close()
        }
    }

    // MARK: Questions

    func search(keepSelection: Bool = false) {
        generation += 1
        let asked = generation
        let text = trimmedQuery
        guard let index, !text.isEmpty else {
            hits = []
            truncated = false
            answered = true
            return
        }
        answered = false
        Task.detached {
            let result = try? await index.search(query: text, category: .any, limit: 50)
            MainQueue.async {
                guard asked == model.generation else { return }
                model.hits = result?.hits ?? []
                model.truncated = result?.truncated ?? false
                model.answered = true
                model.selected = keepSelection
                    ? min(model.selected, max(0, model.hits.count - 1)) : 0
            }
        }
    }

    func refreshRecent() {
        guard let index else { return }
        Task.detached {
            guard let recent = try? await index.recent(limit: 30) else { return }
            MainQueue.async { model.recent = recent }
        }
    }

    func refreshStatus() {
        guard let index else { return }
        Task.detached {
            guard let status = try? await index.status() else { return }
            MainQueue.async {
                model.roots = status.roots.filter(\.online).map(\.path)
                model.indexing = status.roots.contains(where: \.scanning)
            }
        }
    }

    // MARK: Actions

    func move(by delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selected = min(max(0, selected + delta), count - 1)
    }

    func openSelected() {
        let list = rows
        guard list.indices.contains(selected) else { return }
        open(list[selected])
    }

    /// Hands the file to the desktop's handler and goes. Find is a question;
    /// once it is answered the window is in the way of the answer.
    func open(_ hit: Hit) {
        guard OpenFile.run(hit.path) else {
            problem = "Nothing could open \(hit.path) (is xdg-open installed?)"
            return
        }
        // Straight to the daemon rather than through the shared helper: this
        // process is about to end, and it already holds a connection. Quit
        // once the note has left — it is fire-and-forget, so that is a send,
        // not a round trip — or the exit can beat it out of the door.
        guard let index else {
            LavaClient.quit()
        }
        let path = hit.path
        Task.detached {
            await index.noteOpened(path: path, appId: "LavaFind")
            MainQueue.async { LavaClient.quit() }
        }
    }

    /// Escape: clears a query, closes an empty window — the same key backing
    /// out one step at a time, the way the footer says.
    func escape() {
        if query.isEmpty {
            LavaClient.quit()
        } else {
            query = ""
        }
    }
}

nonisolated(unsafe) let model = FindModel()

/// `xdg-open`, detached: the handler outlives this window by design.
enum OpenFile {
    static func run(_ path: String) -> Bool {
        let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin")
            .split(separator: ":").map { "\($0)/xdg-open" }
        guard let xdgOpen = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xdgOpen)
        process.arguments = [path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}
#endif
