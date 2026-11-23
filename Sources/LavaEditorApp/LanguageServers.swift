import Foundation
import LavaEditorSettings
import LavaLSPCore
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
        var capabilities: ServerCapabilities?
        var reportedFailure = false
        init(client: LSPClient) { self.client = client }
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

    private struct Semantic {
        var text: String
        var tokens: [SemanticToken]
        /// The server's own data, unshifted, for the next delta request.
        var snapshot: SemanticTokensSnapshot?
        let encoding: PositionEncoding
        var highlights: SemanticHighlights?
        /// The server said to ask again. Still shown until the answer comes.
        var stale = false
    }

    @ObservationIgnored private var positionsMemo: (id: Int, text: String, encoding: PositionEncoding, positions: DocumentPositions)?

    // MARK: Keeping servers in step

    func sync(
        _ documents: [EditorDocument], active: Int, configs: [LanguageServerConfig], workspaceRoot: URL?
    ) {
        var live = Set<Int>()
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
                if open.modified, !document.isModified { server.client.didSave(uri: open.uri) }
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
        let owner = LanguageServersRef(self)
        server.client.semanticTokens(uri: open.uri, previous: semantic[id]?.snapshot) { result in
            MainQueue.async {
                owner.servers?.semanticArrived(id, key: key, text: text, encoding: encoding, result: result)
            }
        }
    }

    private func semanticArrived(
        _ id: Int, key: Key, text: String, encoding: PositionEncoding,
        result: Result<DecodedSemanticTokens?, LSPClientError>
    ) {
        semanticInFlight.remove(id)
        switch result {
        case .success(let decoded?):
            semantic[id] = Semantic(text: text, tokens: decoded.tokens, snapshot: decoded.snapshot,
                                    encoding: encoding, highlights: nil)
            semanticGeneration &+= 1
        case .success(nil):
            break
        case .failure(.unsupported):
            semanticUnsupported.insert(key)
        case .failure:
            // A delta the server no longer has the base for, a timeout: the
            // next request asks for everything again.
            semantic[id]?.snapshot = nil
        }
        // Typed into while the server was answering.
        if let open = opened[id], open.text != text { wantSemantic(id) }
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
        let server = Server(client: client)
        servers[key] = server
        client.start()
        return server
    }

    private func close(_ id: Int) {
        guard let open = opened.removeValue(forKey: id) else { return }
        servers[open.key]?.client.didClose(uri: open.uri)
        diagnostics[open.path] = nil
        semantic[id] = nil
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
            diagnostics[path] = published.diagnostics.isEmpty ? nil : published.diagnostics
        case .exited(let exit, let willRestart):
            server.capabilities = nil
            if !willRestart, !server.reportedFailure {
                server.reportedFailure = true
                report("\(key.name) stopped (\(exit)).")
            }
        case .failed(let error):
            if !server.reportedFailure {
                server.reportedFailure = true
                report("\(key.name): \(error)")
            }
        case .notification:
            break
        case .refresh(.semanticTokens):
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
