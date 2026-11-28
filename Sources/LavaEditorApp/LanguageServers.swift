import Foundation
import LavaEditorSettings
import LavaLSPCore
import LavaProjectCore
import LavaShell
import LavaText
import LavaUI
import Observation

/// The language servers LavaEditor runs, and what each has been told.
///
/// One `LSPClient` per server and root — sourcekit-lsp for one package,
/// clangd for one build — started the first time a document needs it and
/// kept until the session ends: a language server is slow to start and
/// slower to index, so stopping it when the last tab closes would be paid for
/// on the next tab. Documents are kept in step from `sync`, which the session
/// calls (debounced) whenever its documents change: open when a tab first
/// has text, change when its text differs from what the server last saw,
/// save when it stops being modified, close when the tab goes.
///
/// Main thread only. Client events arrive on the client's own queue and are
/// hopped here with `MainQueue`.
@Observable
final class LanguageServers {
    /// Published diagnostics, by file path. Observed, so a publish rebuilds
    /// the editor's decorations.
    private(set) var diagnostics: [String: [LSPDiagnostic]] = [:]
    /// Bumped when semantic tokens arrive. Observed, so a reply repaints.
    private(set) var semanticGeneration = 0

    /// Something worth saying once in the notice bar — a server that would
    /// not start, or one that died.
    @ObservationIgnored var report: (String) -> Void = { _ in }
    /// Asked for after a server lookup finishes, so the document it was for
    /// gets opened without waiting for an edit.
    @ObservationIgnored var requestSync: () -> Void = {}

    struct Key: Hashable {
        let name: String
        let root: String
    }

    final class Server {
        let client: LSPClient
        /// What the config says it serves — which files it can warm.
        let languages: Set<String>
        var capabilities: ServerCapabilities?
        var reportedFailure = false
        init(client: LSPClient, languages: Set<String>) {
            self.client = client
            self.languages = languages
        }
    }

    /// What one server has been told about one tab.
    struct Opened {
        let key: Key
        let uri: String
        let path: String
        var text: String
        var modified: Bool
    }

    @ObservationIgnored private var servers: [Key: Server] = [:]
    @ObservationIgnored private var opened: [Int: Opened] = [:]
    /// Tabs whose server is being looked up, and tabs no server wants. The
    /// second is forgotten when the settings change.
    @ObservationIgnored private var lookingUp: Set<Int> = []
    @ObservationIgnored private var unserved: Set<Int> = []
    /// The last semantic tokens per tab, and the text they now describe —
    /// shifted across edits made since the reply, until the next one.
    @ObservationIgnored private var semantic: [Int: Semantic] = [:]
    @ObservationIgnored private var semanticWanted: Set<Int> = []
    @ObservationIgnored private var semanticInFlight: Set<Int> = []
    @ObservationIgnored private var semanticUnsupported: Set<Key> = []
    /// Asks made again for a tab whose answer was empty or did not come —
    /// see `retrySemantic`. Cleared by an answer with tokens in it.
    @ObservationIgnored private var semanticRetries: [Int: Int] = [:]
    /// Bumped by each refresh a server sends, so a reply to a request made
    /// before it knows it is out of date even when the tab had no tokens to
    /// mark stale yet.
    @ObservationIgnored private var refreshes: [Key: Int] = [:]

    private struct Semantic {
        var text: String
        var tokens: [SemanticToken]
        /// The server's own data, unshifted, for the next delta request.
        var snapshot: SemanticTokensSnapshot?
        let encoding: PositionEncoding
        var highlights: SemanticHighlights?
        /// The server said to ask again. Still shown until the answer comes.
        var stale = false
        /// `tokens` are the server's answer for exactly `text` — not shifted
        /// across edits, not read from the cache — and so worth caching.
        var fresh = false
    }

    /// Last answers on disk, for the seconds a server takes to warm up.
    @ObservationIgnored private let tokenCache = SemanticTokenCache.standard
    /// Tabs whose cache entry has been looked for, so a miss is looked for
    /// once rather than on every sync.
    @ObservationIgnored private var cacheLooked: Set<Int> = []

    @ObservationIgnored private var positionsMemo: (id: Int, text: String, encoding: PositionEncoding, positions: DocumentPositions)?

