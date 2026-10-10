#if canImport(LavaIDL)
import Foundation
import LavaClient
import LavaFindCore
import LavaIDL
import LavaUI
import NPRPC
import Observation

/// The folders LavaFind searches, and how each is doing.
///
/// Its own model rather than more of `SettingsStore`, because it talks to a
/// different process: everything else on these pages is the compositor's,
/// and this is `lava-index`'s. The split also holds for what is the truth.
/// The *list* is the config file, which this edits a line at a time and the
/// daemon reloads on save. The *state* of each folder — indexed, offline,
/// how many files — is only the daemon's to say, and comes from `Status`.
@Observable
final class IndexSettings {
    /// Configured roots, absolute, in file order.
    private(set) var roots: [String] = []
    /// What the daemon says about each root, by absolute path.
    private(set) var state: [String: RootStatus] = [:]
    /// Whether `lava-index` answered. The list is still editable without it:
    /// the file is just a file, and the daemon reads it when it starts.
    private(set) var running = false
    private(set) var message: String?
    private(set) var messageIsError = false

    @ObservationIgnored private var index: Index?
    @ObservationIgnored private let home = NSHomeDirectory()

    /// `$XDG_CONFIG_HOME/lava/index.conf`, or `LAVA_INDEX_CONFIG` — the same
    /// file `lava-index` reads (`defaultConfigPath` in indexer/src/config.cpp).
    let configPath: String = {
        let environment = ProcessInfo.processInfo.environment
        if let forced = environment["LAVA_INDEX_CONFIG"], !forced.isEmpty { return forced }
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory() + "/.config"
        return base + "/lava/index.conf"
    }()

    func load() {
        roots = readConfig().roots(home: home)
        do {
            index = try FileIndex.connect()
            running = true
            refreshStatus()
            subscribe()
        } catch {
            running = false
        }
    }

    // MARK: Editing

    /// Asks for a folder and adds it. The picker blocks until it is answered,
    /// which is what a modal dialog does; it is called from a click, between
    /// frames.
    func addFolder() {
        guard let url = FileDialog.openFolder(title: "Add a Folder to Search") else { return }
        var config = readConfig()
        guard config.add(root: url.path, home: home) else {
            note("\(FindFormat.tilde(url.path, home: home)) is already searched", isError: false)
            return
        }
        save(config, done: "Added \(FindFormat.tilde(url.path, home: home)); indexing it now")
    }

    func remove(_ root: String) {
        var config = readConfig()
        guard config.remove(root: root, home: home) else { return }
        save(config, done: "Removed \(FindFormat.tilde(root, home: home)) from search")
    }

    /// Re-checks a root against the disk, for the one change the daemon cannot
    /// see on its own: a disk repaired from another OS and remounted as it was.
    func rescan(_ root: String) {
        guard let index else { return }
        Task.detached {
            do {
                try await index.rescan(path: root)
            } catch {
                MainQueue.async { model.note("Could not rescan: \(error)", isError: true) }
            }
        }
    }

