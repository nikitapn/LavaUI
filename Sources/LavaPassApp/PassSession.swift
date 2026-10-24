import CLavaPass
import Foundation
import LavaHost
import LavaPassCore
import LavaUI
import Observation

/// The worker is the sole owner of decrypted vault objects; locking releases them.
private final class VaultWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "lava.pass.vault", qos: .userInitiated)
    var document: VaultDocument?
}

@Observable
final class PassSession: @unchecked Sendable {
    let isDemo: Bool
    private let demoPath: String?
    var vaultPath = AppSettings.string(forKey: "lastVault") ?? ""
    var keyFilePath = ""
    var masterPassword = ""
    var confirmation = ""
    var creating = false
    var rememberMaster = false
    var snapshot: VaultSnapshot?
    var selectedGroup: UUID?
    var selectedEntry: UUID?
    var entryContent: VaultEntryContent?
    var attachmentPendingRemoval: VaultAttachment?
    var search = ""
    var draft: CredentialDraft?
    var showPassword = false
    var groupName: String?
    var notice: String?
    var busy = false
    var confirmRecycle = false
    var generatedLength = 24
    @ObservationIgnored private let worker = VaultWorker()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var idleTimer: DispatchSourceTimer?

    init(path: String? = nil, demo: Bool = false) {
        isDemo = demo
        let demoDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("lavapass-demo-\(UUID())")
        demoPath = demo ? demoDirectory.appendingPathComponent("Demo Vault.kdbx").path : nil
        if demo { try? FileManager.default.createDirectory(at: demoDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        if let demoPath {
            vaultPath = demoPath; creating = true; masterPassword = "demo"; confirmation = "demo"
        }
        if !demo, let path { vaultPath = URL(fileURLWithPath: path).standardizedFileURL.path }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            MainQueue.async { [weak self] in
                guard let self, self.snapshot != nil, Date().timeIntervalSince(self.lastActivity) >= 300 else { return }
                self.lock()
                self.notice = "Locked after 5 minutes without activity"
            }
        }
        timer.resume(); idleTimer = timer
    }
    deinit { idleTimer?.cancel() }

    var visibleEntries: [VaultEntry] {
        guard let snapshot else { return [] }
        let groupIsRecycle = snapshot.groups.first { $0.id == selectedGroup }?.recycleBin == true
        return snapshot.entries.filter { entry in
            let inGroup = selectedGroup == nil ? !entry.recycled : entry.groupID == selectedGroup
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = query.isEmpty || [entry.title, entry.username, entry.url, entry.group].contains {
                $0.localizedCaseInsensitiveContains(query)
            }
            return (query.isEmpty ? inGroup : (groupIsRecycle ? entry.recycled : !entry.recycled)) && matches
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var selected: VaultEntry? { snapshot?.entries.first { $0.id == selectedEntry } }
    var writable: Bool { snapshot != nil && snapshot?.readOnlyReason == nil && !busy }
    func activity() { lastActivity = Date() }

    func chooseVault() {
        guard !isDemo else { return }
        guard !busy, draft == nil else { notice = "Save or cancel the current entry first"; return }
        performDialog({ FileDialog.openFile(title: "Open KeePass Vault", filters: [.init(name: "KeePass Vault", extensions: ["kdbx"])]) }) { session, url in
            session.lock(); session.creating = false; session.vaultPath = url.path
            session.keyFilePath = ""; session.notice = nil
        }
    }
    func newVault() {
        guard !isDemo else { return }
        guard !busy, draft == nil else { notice = "Save or cancel the current entry first"; return }
        performDialog({ FileDialog.saveFile(title: "Create KeePass Vault",
            filters: [.init(name: "KeePass Vault", extensions: ["kdbx"])], defaultName: "Passwords.kdbx") }) { session, url in
            session.lock(); session.vaultPath = url.pathExtension.isEmpty ? url.appendingPathExtension("kdbx").path : url.path
            session.keyFilePath = ""; session.creating = true; session.notice = nil
        }
    }
    func chooseKeyFile() {
        guard !isDemo, !busy else { return }
        performDialog({ FileDialog.openFile(title: "Choose Vault Key File") }) { session, url in
            session.keyFilePath = url.path
        }
    }

    // A modal file picker must not stall auto-lock or clipboard expiry in the parent window.
    private func performDialog(_ request: @escaping @Sendable () -> URL?,
                               receive: @escaping @Sendable (PassSession, URL) -> Void) {
        busy = true
        let token = generation
        Thread.detachNewThread { [weak self] in
            let url = request()
            MainQueue.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.busy = false
                if let url { receive(self, url) }
                ViewInvalidation.markDirty()
            }
        }
    }

    func unlock(fromKeyring: Bool = false) {
        guard !busy, !vaultPath.isEmpty else { return }
        if creating && (masterPassword.isEmpty || masterPassword != confirmation) {
            notice = "Enter a master password and matching confirmation"; return
        }
        guard !isDemo || !fromKeyring else { return }
        let url = URL(fileURLWithPath: demoPath ?? vaultPath).standardizedFileURL.resolvingSymlinksInPath()
        let key = isDemo || keyFilePath.isEmpty ? nil : URL(fileURLWithPath: keyFilePath)
        let create = creating
        let password = masterPassword
        let remember = rememberMaster && !isDemo
        let demo = isDemo
        let token = generation
        busy = true; notice = nil; masterPassword = ""; confirmation = ""
        let worker = worker
        worker.queue.async { [weak self] in
            do {
                var secret = password
                if fromKeyring {
                    var failed: Int32 = 0
                    guard let stored = lava_pass_keyring_lookup(url.path, &failed) else {
                        throw PassError.message(failed != 0 ? "The desktop keyring is unavailable or locked" : "No master password is remembered for this vault")
                    }
                    secret = String(cString: stored); lava_pass_keyring_free(stored)
                }
                let document = try create ? VaultDocument.create(url: url, password: secret)
                    : VaultDocument(url: url, password: secret, keyFile: key)
                if demo && create {
                    let root = document.snapshot.groups[0].id
                    try document.addGroup(name: "Personal", parent: root)
                    try document.addGroup(name: "Work", parent: root)
                    for (title, username, address) in [
                        ("Example Email", "alex@example.test", "https://mail.example.test"),
                        ("Code Hosting", "alex", "https://code.example.test"),
                        ("Home Router", "admin", "http://192.0.2.1")
                    ] {
                        var entry = CredentialDraft(groupID: document.snapshot.groups[1].id)
                        entry.title = title; entry.username = username; entry.url = address
                        entry.password = "demonstration-only"; entry.notes = "Public demo data — no real credentials"
                        let entryID = try document.save(entry)
                        if title == "Example Email" {
                            try document.addAttachment(entryID: entryID, name: "Recovery instructions.txt",
                                data: Data("Public demo attachment.\nKeep recovery information with your login.\n".utf8))
                        }
                    }
                }
                var message: String?
                if remember && !fromKeyring && lava_pass_keyring_store(url.path, secret) == 0 {
                    message = "Vault unlocked, but the master password could not be saved in the desktop keyring"
                }
                secret = ""
                worker.document = document
                let result = document.snapshot
                let statusMessage = message
                MainQueue.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.busy = false; self.snapshot = result; self.vaultPath = result.path
                    self.creating = false; self.masterPassword = ""; self.confirmation = ""
                    self.notice = statusMessage; self.activity()
                    AppSettings.set(result.path, forKey: "lastVault")
                    ViewInvalidation.markDirty()
                }
            } catch {
                worker.document = nil
                let message = error.localizedDescription
                MainQueue.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.busy = false; self.notice = message; ViewInvalidation.markDirty()
                }
            }
        }
    }

