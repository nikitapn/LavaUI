import Foundation
import LavaExplorerCore
import LavaRemote
import LavaUI

/// A server asking for a password, as the login bar shows it.
struct RemoteLoginRequest: Equatable {
    var server: RemoteServer
    /// A password was tried and refused, rather than none given.
    var wrong: Bool
    /// Asked for only when the address named nobody.
    var user: String
    var password = ""
}

/// Rows from a server, dragged inside the window toward a local folder.
struct RemoteDrag: Equatable {
    var entries: [FileEntry]
    /// The pane they would go into if let go of now: a local one.
    var paneID: Int?
}

/// Servers: browsing one, logging in, and moving files to and from it.
///
/// A server's folder is the same tab, list and history as a local one —
/// `RemoteListingSource` makes it look like any other folder that is slow to
/// read. What differs is here: a password that may be needed, files that have
/// to be fetched before anything can open them, and drops that become uploads.
/// New Folder, Rename and Delete go to the server through the same draft row,
/// field and question bar as on the disk; extracting, compressing and the
/// Trash say they are not for servers (`refuseOnServer`) rather than reaching
/// for the local disk with a URL.
extension ExplorerSession {
    // MARK: - Listing

    /// How the remote source lists a folder: on a worker, as whoever this
    /// server is logged into as, with the keyring asked the first time.
    static func fetcher(
        connections: RemoteConnections, logins: RemoteLogins
    ) -> RemoteListingSource.Fetch {
        { url, done in
            DispatchQueue.global(qos: .userInitiated).async {
                let credentials = logins.credentials(for: url.server)
                do throws(RemoteError) {
                    let rows = try connections.list(url, as: credentials)
                    logins.succeeded(url.server)
                    done(.success(rows))
                } catch {
                    if error.kind == .login { logins.refused(url.server) }
                    done(.failure(error))
                }
            }
        }
    }

    var isOnServer: Bool { RemoteURL.isRemote(listing.path) }

    /// A server's folder arrived, or failed to.
    func remoteFolderChanged(_ path: String) {
        let source = self.source
        layout.updateTabs(showing: path) { $0.reload(from: source) }
        // A folder just made or a name just given, now that the listing
        // has it.
        if remote.failure(path) == nil, let pending = selectAfterFetch.removeValue(forKey: path),
           let paneID = layout.paneID(containingTab: pending.tabID)
        {
            layout.updatePane(id: paneID) { pane in
                pane.tabs.updateTab(id: pending.tabID) { $0.selected = pending.path }
            }
            if let index = layout.tab(id: pending.tabID)?.listing.entries
                .firstIndex(where: { $0.path == pending.path })
            {
                let row = FileListMetrics.rowHeight
                scrollPosition(for: pending.tabID).scroll(to: max(0, Float(index - 3) * row))
            }
        }
        let showing = layout.panes.contains { pane in
            pane.tabs.tabs.contains { $0.listing.path == path }
        }
        if let url = RemoteURL(path) {
            if let failure = remote.failure(path) {
                if failure.kind == .login, showing, remoteLogin == nil {
                    // Whatever has the keyboard gives it up, so the bar's
                    // field takes it. Otherwise the address bar, still focused
                    // from typing the address, got the password — and Enter
                    // went to a folder named after it, in the tab's title.
                    FocusManager.clear()
                    remoteLogin = RemoteLoginRequest(
                        server: url.server, wrong: logins.refusedAPassword(url.server),
                        user: url.server.user ?? ""
                    )
                }
            } else if showing {
                rememberServer(url.server)
            }
        }
        ViewInvalidation.markDirty()
    }

    /// Making folders, renaming, deleting: not on a server yet. Says so and
    /// returns true when `path` is on one.
    func refuseOnServer(_ path: String, _ what: String) -> Bool {
        guard let url = RemoteURL(path) else { return false }
        notice = "\(what) on \(url.server.host) is not supported yet"
        ViewInvalidation.markDirty()
        return true
    }

    // MARK: - Logging in

    var loginPassword: Binding<String> {
        Binding(
            get: { [unowned self] in remoteLogin?.password ?? "" },
            set: { [unowned self] in remoteLogin?.password = $0 }
        )
    }

    var loginUser: Binding<String> {
        Binding(
            get: { [unowned self] in remoteLogin?.user ?? "" },
            set: { [unowned self] in remoteLogin?.user = $0 }
        )
    }