    // MARK: Keeping servers in step

    func sync(
        _ documents: [EditorDocument], active: Int, configs: [LanguageServerConfig], workspaceRoot: URL?
    ) {
        var live = Set<Int>()
        warm.tabs = documents.compactMap { $0.url?.standardizedFileURL.path }
        if documents.contains(where: { document in
            opened[document.id].map { $0.text != document.text && !$0.text.isEmpty } ?? false
        }) {
            warm.lastActivity = Date()
        }
        for document in documents {
            guard document.isLoaded, document.loadError == nil, let url = document.url else { continue }
            let path = url.standardizedFileURL.path
            live.insert(document.id)
            if var open = opened[document.id] {
                guard open.path == path, let server = servers[open.key] else {
                    // Saved under another name: the server knows it by the old one.
                    close(document.id)
                    continue
                }
                if open.text != document.text {
                    server.client.didChange(uri: open.uri, text: document.text)
                    open.text = document.text
                }
                if open.modified, !document.isModified {
                    server.client.didSave(uri: open.uri)
                    // The answer for the unsaved text is now the answer for the file.
                    remember(document.id, open)
                }
                open.modified = document.isModified
                opened[document.id] = open
            } else if !lookingUp.contains(document.id), !unserved.contains(document.id) {
                attach(document, url: url, configs: configs, workspaceRoot: workspaceRoot)
            }
        }
        for id in opened.keys where !live.contains(id) { close(id) }
        lookingUp.formIntersection(live)
        unserved.formIntersection(live)
        semantic = semantic.filter { live.contains($0.key) }
        // Highlighting only for the tab in front: it is what is on screen,
        // and a server asked about every tab after each edit does the work
        // of all of them.
        if let open = opened[active],
           semantic[active] == nil || semantic[active]?.text != open.text || semantic[active]?.stale == true {
            if semantic[active] == nil, !open.text.isEmpty { lookInCache(active, open) }
            wantSemantic(active)
        }
    }

    // MARK: Semantic tokens

