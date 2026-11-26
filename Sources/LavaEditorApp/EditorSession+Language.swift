import Foundation
import LavaLSPCore
import LavaUI

/// Language servers in the editor: documents kept in step, diagnostics as
/// decorations, Ctrl+click to the definition.
extension EditorSession {
    func startLanguageServers() {
        languageServers.report = { [weak self] message in self?.notice = message }
        languageServers.requestSync = { [weak self] in self?.scheduleLanguageSync() }
    }

    /// Debounced: `documents` changes on every keystroke, and a server needs
    /// the text when the typing pauses, not each version of it.
    func scheduleLanguageSync() {
        scheduleLineActionDiscovery()
        guard !languageSyncScheduled else { return }
        languageSyncScheduled = true
        let owner = LanguageSessionRef(self)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) {
            MainQueue.async { owner.session?.syncLanguageServers() }
        }
    }

    func syncLanguageServers() {
        languageSyncScheduled = false
        languageServers.warmEnabled = settingsFiles.effective.editor.warmSemanticTokens
        languageServers.sync(
            documents, active: active.id, configs: LanguageServerConfig.from(settingsFiles.effective),
            workspaceRoot: project?.tree.root
        )
    }

    /// The active document's diagnostics, as the editor draws them. Converted
    /// against the text as it is now: the server's ranges are for the version
    /// it last saw, which while typing is a keystroke or two behind.
    func languageDecorations() -> [EditorDecoration] {
        guard let url = active.url,
              let published = languageServers.diagnostics[url.standardizedFileURL.path],
              let server = languageServers.ready(active.id) else { return [] }
        let positions = languageServers.positions(for: active.id, text: active.text, encoding: server.encoding)
        let count = positions.characterCount
        return published.compactMap { diagnostic in
            guard var range = positions.characterRange(for: diagnostic.range) else { return nil }
            // A point — "missing ';' here" — still needs a character to sit under.
            if range.isEmpty {
                guard count > 0 else { return nil }
                let at = min(range.lowerBound, count - 1)
                range = at..<(at + 1)
            }
            let source = diagnostic.source.map { "\($0): " } ?? ""
            return EditorDecoration(
                range: range, severity: Self.severity(diagnostic.severity),
                message: source + diagnostic.message
            )
        }
    }

    /// The server's highlighting for the document in front, shifted to its
    /// current text.
    func languageHighlights() -> SemanticHighlights? {
        languageServers.highlights(for: active.id, text: active.text, style: Self.semanticStyle)
    }

    /// Which `HighlightName` a semantic token takes — see `Language.codeStyle`.
    /// Variables and operators keep the lexer's colour: a server colours
    /// nearly every identifier as one or the other, and painting them all
    /// would bury the ones that say something.
    static func semanticStyle(_ type: String, _ modifiers: [String]) -> Int? {
        let name: String
        switch type {
        case "namespace": name = "namespace"
        case "type", "class", "enum", "interface", "struct", "typeParameter", "protocol": name = "type"
        case "function": name = "function"
        case "method": name = "function.method"
        case "parameter": name = "variable.parameter"
        case "property", "enumMember", "event": name = "property"
        case "macro", "decorator", "keyword", "modifier": name = "keyword"
        case "string", "regexp": name = "string"
        case "comment": name = "comment"
        case "number": name = "number"
        default: return nil
        }
        return HighlightName.index(of: name)
    }

    private static func severity(_ severity: LavaLSPCore.DiagnosticSeverity?) -> LavaUI.DiagnosticSeverity {
        switch severity {
        case .error, nil: return .error
        case .warning: return .warning
        case .information: return .info
        case .hint: return .hint
        }
    }

    /// Ctrl+click on a word: its definition, from the document's language
    /// server, or — with no server, or none that knows — every place the word
    /// is written.
    func follow(at offset: Int) {
        // The server must have the text the offset is into.
        syncLanguageServers()
        guard let server = languageServers.ready(active.id) else {
            searchForWord(at: offset)
            return
        }
        let positions = languageServers.positions(for: active.id, text: active.text, encoding: server.encoding)
        guard let position = positions.position(atCharacterOffset: offset) else {
            searchForWord(at: offset)
            return
        }
        let owner = LanguageSessionRef(self)
        let from = active.id
        let encoding = server.encoding
        server.client.definition(uri: server.uri, at: position, timeout: 10) { result in
            MainQueue.async {
                guard let session = owner.session, session.active.id == from else { return }
                if case .success(let locations) = result, let first = locations.first {
                    session.goTo(first, encoding: encoding)
                } else {
                    session.searchForWord(at: offset)
                }
            }
        }
    }

    /// Opens a location a server named and selects its range.
    func goTo(_ location: LSPLocation, encoding: PositionEncoding) {
        guard let url = URL(string: location.uri), url.isFileURL else {
            notice = "Cannot open \(location.uri)"
            return
        }
        // A definition is somewhere to look, not something to keep: following
        // three of them should not leave three tabs.
        open([url.standardizedFileURL], mode: .preview)
        guard active.isLoaded, active.url?.standardizedFileURL == url.standardizedFileURL else { return }
        let positions = languageServers.positions(for: active.id, text: active.text, encoding: encoding)
        guard let range = positions.characterRange(for: location.range) else { return }
        select(range)
    }
}

/// Only dereferenced on the main thread.
final class LanguageSessionRef: @unchecked Sendable {
    weak var session: EditorSession?
    init(_ session: EditorSession) { self.session = session }
}
