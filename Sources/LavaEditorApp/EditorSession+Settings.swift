import Foundation
import LavaEditorSettings
import LavaExplorerCore
import LavaUI

/// File I/O and diagnostics are driven by the frame loop, like the project tree.
final class EditorSettingsFiles {
    let user = AppSettings.directoryURL.appendingPathComponent("editor.json")
    var loader = EditorSettingsLoader()
    var effective = EditorSettings()
    var watcher: FolderWatcher?
    var reloadScheduled = false
    var migrationMessage: String?
    var activeMessages: [String] = []
    var pendingMessages: [String] = []

    deinit { watcher?.stop() }
}

private final class SettingsSessionRef: @unchecked Sendable {
    weak var session: EditorSession?
    init(_ session: EditorSession) { self.session = session }
}

extension EditorSession {
    private var folderSettingsURL: URL? {
        let root = project?.tree.root ?? workspaceURL?.deletingLastPathComponent()
        return root?.appendingPathComponent(".lava", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    func startEditorSettings() {
        let migrationKey = "editorPreferencesMigrated"
        if AppSettings.bool(forKey: migrationKey) != true {
            do {
                try UserSettingsFile.migrate(at: settingsFiles.user, legacyBool: AppSettings.bool(forKey:))
                AppSettings.set(true, forKey: migrationKey)
            } catch {
                settingsFiles.migrationMessage = "\(settingsFiles.user.path):1:1 — \(error.localizedDescription)"
            }
        }
        let owner = SettingsSessionRef(self)
        settingsFiles.watcher = FolderWatcher { _ in
            MainQueue.async { owner.session?.reloadEditorSettings() }
        }
        reloadEditorSettings()
    }

    /// A workspace switch can close one project and restore another in the same frame.
    func scheduleSettingsReload() {
        guard !settingsFiles.reloadScheduled else { return }
        settingsFiles.reloadScheduled = true
        let owner = SettingsSessionRef(self)
        MainQueue.async {
            guard let session = owner.session, session.settingsFiles.reloadScheduled else { return }
            session.reloadEditorSettings()
        }
    }

    func reloadEditorSettings() {
        settingsFiles.reloadScheduled = false
        let folder = folderSettingsURL
        let files = [settingsFiles.user] + [folder].compactMap { $0 }
        settingsFiles.watcher?.watch(Set(files.flatMap(Self.settingsWatchPaths)))
        let (settings, diagnostics) = settingsFiles.loader.load(user: settingsFiles.user, folder: folder)
        settingsFiles.effective = settings
        applyEditorPreferences(settings.editor)
        languageServers.settingsChanged()
        scheduleLanguageSync()

        var messages = [settingsFiles.migrationMessage].compactMap { $0 }
        messages += diagnostics.map(\.localizedDescription)
        if let warning = fontSettingsWarning {
            let location = settings.origin(at: ["editor", "fontFamily"])?.location?.description
                ?? "Built-in editor.fontFamily"
            messages.append("\(location) — warning: \(warning)")
        }
        reportSettingsMessages(messages)
    }

    private static func settingsWatchPaths(for file: URL) -> [String] {
        // Watch ancestors to catch a settings directory created or replaced by another editor.
        [file, file.resolvingSymlinksInPath()].flatMap { file -> [String] in
            var directory = file.deletingLastPathComponent()
            while !isDirectory(directory) {
                let parent = directory.deletingLastPathComponent()
                guard parent.path != directory.path else { return [] }
                directory = parent
            }
            return [directory.path, directory.deletingLastPathComponent().path]
        }
    }

    private func reportSettingsMessages(_ messages: [String]) {
        let pending = settingsFiles.pendingMessages
        settingsFiles.pendingMessages = messages.filter {
            pending.contains($0) || !settingsFiles.activeMessages.contains($0)
        }
        settingsFiles.activeMessages = messages
        guard pending.isEmpty, !settingsFiles.pendingMessages.isEmpty else { return }
        // Startup can open a file after loading settings, and opening a tab clears the notice.
        let owner = SettingsSessionRef(self)
        MainQueue.async {
            guard let session = owner.session else { return }
            let messages = session.settingsFiles.pendingMessages
            session.settingsFiles.pendingMessages = []
            guard !messages.isEmpty else { return }
            session.notice = ([session.notice].compactMap { $0 } + messages).joined(separator: " • ")
        }
    }

    func setEditorSetting(_ key: EditorToggle, to value: Bool) {
        let user = settingsFiles.user
        do {
            try UserSettingsFile.set(key, to: value, at: user)
            reloadEditorSettings()
            if let location = settingsFiles.effective.folderOverride(for: key) {
                notice = "\(location) — The folder setting for \(key.path.joined(separator: ".")) wins. Updated \(user.path)."
            }
        } catch {
            showSettingsFileError(error, at: user)
        }
    }

    func openUserSettings() { openSettingsFile(settingsFiles.user) }

    func openFolderSettings() {
        if let folder = folderSettingsURL { openSettingsFile(folder) }
    }

    private func openSettingsFile(_ file: URL) {
        do {
            try UserSettingsFile.createIfMissing(at: file)
            open([file])
            reloadEditorSettings()
        } catch {
            showSettingsFileError(error, at: file)
        }
    }

    private func showSettingsFileError(_ error: Error, at file: URL) {
        notice = (error as? SettingsDiagnostic)?.localizedDescription
            ?? "\(file.path):1:1 — \(error.localizedDescription)"
    }
}