    func lock() {
        generation += 1
        PassClipboard.clear()
        AttachmentFiles.clear()
        FocusManager.clear()
        masterPassword = ""; confirmation = ""; draft = nil; showPassword = false
        snapshot = nil; entryContent = nil; attachmentPendingRemoval = nil; selectedEntry = nil; selectedGroup = nil; search = ""; rememberMaster = false
        groupName = nil; busy = false; confirmRecycle = false
        let worker = worker
        worker.queue.async { worker.document = nil }
        ViewInvalidation.markDirty()
    }

    func forgetMaster() {
        guard !isDemo else { return }
        guard !busy, !vaultPath.isEmpty else { return }
        let path = URL(fileURLWithPath: vaultPath).standardizedFileURL.resolvingSymlinksInPath().path
        busy = true
        let token = generation
        worker.queue.async { [weak self] in
            let success = lava_pass_keyring_forget(path) != 0
            MainQueue.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.busy = false
                self.notice = success ? "Remembered master password removed" : "Could not remove the remembered master password"
                ViewInvalidation.markDirty()
            }
        }
    }

    func selectGroup(_ id: UUID?) {
        guard draft == nil else { notice = "Save or cancel the current entry first"; return }
        selectedGroup = id; selectedEntry = nil; entryContent = nil; attachmentPendingRemoval = nil; confirmRecycle = false; activity()
    }
    func selectEntry(_ id: UUID) {
        guard draft == nil else { notice = "Save or cancel the current entry first"; return }
        selectedEntry = id; entryContent = nil; attachmentPendingRemoval = nil
        confirmRecycle = false; activity(); loadEntryContent()
    }
    private func loadEntryContent() {
        guard let id = selectedEntry else { entryContent = nil; return }
        let token = generation
        let worker = worker
        worker.queue.async { [weak self] in
            do {
                guard let document = worker.document else { return }
                let result = try document.entryContent(for: id)
                MainQueue.async { [weak self] in
                    guard let self, self.generation == token, self.selectedEntry == id else { return }
                    self.entryContent = result
                    ViewInvalidation.markDirty()
                }
            } catch {
                let message = error.localizedDescription
                MainQueue.async { [weak self] in
                    guard let self, self.generation == token, self.selectedEntry == id else { return }
                    self.notice = message; ViewInvalidation.markDirty()
                }
            }
        }
    }

    func addAttachment() {
        guard writable, draft == nil, let id = selectedEntry else { return }
        performDialog({ FileDialog.openFile(title: "Add Entry Attachment") }) { session, url in
            session.run { document in
                try document.importAttachment(entryID: id, from: url)
                return .saved(document.snapshot, id)
            }
        }
    }

    func saveAttachment(_ attachment: VaultAttachment) {
        guard !busy, let id = selectedEntry else { return }
        let name = VaultDocument.attachmentFilename(attachment.name)
        performDialog({ FileDialog.saveFile(title: "Save Attachment As", defaultName: name) }) { session, url in
            session.run { document in
                try document.exportAttachment(entryID: id, attachmentID: attachment.id, to: url)
                return .message("Attachment saved")
            }
        }
    }

    func openAttachment(_ attachment: VaultAttachment) {
        guard !busy, let id = selectedEntry else { return }
        let target: URL
        do { target = try AttachmentFiles.temporaryURL(name: attachment.name) }
        catch { notice = "Could not create a private attachment copy"; return }
        run { document in
            try document.exportAttachment(entryID: id, attachmentID: attachment.id, to: target)
            return .opened(target)
        }
    }

    func removeAttachment() {
        guard writable, let id = selectedEntry, let attachment = attachmentPendingRemoval else { return }
        run { document in
            try document.removeAttachment(entryID: id, attachmentID: attachment.id)
            return .saved(document.snapshot, id)
        }
    }

    func newEntry() {
        guard writable, draft == nil, let snapshot else { return }
        let group = snapshot.groups.first { $0.id == selectedGroup && !$0.recycleBin }
            ?? snapshot.groups.first { !$0.recycleBin }
        guard let group else { return }
        draft = CredentialDraft(groupID: group.id); showPassword = false; activity()
    }
    func editEntry() {
        guard writable, draft == nil, let id = selectedEntry else { return }
        run { doc in .draft(try doc.draft(for: id)) }
    }
    func saveEntry() {
        guard writable, let draft else { return }
        run(submittedDraft: draft) { doc in let id = try doc.save(draft); return .saved(doc.snapshot, id) }
    }
    func recycleEntry() {
        guard writable, let id = selectedEntry else { return }
        selectedEntry = nil
        run { doc in try doc.recycle(id); return .snapshot(doc.snapshot) }
    }
    func addGroup() {
        guard writable, let name = groupName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let parent = selectedGroup ?? snapshot?.groups.first?.id else { return }
        run { doc in try doc.addGroup(name: name, parent: parent); return .snapshot(doc.snapshot) }
    }
    func copyPassword() {
        guard !busy, let id = selectedEntry else { return }
        run { doc in .password(try doc.password(for: id)) }
    }
    func saveCopy() {
        guard !isDemo, !busy, snapshot?.canSaveCopy == true, draft == nil else { return }
        performDialog({ FileDialog.saveFile(title: "Save KDBX 4 Copy",
            filters: [.init(name: "KeePass Vault", extensions: ["kdbx"])], defaultName: "Passwords-copy.kdbx") }) { session, url in
            let target = url.pathExtension.isEmpty ? url.appendingPathExtension("kdbx") : url
            session.run { doc in .copy(try doc.saveCopy(to: target)) }
        }
    }
    func generatePassword() {
        draft?.password = PasswordGenerator.generate(length: generatedLength)
        activity()
    }

    private enum WorkerResult { case snapshot(VaultSnapshot), saved(VaultSnapshot, UUID), draft(CredentialDraft), password(String), copy(VaultDocument), opened(URL), message(String) }
    private struct WorkerUpdate: Sendable {
        var snapshot: VaultSnapshot?
        var draft: CredentialDraft?
        var password: String?
        var savedID: UUID?
        var opened: URL?
        var message: String?
    }
    private func run(submittedDraft: CredentialDraft? = nil, _ work: @escaping @Sendable (VaultDocument) throws -> WorkerResult) {
        guard !busy else { return }
        busy = true; notice = nil; activity()
        let token = generation
        let worker = worker
        worker.queue.async { [weak self] in
            do {
                guard let document = worker.document else { throw PassError.message("The vault is locked") }
                let result = try work(document)
                // Keep the document itself confined to this queue, including Save Copy.
                let resultUpdate: WorkerUpdate
                switch result {
                case .copy(let document): worker.document = document; resultUpdate = .init(snapshot: document.snapshot)
                case .snapshot(let value): resultUpdate = .init(snapshot: value)
                case .saved(let value, let id): resultUpdate = .init(snapshot: value, savedID: id)
                case .draft(let value): resultUpdate = .init(draft: value)
                case .password(let value): resultUpdate = .init(password: value)
                case .opened(let file): resultUpdate = .init(opened: file)
                case .message(let text): resultUpdate = .init(message: text)
                }
                MainQueue.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.busy = false
                    if let update = resultUpdate.snapshot {
                        let newerEdits = submittedDraft != nil && self.draft != nil && self.draft != submittedDraft
                        self.snapshot = update; self.vaultPath = update.path
                        if newerEdits { self.draft?.id = resultUpdate.savedID } else { self.draft = nil }
                        self.groupName = nil; self.confirmRecycle = false; self.showPassword = false
                        if let savedID = resultUpdate.savedID {
                            self.selectedEntry = savedID
                            if self.selectedGroup != nil, let group = update.entries.first(where: { $0.id == savedID })?.groupID {
                                self.selectedGroup = group
                            }
                        }
                        if !update.entries.contains(where: { $0.id == self.selectedEntry }) { self.selectedEntry = nil }
                        AppSettings.set(update.path, forKey: "lastVault")
                        self.attachmentPendingRemoval = nil
                        self.entryContent = nil
                        self.loadEntryContent()
                        self.notice = newerEdits ? "Saved; additional edits remain unsaved" : "Saved"
                    }
                    if let editing = resultUpdate.draft { self.draft = editing; self.showPassword = false }
                    if let copied = resultUpdate.password { self.copySecret(copied) }
                    if let message = resultUpdate.message { self.notice = message }
                    if let file = resultUpdate.opened {
                        self.notice = AttachmentFiles.open(file) ? "Opened attachment — temporary copy is removed on lock" : "Could not open attachment"
                    }
                    ViewInvalidation.markDirty()
                }
            } catch {
                let message = error.localizedDescription
                MainQueue.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.busy = false; self.notice = message; ViewInvalidation.markDirty()
                }
            }
        }
    }

    func copyField(_ value: String) {
        activity()
        PassClipboard.copy(value)
        notice = "Copied — clipboard clears in 30 seconds"
    }

    private func copySecret(_ value: String) {
        PassClipboard.copy(value)
        notice = "Password copied — clipboard clears in 30 seconds"
    }

}

private enum PassError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let message): return message } }
}