    /// Asks once typing has paused. A reply describes the text the server had
    /// when asked; edits since are shifted over until the next one.
    private func wantSemantic(_ id: Int) {
        guard !semanticWanted.contains(id), !semanticInFlight.contains(id) else { return }
        semanticWanted.insert(id)
        let owner = LanguageServersRef(self)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
            MainQueue.async { owner.servers?.requestSemantic(id) }
        }
    }

    private func requestSemantic(_ id: Int) {
        semanticWanted.remove(id)
        guard let open = opened[id], let server = servers[open.key],
              let capabilities = server.capabilities, capabilities.supportsSemanticTokensFull,
              !semanticUnsupported.contains(open.key), !semanticInFlight.contains(id) else { return }
        semanticInFlight.insert(id)
        let text = open.text
        let key = open.key
        let encoding = capabilities.positionEncoding
        let refresh = refreshes[key, default: 0]
        let owner = LanguageServersRef(self)
        server.client.semanticTokens(uri: open.uri, previous: semantic[id]?.snapshot) { result in
            MainQueue.async {
                owner.servers?.semanticArrived(
                    id, key: key, text: text, encoding: encoding, refresh: refresh, result: result
                )
            }
        }
    }

    private func semanticArrived(
        _ id: Int, key: Key, text: String, encoding: PositionEncoding, refresh: Int,
        result: Result<DecodedSemanticTokens?, LSPClientError>
    ) {
        semanticInFlight.remove(id)
        switch result {
        case .success(let decoded?):
            // Nothing at all for a file with text in it is a server that is
            // not ready, not a file with nothing to colour: sourcekit-lsp
            // answers that way until it has loaded the package's build
            // settings — seconds to a minute in — and does not send a
            // refresh once it has. Kept, and asked again.
            let early = decoded.tokens.isEmpty && !text.isEmpty
            if early, let shown = semantic[id], shown.text == text, !shown.tokens.isEmpty {
                // Cached tokens for this very text: better than nothing while
                // the server warms up. Kept, and asked again.
                semantic[id]?.stale = true
                semantic[id]?.snapshot = nil
            } else {
                semantic[id] = Semantic(text: text, tokens: decoded.tokens, snapshot: decoded.snapshot,
                                        encoding: encoding, highlights: nil, stale: early, fresh: !early)
                semanticGeneration &+= 1
            }
            if early {
                retrySemantic(id)
            } else {
                semanticRetries[id] = nil
                if let open = opened[id], open.text == text, !open.modified { remember(id, open) }
                // Past its warm-up: a server that answers a tab will answer
                // the files nobody has opened yet.
                if warm.answered.insert(key).inserted { scheduleWarm(after: 2) }
            }
        case .success(nil):
            retrySemantic(id)
        case .failure(.unsupported):
            semanticUnsupported.insert(key)
        case .failure:
            // A delta the server no longer has the base for, a timeout: the
            // next request asks for everything again.
            semantic[id]?.snapshot = nil
            retrySemantic(id)
        }
        if refreshes[key, default: 0] != refresh {
            // The server said its answers were out of date while this one was
            // on its way — before the tab had anything to mark stale.
            semantic[id]?.stale = true
            requestSync()
        }
        // Typed into while the server was answering.
        if let open = opened[id], open.text != text { wantSemantic(id) }
    }

    /// Reads the tab's last answer from the cache, off the main thread, and
    /// shows it if the server has not answered by the time it is read.
    private func lookInCache(_ id: Int, _ open: Opened) {
        guard !cacheLooked.contains(id) else { return }
        cacheLooked.insert(id)
        let cache = tokenCache
        let path = open.path, text = open.text, server = open.key.name
        let owner = LanguageServersRef(self)
        DispatchQueue.global(qos: .userInitiated).async {
            guard let entry = cache.load(path: path, text: text, server: server) else { return }
            MainQueue.async {
                guard let servers = owner.servers, servers.semantic[id] == nil,
                      servers.opened[id]?.text == text else { return }
                // Stale: the server is still asked, and its answer replaces this.
                servers.semantic[id] = Semantic(
                    text: text, tokens: entry.tokens, snapshot: nil, encoding: entry.encoding,
                    highlights: nil, stale: true
                )
                servers.semanticGeneration &+= 1
            }
        }
    }

    /// Writes the tab's tokens to the cache when they are the server's own
    /// answer for what is now on disk.
    private func remember(_ id: Int, _ open: Opened) {
        guard let state = semantic[id], state.fresh, state.text == open.text, !state.tokens.isEmpty else { return }
        let cache = tokenCache
        let path = open.path, server = open.key.name
        let text = state.text, encoding = state.encoding, tokens = state.tokens
        DispatchQueue.global(qos: .utility).async {
            cache.store(path: path, text: text, server: server, encoding: encoding, tokens: tokens)
        }
    }

    // MARK: Warming the cache

    /// Off with `editor.warmSemanticTokens: false`.
    @ObservationIgnored var warmEnabled = true

    /// Filling the token cache for files nobody has opened, so they open
    /// coloured too: one file at a time, through the server that would
    /// serve it, only while the editor is idle — nothing typed for a few
    /// seconds, nothing of the user's waiting on a server, no server busy
    /// with its own progress, not on battery — and only through servers
    /// that have already answered a tab, which is how a server's warm-up
    /// (sourcekit-lsp's empty answers) is told from a file with nothing in
    /// it. A file is opened, asked for, and closed again at once, so the
    /// server does not keep its AST. Files whose entry is current
    /// (`SemanticTokenCache.isCurrent`) cost a `stat` and one line of the
    /// entry, so a warm cache is checked in moments at every start.
    private struct Warmup {
        var queue: [String] = []
        var queued: Set<String> = []
        /// Server roots whose files have been listed.
        var listed: Set<String> = []
        /// The session's tabs, opened or not, which go first.
        var tabs: [String] = []
        var inFlight: String?
        var scheduled = false
        var lastActivity = Date.distantPast
        var answered: Set<Key> = []
        /// Servers a warm request crashed: left alone for the session, so
        /// warming never spends more than one of the client's restarts.
        var crashed: Set<Key> = []
        var progress: [Key: Set<String>] = [:]
        var battery: (checked: Date, onBattery: Bool)?
    }

    @ObservationIgnored private var warm = Warmup()

    /// Seconds without typing before warming resumes.
    private static let warmIdle: TimeInterval = 3
    /// Larger files are left until they are opened.
    private static let warmLargestFile = 2 << 20

    private func scheduleWarm(after seconds: Double = 0.2) {
        guard warmEnabled, !warm.scheduled else { return }
        warm.scheduled = true
        let owner = LanguageServersRef(self)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
            MainQueue.async { owner.servers?.warmStep() }
        }
    }

    private var warmIdleNow: Bool {
        guard Date().timeIntervalSince(warm.lastActivity) > Self.warmIdle,
              semanticWanted.isEmpty, semanticInFlight.isEmpty, lookingUp.isEmpty,
              warm.progress.values.allSatisfy(\.isEmpty) else { return false }
        if warm.battery.map({ Date().timeIntervalSince($0.checked) > 30 }) ?? true {
            warm.battery = (Date(), PowerSupply.read().map { !$0.pluggedIn } ?? false)
        }
        return warm.battery?.onBattery != true
    }

    private func warmStep() {
        warm.scheduled = false
        guard warmEnabled, warm.inFlight == nil else { return }
        guard warmIdleNow else { return scheduleWarm(after: 2) }
        for key in warm.answered where !warm.listed.contains(key.root) {
            warm.listed.insert(key.root)
            listForWarming(key.root)
        }
        while !warm.queue.isEmpty {
            let path = warm.queue.removeFirst()
            guard !opened.values.contains(where: { $0.path == path }),
                  let (key, language) = warmServer(for: path) else { continue }
            warm.inFlight = path
            let cache = tokenCache
            let owner = LanguageServersRef(self)
            DispatchQueue.global(qos: .utility).async {
                var read: String?
                if !cache.isCurrent(path: path, server: key.name),
                   let data = FileManager.default.contents(atPath: path), data.count <= Self.warmLargestFile {
                    read = String(data: data, encoding: .utf8)
                }
                let text = read
                MainQueue.async { owner.servers?.warmRequest(path, key: key, language: language, text: text) }
            }
            return
        }
    }

    /// The running server that would serve `path`, if it has answered a tab.
    private func warmServer(for path: String) -> (Key, String)? {
        guard let language = Self.languageID(for: URL(fileURLWithPath: path)) else { return nil }
        let key = servers.first { key, server in
            path.hasPrefix(key.root + "/") && server.languages.contains(language)
                && warm.answered.contains(key) && !warm.crashed.contains(key) && !semanticUnsupported.contains(key)
                && server.capabilities?.supportsSemanticTokensFull == true
        }?.key
        return key.map { ($0, language) }
    }

    private func listForWarming(_ root: String) {
        let tabs = warm.tabs.filter { $0.hasPrefix(root + "/") }
        let owner = LanguageServersRef(self)
        DispatchQueue.global(qos: .utility).async {
            let files = (ProjectFiles.list(root: URL(fileURLWithPath: root)) ?? [])
                .filter { Self.languageID(for: URL(fileURLWithPath: $0)) != nil }
            let ordered = SemanticTokenWarmup.order(files: files, tabs: tabs)
            MainQueue.async {
                guard let servers = owner.servers else { return }
                for path in ordered where servers.warm.queued.insert(path).inserted {
                    servers.warm.queue.append(path)
                }
                servers.scheduleWarm()
            }
        }
    }

    /// `text` is nil for a file whose entry is current, or that could not be
    /// read: nothing to ask.
    private func warmRequest(_ path: String, key: Key, language: String, text: String?) {
        guard let text else {
            warm.inFlight = nil
            return scheduleWarm(after: 0)
        }
        guard warmIdleNow, let server = servers[key], let capabilities = server.capabilities,
              !opened.values.contains(where: { $0.path == path }) else {
            // Busy again: put it back at the front for later.
            warm.inFlight = nil
            if servers[key] != nil, warm.queued.contains(path) { warm.queue.insert(path, at: 0) }
            return scheduleWarm(after: 2)
        }
        let uri = URL(fileURLWithPath: path).absoluteString
        let encoding = capabilities.positionEncoding
        server.client.didOpen(uri: uri, languageID: language, text: text)
        let owner = LanguageServersRef(self)
        server.client.semanticTokens(uri: uri) { result in
            MainQueue.async {
                owner.servers?.warmArrived(path, uri: uri, key: key, text: text, encoding: encoding, result: result)
            }
        }
    }

    private func warmArrived(
        _ path: String, uri: String, key: Key, text: String, encoding: PositionEncoding,
        result: Result<DecodedSemanticTokens?, LSPClientError>
    ) {
        warm.inFlight = nil
        // Unless a tab opened it meanwhile, which now owns the document.
        if let server = servers[key], !opened.values.contains(where: { $0.path == path }) {
            server.client.didClose(uri: uri)
        }
        let cache = tokenCache
        let name = key.name
        switch result {
        case .success(let decoded?) where !decoded.tokens.isEmpty:
            DispatchQueue.global(qos: .utility).async {
                cache.store(path: path, text: text, server: name, encoding: encoding, tokens: decoded.tokens)
            }
        case .failure(.serverExited), .failure(.timedOut):
            // Servers have bugs on particular files: sourcekit-lsp crashes on
            // some in this repository whether a tab or the warmer opens them.
            // A timeout is the same thing seen earlier — the server dying on
            // this file in the background — and whatever is asked next only
            // finds out; so both mean: not this file again until it changes,
            // and not this server again this session.
            DispatchQueue.global(qos: .utility).async { cache.quarantine(path: path, server: name) }
            warm.crashed.insert(key)
            report("\(name) failed on \(URL(fileURLWithPath: path).lastPathComponent) while caching colours in the background; "
                   + "it will not be asked about that file again until it changes.")
        default:
            break
        }
        scheduleWarm()
    }

    /// Asks again later, backing off, for a tab the server had nothing for
    /// yet. Through the sync, which asks only for the tab in front — one that
    /// is not is asked when it comes to the front, being stale or unanswered.
    private func retrySemantic(_ id: Int) {
        let attempt = semanticRetries[id, default: 0]
        let delays: [Double] = [1, 2, 4, 8, 16, 30]
        guard attempt < delays.count else { return }
        semanticRetries[id] = attempt + 1
        let owner = LanguageServersRef(self)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delays[attempt]) {
            MainQueue.async { owner.servers?.requestSync() }
        }
    }

    /// The tab's semantic highlighting for `text`, its current contents, with
    /// `style` deciding which palette entry each token type takes (nil leaves
    /// the lexer's colour).
    func highlights(
        for id: Int, text: String, style: (String, [String]) -> Int?
    ) -> SemanticHighlights? {
        _ = semanticGeneration
        guard var state = semantic[id] else { return nil }
        if state.text != text {
            // Which logical lines the edit replaced, and what they are now.
            var edited: (old: ClosedRange<Int>, newLast: Int)?
            if let change = IncrementalChange.between(state.text, and: text, encoding: state.encoding) {
                state.tokens = SemanticToken.shifting(state.tokens, for: change, encoding: state.encoding)
                let breaks = change.text.utf8.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
                let first = change.range.start.line
                edited = (first...change.range.end.line, first + breaks)
            }
            state.text = text
            state.fresh = false
            if let edited, let previous = state.highlights {
                // A keystroke converts the tokens on the lines it touched;
                // every other line's spans are columns in a line it did not
                // change, and only its number moves.
                let touched = edited.old.lowerBound...edited.newLast
                let positions = positions(for: id, text: text, encoding: state.encoding)
                let spans = Self.spans(state.tokens.filter { touched.contains($0.line) },
                                       positions: positions, style: style)
                state.highlights = previous.replacing(edited.old, newLast: edited.newLast, with: spans)
            } else {
                state.highlights = nil
            }
        }
        if state.highlights == nil {
            let positions = positions(for: id, text: text, encoding: state.encoding)
            state.highlights = SemanticHighlights(
                lines: Self.spans(state.tokens, positions: positions, style: style)
            )
        }
        semantic[id] = state
        return state.highlights
    }

    /// `tokens` as spans per line, in characters from each line's start.
    private static func spans(
        _ tokens: [SemanticToken], positions: DocumentPositions, style: (String, [String]) -> Int?
    ) -> [Int: [HighlightSpan]] {
        var lines: [Int: [HighlightSpan]] = [:]
        var lineStarts: [Int: Int] = [:]
        for token in tokens {
            guard let styleIndex = style(token.type, token.modifiers) else { continue }
            let lineStart: Int
            if let known = lineStarts[token.line] {
                lineStart = known
            } else if let found = positions.characterOffset(at: LSPPosition(line: token.line, character: 0)) {
                lineStart = found
                lineStarts[token.line] = found
            } else { continue }
            guard let lower = positions.characterOffset(at: token.range.start),
                  let upper = positions.characterOffset(at: token.range.end, roundingUp: true),
                  lower < upper else { continue }
            lines[token.line, default: []].append(
                HighlightSpan(range: (lower - lineStart)..<(upper - lineStart), styleIndex: styleIndex)
            )
        }
        return lines
    }

    /// Settings changed: tabs no server wanted may be wanted now. Servers
    /// already running keep the command they were started with.
    func settingsChanged() {
        unserved.removeAll()
    }

    private func attach(
        _ document: EditorDocument, url: URL, configs: [LanguageServerConfig], workspaceRoot: URL?
    ) {
        guard let language = Self.languageID(for: url),
              configs.contains(where: { $0.languages.contains(language) }) else {
            unserved.insert(document.id)
            return
        }
        lookingUp.insert(document.id)
        let id = document.id
        let file = url.standardizedFileURL
        let root = workspaceRoot ?? file.deletingLastPathComponent()
        let owner = LanguageServersRef(self)
        // `select` walks the disk for root markers, off the main thread.
        Task.detached {
            let match = await LanguageServerConfig.select(
                for: file, in: root, configs: configs, language: language
            )
            MainQueue.async {
                guard let servers = owner.servers else { return }
                servers.lookingUp.remove(id)
                guard let match else {
                    servers.unserved.insert(id)
                    return
                }
                servers.open(id, file: file, language: language, config: match.config, root: match.root)
            }
        }
    }

    private func open(_ id: Int, file: URL, language: String, config: LanguageServerConfig, root: URL) {
        let key = Key(name: config.name, root: root.standardizedFileURL.path)
        let server = servers[key] ?? start(config, root: root, key: key)
        // Opened with empty text and brought up to date by the sync it asks
        // for: the text here would be whatever it was before the lookup.
        let uri = file.absoluteString
        server.client.didOpen(uri: uri, languageID: language, text: "")
        opened[id] = Opened(key: key, uri: uri, path: file.path, text: "", modified: false)
        requestSync()
    }

    private func start(_ config: LanguageServerConfig, root: URL, key: Key) -> Server {
        let owner = LanguageServersRef(self)
        let client = LSPClient(
            config: config, root: root, restart: RestartPolicy(maxRetries: 3)
        ) { event in
            MainQueue.async { owner.servers?.handle(event, from: key) }
        }
        let server = Server(client: client, languages: Set(config.languages))
        servers[key] = server
        client.start()
        return server
    }

    private func close(_ id: Int) {
        guard let open = opened.removeValue(forKey: id) else { return }
        servers[open.key]?.client.didClose(uri: open.uri)
        diagnostics[open.path] = nil
        semantic[id] = nil
        semanticRetries[id] = nil
        cacheLooked.remove(id)
    }

    /// Shuts every server down — the session is ending or the folder changed.
    func stopAll() {
        for server in servers.values { server.client.stop() }
        servers.removeAll()
        opened.removeAll()
        lookingUp.removeAll()
        unserved.removeAll()
        diagnostics.removeAll()
        semantic.removeAll()
        semanticRetries.removeAll()
        cacheLooked.removeAll()
        warm = Warmup()
        refreshes.removeAll()
    }

    private func handle(_ event: LSPEvent, from key: Key) {
        guard let server = servers[key] else { return }
        switch event {
        case .ready(let capabilities):
            server.capabilities = capabilities
            server.reportedFailure = false
            // A restarted server has none of the results it handed out.
            for (id, open) in opened where open.key == key { semantic[id]?.snapshot = nil }
            requestSync()
        case .diagnostics(let published):
            guard let path = URL(string: published.uri)?.standardizedFileURL.path else { return }
            // Only for a file a tab has open. Warming the colour cache opens
            // files on the server for a moment too, and a server publishes
            // for those — clangd's report on a header nobody had open went
            // into the Problems list, and its empty one on the close took it
            // out again a moment later.
            guard opened.values.contains(where: { $0.path == path }) else { return }
            diagnostics[path] = published.diagnostics.isEmpty ? nil : published.diagnostics
        case .exited(let exit, let willRestart):
            server.capabilities = nil
            warm.answered.remove(key)
            warm.progress[key] = nil
            if !willRestart, !server.reportedFailure {
                server.reportedFailure = true
                report("\(key.name) stopped (\(exit)).")
            }
        case .failed(let error):
            if !server.reportedFailure {
                server.reportedFailure = true
                report("\(key.name): \(error)")
            }
        case .notification(method: "$/progress", let params):
            // A server busy with its own work — indexing, loading a package —
            // is left to it.
            let token = params?["token"].map { $0.string ?? $0.integer.map(String.init) ?? "" } ?? ""
            switch params?["value"]?["kind"]?.string {
            case "begin":
                warm.progress[key, default: []].insert(token)
            case "end":
                warm.progress[key]?.remove(token)
            default: break
            }
        case .notification:
            break
        case .refresh(.semanticTokens):
            refreshes[key, default: 0] += 1
            // Every tab this server colours is out of date. Only the one in
            // front is asked again now; the rest when they come to the front.
            for (id, open) in opened where open.key == key {
                semantic[id]?.snapshot = nil
                semantic[id]?.stale = true
            }
            requestSync()
        }
    }

    // MARK: Asking

    /// The server a tab is open with, once it has answered the handshake.
    func ready(_ id: Int) -> (client: LSPClient, uri: String, encoding: PositionEncoding)? {
        guard let open = opened[id], let server = servers[open.key],
              let capabilities = server.capabilities else { return nil }
        return (server.client, open.uri, capabilities.positionEncoding)
    }

    /// Converts between the editor's character offsets and a server's
    /// positions for one tab's text. Kept for the last text asked about: the
    /// line table is a pass over the whole buffer, and every frame that
    /// shows diagnostics asks again about the same text.
    func positions(for id: Int, text: String, encoding: PositionEncoding) -> DocumentPositions {
        if let memo = positionsMemo, memo.id == id, memo.encoding == encoding, memo.text == text {
            return memo.positions
        }
        let positions = DocumentPositions(text, encoding: encoding)
        positionsMemo = (id, text, encoding, positions)
        return positions
    }

    /// The language ID a server is asked about a file as. The extension is
    /// enough for the servers this knows; clangd decides C from C++ by its
    /// compile flags whatever a header is called.
    static func languageID(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "c": return "c"
        case "h", "hh", "hpp", "hxx", "cc", "cpp", "cxx", "c++", "ipp", "inl": return "cpp"
        case "m", "mm": return "objective-c"
        default: return nil
        }
    }
}

