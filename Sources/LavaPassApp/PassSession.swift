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
    struct EntryDetails: Sendable {
        let entry: VaultEntry
        let content: VaultEntryContent?
        fileprivate let request: Int
    }

    let isDemo: Bool
    private let demoPath: String?
    var vaultPath = AppSettings.string(forKey: "lastVault") ?? "" {
        didSet { if oldValue != vaultPath { unlockError = nil } }
    }
    var recentVaults: [String] = []
    var keyFilePath = "" {
        didSet { if oldValue != keyFilePath { unlockError = nil } }
    }
    var masterPassword = "" {
        didSet { if oldValue != masterPassword { unlockError = nil } }
    }
    var confirmation = "" {
        didSet { if oldValue != confirmation { unlockError = nil } }
    }
    var showMasterPassword = false
    var vaultPathFocused = false
    var masterPasswordFocused = false
    var confirmationFocused = false
    private(set) var unlockError: String?
    private(set) var unlockShake = 0
    var creating = false
    var rememberMaster = false
    var snapshot: VaultSnapshot?
    var selectedGroup: UUID?
    private(set) var selectedEntry: UUID?
    private(set) var entryDetails: EntryDetails?
    var attachmentPendingRemoval: VaultAttachment?
    var search = ""
    var searchFocused = false
    var draft: CredentialDraft?
    var showPassword = false
    private(set) var revealedPassword: String?
    var groupName: String?
    var notice: String?
    private(set) var clipboardNotice: String?
    var busy = false
    var confirmRecycle = false
    var generatedLength = 24
    var generatedCharacters: PasswordGenerator.Characters = .all
    @ObservationIgnored private let worker = VaultWorker()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var entryRequest = 0
    @ObservationIgnored private var revealRequest = 0
    @ObservationIgnored private var clipboardRequest = 0
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var idleTimer: DispatchSourceTimer?

    init(path: String? = nil, demo: Bool = false) {
        isDemo = demo
        let demoDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("lavapass-demo-\(UUID())")
        demoPath = demo ? demoDirectory.appendingPathComponent("Demo Vault.kdbx").path : nil
        if !demo {
            recentVaults = Array((AppSettings.value(forKey: "recentVaults", as: [String].self)
                ?? (vaultPath.isEmpty ? [] : [vaultPath])).prefix(10))
        }
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
    var actionableEntryID: UUID? {
        guard let id = selectedEntry, let details = entryDetails, details.entry.id == id,
              details.request == entryRequest else { return nil }
        return id
    }
    func canAct(on details: EntryDetails) -> Bool {
        draft == nil && actionableEntryID == details.entry.id && details.request == entryRequest
    }
    var writable: Bool { snapshot != nil && snapshot?.readOnlyReason == nil && !busy }
    func activity() { lastActivity = Date() }

    func chooseVault() {
        guard !isDemo else { return }
        guard !busy, draft == nil else { notice = "Save or cancel the current entry first"; return }
        performDialog({ FileDialog.openFile(title: "Open KeePass Vault", filters: [.init(name: "KeePass Vault", extensions: ["kdbx"])]) }) { session, url in
            session.openRecentVault(url.path)
        }
    }
    func openRecentVault(_ path: String) {
        guard !isDemo, !busy else { return }
        guard draft == nil else { notice = "Save or cancel the current entry first"; return }
        lock()
        creating = false; vaultPath = path; keyFilePath = ""; notice = nil
        activity()
    }

    func clearRecentVaults() {
        guard !isDemo else { return }
        recentVaults = []
        AppSettings.set(recentVaults, forKey: "recentVaults")
    }

    func removeRecentVault(_ path: String) {
        guard !isDemo, !busy else { return }
        recentVaults.removeAll { $0 == path }
        AppSettings.set(recentVaults, forKey: "recentVaults")
    }

    private func rememberVault(_ path: String) {
        guard !isDemo else { return }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        recentVaults.removeAll { $0 == canonical }
        recentVaults.insert(canonical, at: 0)
        recentVaults = Array(recentVaults.prefix(10))
        AppSettings.set(recentVaults, forKey: "recentVaults")
        AppSettings.set(canonical, forKey: "lastVault")
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
            rejectUnlock("Enter a master password and matching confirmation.")
            return
        }
        guard !isDemo || !fromKeyring else { return }
        let url = URL(fileURLWithPath: demoPath ?? vaultPath).standardizedFileURL.resolvingSymlinksInPath()
        let key = isDemo || keyFilePath.isEmpty ? nil : URL(fileURLWithPath: keyFilePath)
        let create = creating
        let password = masterPassword
        let remember = rememberMaster && !isDemo
        let demo = isDemo
        let token = generation
        busy = true; notice = nil; unlockError = nil
        if showMasterPassword { toggleMasterPasswordVisibility() }
        masterPassword = ""; confirmation = ""
        let worker = worker
        worker.queue.async { [weak self] in
            do {
                var secret = password
                if fromKeyring {
                    var failed: Int32 = 0
                    guard let stored = lava_pass_keyring_lookup(url.path, &failed) else {
                        if failed != 0 { throw PassError.message("The desktop keyring is unavailable or locked") }
                        throw PassError.noRememberedPassword
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
                    self.rememberVault(result.path)
                    ViewInvalidation.markDirty()
                }
            } catch {
                worker.document = nil
                let inlineError: String?
                if case .unlockFailed? = error as? VaultError, !create {
                    inlineError = !fromKeyring && password.isEmpty && key == nil
                        ? "Enter your master password, or use the keyring."
                        : "Could not unlock. Check the password, key file, and vault format."
                } else if case .noRememberedPassword? = error as? PassError {
                    inlineError = error.localizedDescription
                } else {
                    inlineError = nil
                }
                let message = error.localizedDescription
                MainQueue.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.busy = false
                    if let inlineError { self.rejectUnlock(inlineError) } else { self.notice = message }
                    ViewInvalidation.markDirty()
                }
            }
        }
    }

    private func rejectUnlock(_ message: String) {
        unlockError = message
        unlockShake &+= 1
    }

    func toggleMasterPasswordVisibility() {
        FocusManager.clear()
        showMasterPassword.toggle()
        masterPasswordFocused = true
    }

    func lock() {
        generation += 1
        clearClipboard()
        AttachmentFiles.clear()
        FocusManager.clear()
        masterPassword = ""; confirmation = ""; showMasterPassword = false; unlockError = nil
        draft = nil; showPassword = false; hideEntryPassword()
        snapshot = nil; entryDetails = nil; attachmentPendingRemoval = nil; selectedEntry = nil; selectedGroup = nil
        search = ""; searchFocused = false; rememberMaster = false
        groupName = nil; busy = false; confirmRecycle = false; notice = nil
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
        hideEntryPassword()
        selectedGroup = id; selectedEntry = nil; entryDetails = nil; attachmentPendingRemoval = nil; confirmRecycle = false; activity()
    }
    func selectEntry(_ id: UUID) {
        guard draft == nil else { notice = "Save or cancel the current entry first"; return }
        activity()
        guard selectedEntry != id || (entryDetails?.entry.id == id && entryDetails?.content == nil) else { return }
        hideEntryPassword()
        selectedEntry = id; attachmentPendingRemoval = nil
        confirmRecycle = false
        loadEntryContent()
    }
    private func loadEntryContent() {
        entryRequest &+= 1
        guard let entry = snapshot?.entries.first(where: { $0.id == selectedEntry }) else {
            entryDetails = nil
            return
        }
        // Keep presenting the previous entry until its replacement is ready.
        // The request number also distinguishes A → B → A and post-save reloads.
        let request = entryRequest
        let token = generation
        let worker = worker
        worker.queue.async { [weak self] in
            let content: VaultEntryContent?
            let errorMessage: String?
            do {
                guard let document = worker.document else { throw PassError.message("The vault is locked") }
                content = try document.entryContent(for: entry.id)
                errorMessage = nil
            } catch {
                content = nil
                errorMessage = error.localizedDescription
            }
            MainQueue.async { [weak self] in
                guard let self, self.generation == token, self.entryRequest == request,
                      self.selectedEntry == entry.id else { return }
                self.entryDetails = EntryDetails(entry: entry, content: content, request: request)
                if let errorMessage { self.notice = errorMessage }
                ViewInvalidation.markDirty()
            }
        }
    }

    func addAttachment() {
        guard writable, draft == nil, let id = actionableEntryID else { return }
        performDialog({ FileDialog.openFile(title: "Add Entry Attachment") }) { session, url in
            session.importAttachment(url, into: id)
        }
    }

    func importAttachment(_ url: URL) {
        guard writable, draft == nil, let id = actionableEntryID else { return }
        importAttachment(url, into: id)
    }

    private func importAttachment(_ url: URL, into id: UUID) {
        run { document in
            try document.importAttachment(entryID: id, from: url)
            return .saved(document.snapshot, id)
        }
    }

    func saveAttachment(_ attachment: VaultAttachment) {
        guard !busy, let id = actionableEntryID else { return }
        let name = VaultDocument.attachmentFilename(attachment.name)
        performDialog({ FileDialog.saveFile(title: "Save Attachment As", defaultName: name) }) { session, url in
            session.run { document in
                try document.exportAttachment(entryID: id, attachmentID: attachment.id, to: url)
                return .message("Attachment saved")
            }
        }
    }

    func openAttachment(_ attachment: VaultAttachment) {
        guard !busy, let id = actionableEntryID else { return }
        let target: URL
        do { target = try AttachmentFiles.temporaryURL(name: attachment.name) }
        catch { notice = "Could not create a private attachment copy"; return }
        run { document in
            try document.exportAttachment(entryID: id, attachmentID: attachment.id, to: target)
            return .opened(target)
        }
    }

    func removeAttachment() {
        guard writable, let id = actionableEntryID, let attachment = attachmentPendingRemoval else { return }
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
        hideEntryPassword()
        draft = CredentialDraft(groupID: group.id); showPassword = false; activity()
    }
    func editEntry() {
        guard writable, draft == nil, let id = actionableEntryID else { return }
        hideEntryPassword()
        run { doc in .draft(try doc.draft(for: id)) }
    }
    func saveEntry() {
        guard writable, let draft else { return }
        run(submittedDraft: draft) { doc in let id = try doc.save(draft); return .saved(doc.snapshot, id) }
    }
    func recycleEntry() {
        guard writable, let id = actionableEntryID else { return }
        hideEntryPassword()
        selectedEntry = nil
        entryDetails = nil
        run { doc in try doc.recycle(id); return .snapshot(doc.snapshot) }
    }
    func addGroup() {
        guard writable, let name = groupName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let parent = selectedGroup ?? snapshot?.groups.first?.id else { return }
        run { doc in try doc.addGroup(name: name, parent: parent); return .snapshot(doc.snapshot) }
    }
    func copyPassword() {
        guard !busy, let id = actionableEntryID else { return }
        run { doc in .password(try doc.password(for: id)) }
    }

    func hideEntryPassword() {
        revealRequest &+= 1
        revealedPassword = nil
    }

    func toggleEntryPassword() {
        guard let id = actionableEntryID, !busy else { return }
        if revealedPassword != nil { hideEntryPassword(); return }
        revealRequest &+= 1
        let request = revealRequest
        let token = generation
        let worker = worker
        activity()
        worker.queue.async { [weak self] in
            let password = try? worker.document?.password(for: id)
            MainQueue.async { [weak self] in
                guard let self, self.generation == token, self.revealRequest == request,
                      self.selectedEntry == id, self.draft == nil else { return }
                self.revealedPassword = password
                ViewInvalidation.markDirty()
            }
        }
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
        draft?.password = PasswordGenerator.generate(length: generatedLength, characters: generatedCharacters)
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
                        self.hideEntryPassword()
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
                        self.rememberVault(update.path)
                        self.attachmentPendingRemoval = nil
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
        showClipboardNotice("Copied · clears in 30 seconds", value: value)
    }

    func openWebsite(_ url: URL) {
        activity()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xdg-open", url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { notice = "Could not open the website" }
    }

    private func copySecret(_ value: String) {
        showClipboardNotice("Password copied · clears in 30 seconds", value: value)
    }

    private func showClipboardNotice(_ message: String, value: String) {
        PassClipboard.copy(value)
        clipboardNotice = message
        clipboardRequest &+= 1
        let token = clipboardRequest
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak self] in
            MainQueue.async { [weak self] in
                guard let self, self.clipboardRequest == token else { return }
                self.clipboardNotice = nil
            }
        }
    }

    func clearClipboard() {
        clipboardRequest &+= 1
        PassClipboard.clear()
        clipboardNotice = nil
    }

}

private enum PassError: Error, LocalizedError {
    case message(String)
    case noRememberedPassword

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        case .noRememberedPassword: "No master password is remembered for this vault."
        }
    }
}