    /// Log in with what was typed. A user typed for an address that named
    /// none becomes part of the address — of every tab on that server — so
    /// the password is filed under somebody.
    func submitLogin() {
        guard let request = remoteLogin, !request.password.isEmpty else { return }
        remoteLogin = nil
        FocusManager.clear()
        var server = request.server
        let typedUser = request.user.trimmingCharacters(in: .whitespaces)
        if server.user == nil, !typedUser.isEmpty {
            server.user = typedUser
            logins.remember(request.password, for: server)
            layout.rebaseTabs(
                from: request.server.prefix, to: server.prefix, source: source
            )
        } else {
            logins.remember(request.password, for: server)
        }
        retry(server)
    }

    func cancelLogin() {
        guard let request = remoteLogin else { return }
        remoteLogin = nil
        FocusManager.clear()
        notice = "Not connected to \(request.server.host)"
        ViewInvalidation.markDirty()
    }

    /// Everything on `server` fetched again, as whoever it is now logged in as.
    private func retry(_ server: RemoteServer) {
        remote.invalidate(server: server)
        let source = self.source
        layout.updateAllTabs { tab in
            if RemoteURL(tab.listing.path)?.server == server { tab.reload(from: source) }
        }
        ViewInvalidation.markDirty()
    }

    // MARK: - Connect to Server…

    /// Opens the bar with an address to finish typing.
    func startConnect() {
        dismissContext()
        FocusManager.clear()
        connectDraft = "sftp://"
        ViewInvalidation.markDirty()
    }

    var connectBinding: Binding<String> {
        Binding(
            get: { [unowned self] in connectDraft ?? "" },
            set: { [unowned self] in connectDraft = $0 }
        )
    }

    func submitConnect() {
        guard let draft = connectDraft else { return }
        guard RemoteURL(draft) != nil else {
            notice = "An address is sftp://, ftp:// or ftps://, then the server"
            ViewInvalidation.markDirty()
            return
        }
        connectDraft = nil
        FocusManager.clear()
        go(draft)
    }

    func cancelConnect() {
        connectDraft = nil
        FocusManager.clear()
        ViewInvalidation.markDirty()
    }

    /// Going to an address with a password in it uses the password and drops
    /// it from the address. Called by `go` before anything else sees it.
    func takePassword(from address: String) -> String {
        guard let (url, password) = RemoteURL.parse(address) else { return address }
        if let password { logins.remember(password, for: url.server) }
        return url.string
    }

    // MARK: - The sidebar's servers

    private static let serversKey = "remoteServers"

    static func loadServers() -> [RemoteURL] {
        (AppSettings.value(forKey: serversKey, as: [String].self) ?? []).compactMap(RemoteURL.init)
    }

    /// Where a server's row in the sidebar goes: its login folder.
    static func start(of server: RemoteServer) -> RemoteURL {
        RemoteURL(server: server, path: server.scheme == .sftp ? "/~" : "/")
    }

    /// A server that answered goes to the top of the sidebar. Eight at most:
    /// it is a list of where you have been lately, not a bookmark manager.
    func rememberServer(_ server: RemoteServer) {
        let start = Self.start(of: server)
        guard servers.first != start else { return }
        servers.removeAll { $0.server == server }
        servers.insert(start, at: 0)
        if servers.count > 8 { servers.removeLast(servers.count - 8) }
    }

    /// Off the sidebar, and its password out of the keyring.
    func forgetServer(_ url: RemoteURL) {
        servers.removeAll { $0.server == url.server }
        logins.refused(url.server)
        let server = url.server
        DispatchQueue.global(qos: .utility).async { RemoteKeyring.forget(server) }
        notice = "Forgot \(server.title)"
        ViewInvalidation.markDirty()
    }

    // MARK: - Transfers

    /// The user's Downloads, or home.
    static func downloadsFolder() -> String {
        let home = RemoteCache.home
        let places = Places.standard(home: home)
        return places.first { $0.title == "Downloads" }?.path ?? home
    }