    /// The file, or — when there is none yet — what the daemon is using
    /// without one, so the first edit keeps those folders rather than
    /// replacing them with the one being added.
    private func readConfig() -> IndexConfig {
        if let text = try? String(contentsOfFile: configPath, encoding: .utf8) {
            return IndexConfig(text: text)
        }
        return IndexConfig.defaults(home: home) {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    /// Written beside and renamed over, so the daemon — which reloads on the
    /// rename — never reads half a file.
    private func save(_ config: IndexConfig, done: String) {
        let directory = (configPath as NSString).deletingLastPathComponent
        let temporary = configPath + ".tmp"
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
            try config.text.write(toFile: temporary, atomically: false, encoding: .utf8)
            if rename(temporary, configPath) != 0 {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            note("Could not save \(configPath): \(error.localizedDescription)", isError: true)
            return
        }
        roots = config.roots(home: home)
        note(running ? done : done + " when lava-index starts", isError: false)
    }

    fileprivate func note(_ text: String, isError: Bool) {
        message = text
        messageIsError = isError
    }

    // MARK: State

    private func refreshStatus() {
        guard let index else { return }
        Task.detached {
            guard let status = try? await index.status() else { return }
            MainQueue.async {
                var byPath: [String: RootStatus] = [:]
                for root in status.roots { byPath[root.path] = root }
                indexSettings.state = byPath
            }
        }
    }

    /// Crawls announce progress as they go, so a folder just added counts up
    /// on the page rather than sitting at zero until it is done.
    private func subscribe() {
        guard let index,
              let stream = try? index.subscribeChanges() else { return }
        Task.detached {
            do {
                for try await change in stream.reader {
                    MainQueue.async { indexSettings.refreshStatus() }
                    try? await stream.writer.write(IndexChangedAck(serial: change.serial))
                }
            } catch {}
            stream.writer.close()
        }
    }

    /// The line under a root's path.
    func describe(_ root: String) -> String {
        guard running else { return "lava-index is not running" }
        guard let status = state[root] else { return "Waiting for lava-index…" }
        let files = Self.count(status.entries)
        if !status.online {
            return status.entries > 0
                ? "Not mounted — \(files) remembered, searched as they were"
                : "Not there — nothing indexed"
        }
        if status.scanning { return "Indexing… \(files) so far" }
        if !status.watched {
            return "\(files) · read-only: re-checked when it is mounted"
        }
        return "\(files) · kept up to date"
    }

    static func count(_ n: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let number = formatter.string(from: NSNumber(value: n)) ?? "\(n)"
        return n == 1 ? "1 item" : "\(number) items"
    }
}

/// Reached from `MainQueue` closures, which may not capture a non-Sendable
/// model — the same arrangement every other client here uses.
nonisolated(unsafe) let indexSettings = IndexSettings()
private var model: IndexSettings { indexSettings }

struct SearchPage: View {
    let store: SettingsStore

    var body: some View {
        let settings = indexSettings
        let roots = settings.roots
        let mod = store.modKey == "super" ? "Super" : "Alt"

        return VStack(spacing: 18) {
            SettingGroup("Folders") {
                SettingRow(
                    "Searched by LavaFind",
                    "\(mod)+Space opens it. Names are indexed, not contents; "
                    + "a disk that is not always mounted is fine — its files "
                    + "stay searchable while it is away."
                ) {
                    VStack(spacing: 4) {
                        if roots.isEmpty {
                            Text("Nothing is searched yet.", color: Theme.current.textDim)
                                .padding(8)
                        }
                        ForEach(roots, id: \.self) { root in
                            RootRow(root: root, detail: settings.describe(root))
                        }
                        HStack {
                            ActionText("Add Folder…") { settings.addFolder() }
                            Spacer()
                        }
                        .padding(EdgeInsets(top: 6, leading: 0, bottom: 0, trailing: 0))
                    }
                }
            }

            if let message = settings.message {
                Text(message, color: settings.messageIsError
                     ? Theme.current.accent : Theme.current.textSecondary)
            }
            if !settings.running {
                Text("lava-index is not running, so nothing is being indexed. "
                     + "Start it with: systemctl --user start lava-index",
                     color: Theme.current.textDim)
            }
        }
    }
}

private struct RootRow: View {
    let root: String
    let detail: String

    @DrawState private var hovered = false

    var body: some View {
        HStack(padding: 8, alignment: .center, spacing: 12, onHover: { hovered = $0 }) {
            VStack(spacing: 2) {
                Text(Self.shortened(FindFormat.tilde(root, home: NSHomeDirectory())),
                     color: Theme.current.textPrimary, lineLimit: 1)
                Text(detail, color: Theme.current.textDim, lineLimit: 1)
            }
            .flexGrow(1)
            .flexShrink(1)
            ActionText("Rescan") { indexSettings.rescan(root) }
            ActionText("Remove") { indexSettings.remove(root) }
        }
        .background(hovered ? Theme.current.hover : .clear)
        .cornerRadius(6)
    }

    /// A long path loses its *start*, not its end: the end is what tells two
    /// folders apart, and a row of "/tmp/claude-1000/-home-…" says nothing.
    static func shortened(_ path: String, keep: Int = 44) -> String {
        guard path.count > keep else { return path }
        return "…" + path.suffix(keep - 1)
    }
}

/// A filled, clickable text — the Lock page's "Lock the session" shape:
/// padding first so it stays one node and the click target is the fill.
private struct ActionText: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Text(
            title,
            color: Theme.current.textPrimary,
            hoverFill: Theme.current.accent,
            cornerRadius: 6,
            onClick: action
        )
        .padding(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
        .background(Theme.current.selectionFill)
        .cornerRadius(6)
    }
}
#endif