/// Only dereferenced on the main thread. A server's callbacks must not keep
/// the session alive.
private final class LanguageServersRef: @unchecked Sendable {
    weak var servers: LanguageServers?
    init(_ servers: LanguageServers) { self.servers = servers }
}

extension LanguageServerConfig {
    /// The enabled servers from the effective settings, in a stable order —
    /// the first whose languages match a file is the one that serves it.
    static func from(_ settings: EditorSettings) -> [LanguageServerConfig] {
        settings.servers.keys.sorted().compactMap { name in
            guard let server = settings.servers[name], server.enabled, !server.command.isEmpty else { return nil }
            return LanguageServerConfig(
                name: name, command: server.command, languages: server.languages,
                rootMarkers: server.rootMarkers,
                initializationOptions: server.initializationOptions.map(JSON.init),
                settings: server.settings.map(JSON.init)
            )
        }
    }
}

extension JSON {
    /// The settings file's JSON as the protocol's. Numbers there are kept as
    /// their source text, so a server is sent an integer where one was written.
    init(_ value: JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let bool): self = .bool(bool)
        case .string(let string): self = .string(string)
        case .number(let text): self = Int(text).map(JSON.integer) ?? .number(Double(text) ?? 0)
        case .array(let items): self = .array(items.map(JSON.init))
        case .object(let fields): self = .object(fields.mapValues(JSON.init))
        }
    }
}