    /// Fetches a server's file into the cache, then hands its local path to
    /// `then` — `xdg-open`, or an app from Open With.
    func openRemote(_ entry: FileEntry, then: @escaping @Sendable (String) -> Bool) {
        guard let url = RemoteURL(entry.path), !entry.isDirectory else { return }
        guard !transferRunning else {
            notice = "Still transferring — try again when it is done"
            ViewInvalidation.markDirty()
            return
        }
        let local = RemoteCache.path(for: url, cacheRoot: RemoteCache.root)
        let folder = (local as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // Into the cache's folder for this file: a second open replaces the
        // copy there, so what opens is always what the server has now.
        var plan = RemoteTransferPlan.download([entry], into: folder)
        plan.items = plan.items.map { var item = $0; item.clashes = false; return item }
        runTransfer(plan, choice: .replace) { [weak self] outcome in
            guard let self, outcome.done == 1 else { return }
            if !then(local) {
                self.notice = "Could not open \(entry.name)"
            }
        }
    }

    /// A server's rows into a local folder.
    func download(_ entries: [FileEntry], into folder: String) {
        let remoteRows = entries.filter { RemoteURL.isRemote($0.path) }
        guard !remoteRows.isEmpty else { return }
        start(RemoteTransferPlan.download(remoteRows, into: folder))
    }

    /// Local files into a server's folder. Names are checked against what the
    /// server last listed there — the listing on screen.
    func upload(_ paths: [String], into folder: RemoteURL) {
        let local = paths.filter { !RemoteURL.isRemote($0) }
        guard !local.isEmpty else {
            notice = "Copying from one server to another is not supported yet"
            ViewInvalidation.markDirty()
            return
        }
        let existing = remote.cached(folder.string) ?? []
        start(RemoteTransferPlan.upload(local, into: folder, existing: existing))
    }

    /// Asks about clashes first, if there are any.
    private func start(_ plan: RemoteTransferPlan) {
        guard !plan.items.isEmpty else { return }
        guard !transferRunning, pendingTransfer == nil else {
            notice = "Still transferring — try again when it is done"
            ViewInvalidation.markDirty()
            return
        }
        if plan.clashes.isEmpty {
            runTransfer(plan, choice: .skip)
        } else {
            pendingTransfer = plan
            ViewInvalidation.markDirty()
        }
    }

    /// The clash bar's answer; nil is Cancel.
    func resolveTransfer(_ choice: ClashChoice?) {
        guard let plan = pendingTransfer else { return }
        pendingTransfer = nil
        if let choice { runTransfer(plan, choice: choice) }
        ViewInvalidation.markDirty()
    }

    func cancelTransfer() {
        guard transferRunning else { return }
        transferCancel.cancel()
        notice = "Cancelling…"
        ViewInvalidation.markDirty()
    }

    private func runTransfer(
        _ plan: RemoteTransferPlan, choice: ClashChoice,
        then: (@Sendable (RemoteTransferOutcome) -> Void)? = nil
    ) {
        let cancel = CancelFlag()
        transferCancel = cancel
        transferRunning = true
        let verb: String
        switch plan.direction {
        case .upload: verb = "Uploading"
        case .download: verb = "Downloading"
        }
        let what = plan.items.count == 1
            ? "\u{201C}\(plan.items[0].name)\u{201D}" : Self.items(plan.items.count)
        notice = "\(verb) \(what)…"
        ViewInvalidation.markDirty()
        let connections = self.connections
        let logins = self.logins
        Thread.detachNewThread { [weak self] in
            // One notice per percent: a progress callback per buffer would be
            // a frame per few kilobytes.
            var shown = -1
            let outcome = RemoteTransfer.run(
                plan, clashes: choice, connections: connections, logins: logins,
                isCancelled: { cancel.isCancelled }
            ) { done, total, name in
                let percent = total > 0 ? Int(done * 100 / max(total, 1)) : -1
                guard percent != shown else { return }
                shown = percent
                let text = percent >= 0
                    ? "\(verb) \u{201C}\(name)\u{201D}… \(min(percent, 100))%"
                    : "\(verb) \u{201C}\(name)\u{201D}…"
                MainQueue.async { [weak self] in self?.showTransferProgress(text, cancel) }
            }
            MainQueue.async { [weak self] in
                self?.finishTransfer(plan, outcome, verb: verb)
                then?(outcome)
            }
        }
    }

    private func showTransferProgress(_ text: String, _ cancel: CancelFlag) {
        // Late percentages must not paint over the result or "Cancelling…".
        guard transferRunning, transferCancel === cancel, !cancel.isCancelled else { return }
        notice = text
        ViewInvalidation.markDirty()
    }

    private func finishTransfer(
        _ plan: RemoteTransferPlan, _ outcome: RemoteTransferOutcome, verb: String
    ) {
        transferRunning = false
        switch plan.direction {
        case .upload(let folder):
            remote.invalidate(folder.string)
            let source = self.source
            layout.updateTabs(showing: folder.string) { $0.reload(from: source) }
            if let server = outcome.error?.kind == .login ? folder.server : nil {
                logins.refused(server)
            }
        case .download(let folder):
            reloadAfterChange(in: [folder])
        }
        let title = plan.destinationTitle
        if outcome.cancelled {
            notice = "Cancelled"
        } else if let error = outcome.error {
            let server: RemoteServer? = switch plan.direction {
            case .upload(let folder): folder.server
            case .download: plan.items.first.flatMap { RemoteURL($0.source)?.server }
            }
            notice = server.map(error.describe) ?? error.message
        } else {
            let done = Self.items(outcome.done)
            notice = verb == "Uploading" ? "Uploaded \(done) to \(title)" : "Downloaded \(done) to \(title)"
            if outcome.skipped > 0 { notice! += "; skipped \(outcome.skipped)" }
        }
        ViewInvalidation.markDirty()
    }

    // MARK: - Dragging a server's rows

    /// The selection (or `entry`) dragged within the window. Let go of over a
    /// local pane, it is downloaded into that pane's folder.
    func dragRemote(_ entry: FileEntry, _ value: DragGestureValue) {
        switch value.phase {
        case .began:
            dismissContext()
            let selection = selectedEntries
            let entries = selection.contains(entry) ? selection : [entry]
            if !selection.contains(entry) {
                tabSet.updateCurrent { $0.selected = entry.path }
            }
            remoteDrag = RemoteDrag(entries: entries, paneID: localPane(at: value.x, value.y))
        case .changed:
            guard var drag = remoteDrag else { return }
            let pane = localPane(at: value.x, value.y)
            guard pane != drag.paneID else { return }
            drag.paneID = pane
            remoteDrag = drag
        case .ended:
            guard let drag = remoteDrag else { return }
            remoteDrag = nil
            if let paneID = drag.paneID, let pane = layout.pane(id: paneID) {
                download(drag.entries, into: pane.tabs.current.listing.path)
            }
            ViewInvalidation.markDirty()
        }
    }

    /// The pane under a point, if it shows a local folder — the only kind a
    /// server's rows can be let go of in.
    private func localPane(at x: Float, _ y: Float) -> Int? {
        for pane in layout.panes {
            guard let rect = paneFrames[pane.id],
                  x >= rect.x, x < rect.x + rect.w, y >= rect.y, y < rect.y + rect.h
            else { continue }
            let path = pane.tabs.current.listing.path
            return path.hasPrefix("/") ? pane.id : nil
        }
        return nil
    }

    // MARK: - Changing a server

    /// New Folder, on a server: the name checked against the listing on
    /// screen, the folder made on a worker, and selected once it is listed.
    func commitRemoteNewFolder(_ draft: NewFolderDraft) {
        guard let folder = RemoteURL(draft.directory) else { return }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        if let problem = NewFolder.problem(with: name) ?? Self.takenProblem(name, in: folder, session: self) {
            notice = problem
            ViewInvalidation.markDirty()
            return
        }
        let target = folder.appending(name)
        newFolderDraft = nil
        FocusManager.clear()
        let connections = self.connections
        let logins = self.logins
        runRemote("Creating \u{201C}\(name)\u{201D}…") { _ in
            do throws(RemoteError) {
                try connections.makeFolder(target, as: logins.credentials(for: folder.server))
                return nil
            } catch {
                return error
            }
        } done: { [weak self] error in
            guard let self else { return }
            self.changed(folder, select: target, in: draft.tabID)
            self.notice = error.map { "Could not create \u{201C}\(name)\u{201D}: \($0.message)" }
                ?? "Created \u{201C}\(name)\u{201D}"
        }
    }

    /// Rename, on a server. A tab open inside a renamed folder follows it,
    /// as on the disk. No undo: the history knows local paths only.
    func commitRemoteRename(_ draft: RenameDraft) {
        guard let item = RemoteURL(draft.path), let folder = item.parent else { return }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard name != item.name else {
            renameDraft = nil
            FocusManager.clear()
            ViewInvalidation.markDirty()
            return
        }
        if let problem = NewFolder.problem(with: name) ?? Self.takenProblem(name, in: folder, session: self) {
            // The field stays open with what was typed, to be fixed.
            notice = problem
            ViewInvalidation.markDirty()
            return
        }
        let target = folder.appending(name)
        renameDraft = nil
        FocusManager.clear()
        let connections = self.connections
        let logins = self.logins
        runRemote("Renaming \u{201C}\(item.name)\u{201D}…") { _ in
            do throws(RemoteError) {
                try connections.rename(item, to: name, as: logins.credentials(for: item.server))
                return nil
            } catch {
                return error
            }
        } done: { [weak self] error in
            guard let self else { return }
            if let error {
                self.changed(folder, select: nil, in: draft.tabID)
                self.notice = "Could not rename \u{201C}\(item.name)\u{201D}: \(error.message)"
                return
            }
            // Every tab inside it, and what they would go back to.
            self.layout.rebaseTabs(from: item.string, to: target.string, source: self.source)
            self.changed(folder, select: target, in: draft.tabID)
            self.notice = "Renamed to \u{201C}\(name)\u{201D}"
        }
    }

    /// Delete, on a server, once the bar has had its yes. Folders go whole;
    /// Cancel stops before the next item.
    func eraseRemote(_ entries: [FileEntry]) {
        let rows = entries.compactMap { entry in RemoteURL(entry.path).map { (entry, $0) } }
        guard let first = rows.first?.1 else { return }
        let named = rows.count == 1 ? "\u{201C}\(rows[0].0.name)\u{201D}" : Self.items(rows.count)
        let connections = self.connections
        let logins = self.logins
        runRemote("Deleting \(named)…") { cancel in
            let credentials = logins.credentials(for: first.server)
            for (entry, url) in rows {
                if cancel.isCancelled { return RemoteError(.cancelled, "Cancelled") }
                do throws(RemoteError) {
                    if entry.isDirectory, !entry.isSymlink {
                        try connections.removeFolder(url, as: credentials) { cancel.isCancelled }
                    } else {
                        try connections.removeFile(url, as: credentials)
                    }
                } catch {
                    return RemoteError(error.kind, "\(entry.name): \(error.message)")
                }
            }
            return nil
        } done: { [weak self] error in
            guard let self else { return }
            for folder in Set(rows.compactMap { $0.1.parent }) {
                self.changed(folder, select: nil, in: nil)
            }
            switch error?.kind {
            case nil: self.notice = "Deleted \(named)"
            case .cancelled?: self.notice = "Cancelled — some of it may be gone already"
            default: self.notice = "Could not delete \(error!.message)"
            }
        }
    }

    /// Why `name` cannot go into `folder`, from the listing on screen.
    private static func takenProblem(_ name: String, in folder: RemoteURL, session: ExplorerSession) -> String? {
        let names = Set((session.remote.cached(folder.string) ?? []).map(\.name))
        guard names.contains(name) else { return nil }
        return "\u{201C}\(name)\u{201D} is already in \(folder.name)"
    }

    /// `folder` is to be fetched again and every tab on it reloaded — the
    /// new listing then selects `select`, if given.
    private func changed(_ folder: RemoteURL, select: RemoteURL?, in tabID: Int?) {
        if let select, let tabID {
            selectAfterFetch[folder.string] = (tabID, select.string)
        }
        remote.invalidate(folder.string)
        let source = self.source
        layout.updateTabs(showing: folder.string) { $0.reload(from: source) }
        ViewInvalidation.markDirty()
    }

    /// One change to a server, on a worker, with the status line's Cancel —
    /// shared with transfers, so a delete cannot start under an upload into
    /// the same folder. `work` returns what stopped it, if anything.
    private func runRemote(
        _ text: String,
        work: @escaping @Sendable (CancelFlag) -> RemoteError?,
        done: @escaping @Sendable (RemoteError?) -> Void
    ) {
        guard !transferRunning else {
            notice = "Still busy on the server — try again when it is done"
            ViewInvalidation.markDirty()
            return
        }
        let cancel = CancelFlag()
        transferCancel = cancel
        transferRunning = true
        notice = text
        ViewInvalidation.markDirty()
        Thread.detachNewThread { [weak self] in
            let error = work(cancel)
            MainQueue.async { [weak self] in
                guard let self else { return }
                self.transferRunning = false
                if error?.kind == .login, let server = RemoteURL(self.listing.path)?.server {
                    self.logins.refused(server)
                }
                done(error)
                ViewInvalidation.markDirty()
            }
        }
    }
}
