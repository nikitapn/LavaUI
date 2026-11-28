import Foundation

public enum SettingsLayer: Equatable, Sendable {
    case defaults, user, folder
}

public struct SettingsOrigin: Equatable, Sendable {
    public let layer: SettingsLayer
    public let location: SettingsLocation?
}

public struct SettingsDiagnostic: Error, Equatable, Sendable, LocalizedError {
    public enum Severity: String, Sendable { case warning, error }

    public let severity: Severity
    public let location: SettingsLocation
    public let message: String

    public var errorDescription: String? { "\(location) — \(severity.rawValue): \(message)" }
}

public struct EditorIndentationPreferences: Equatable, Sendable {
    public let tabSize: Int
    public let insertSpaces: Bool
}

public struct EditorPreferences: Equatable, Sendable {
    public let fontFamily: String
    public let fontSize: Float
    public let lineHeight: Float
    public let wordWrap: Bool
    public let lineNumbers: Bool
    public let highlightChangedLines: Bool
    public let tabSize: Int
    public let insertSpaces: Bool
    /// Whether a file's own indentation outranks `tabSize`/`insertSpaces`.
    public let detectIndentation: Bool
    /// Whether idle time fills the semantic-token cache for files not yet
    /// opened, through the language servers already running.
    public let warmSemanticTokens: Bool
    public let languageIndentation: [String: EditorIndentationPreferences]

    public static let defaults = Self(
        fontFamily: "Noto Sans Mono", fontSize: 14, lineHeight: 1.5,
        wordWrap: false, lineNumbers: true, highlightChangedLines: true,
        tabSize: 4, insertSpaces: true, detectIndentation: true, warmSemanticTokens: true, languageIndentation: [:]
    )

    public func indentation(for language: String) -> EditorIndentationPreferences {
        languageIndentation[language] ?? .init(tabSize: tabSize, insertSpaces: insertSpaces)
    }

    fileprivate var fields: [String: JSONValue] {
        [
            "fontFamily": .string(fontFamily), "fontSize": .number(String(fontSize)),
            "lineHeight": .number(String(lineHeight)), "wordWrap": .bool(wordWrap),
            "lineNumbers": .bool(lineNumbers), "highlightChangedLines": .bool(highlightChangedLines),
            "tabSize": .number(String(tabSize)), "insertSpaces": .bool(insertSpaces),
            "detectIndentation": .bool(detectIndentation),
            "warmSemanticTokens": .bool(warmSemanticTokens),
            "languages": .object(languageIndentation.mapValues {
                .object(["tabSize": .number(String($0.tabSize)), "insertSpaces": .bool($0.insertSpaces)])
            }),
        ]
    }
}

public struct LanguageServerSettings: Equatable, Sendable {
    public let command: [String]
    public let languages: [String]
    public let rootMarkers: [String]
    public let enabled: Bool
    public let initializationOptions: JSONValue?
    public let settings: JSONValue?

    fileprivate init(
        command: [String] = [], languages: [String] = [], rootMarkers: [String] = [],
        enabled: Bool = true, initializationOptions: JSONValue? = nil, settings: JSONValue? = nil
    ) {
        self.command = command
        self.languages = languages
        self.rootMarkers = rootMarkers
        self.enabled = enabled
        self.initializationOptions = initializationOptions
        self.settings = settings
    }

    fileprivate static let defaults: [String: Self] = [
        // Both serve the C family. Which one takes a file is
        // `LanguageServerConfig.select`'s answer: clangd where a compile
        // database lists it, sourcekit-lsp inside a SwiftPM package — it
        // knows a C target's include paths, plain clangd does not.
        "sourcekit-lsp": .init(
            command: ["sourcekit-lsp"], languages: ["swift", "c", "cpp", "objective-c"],
            rootMarkers: ["Package.swift", ".git"]
        ),
        "clangd": .init(
            command: ["clangd"], languages: ["c", "cpp", "objective-c"],
            rootMarkers: ["compile_commands.json", "build/compile_commands.json", "compile_flags.txt", ".git"]
        ),
    ]

    fileprivate var fields: [String: JSONValue] {
        [
            "command": .array(command.map(JSONValue.string)),
            "languages": .array(languages.map(JSONValue.string)),
            "rootMarkers": .array(rootMarkers.map(JSONValue.string)),
            "enabled": .bool(enabled),
        ]
    }
}

public struct EditorSettings: Sendable {
    public let editor: EditorPreferences
    public let servers: [String: LanguageServerSettings]
    public let diagnostics: [SettingsDiagnostic]
    private let root: SettingNode

    /// The merged values after validation, including keys the editor doesn't recognize yet.
    public var value: JSONValue { root.value }

    public func origin(at path: [String]) -> SettingsOrigin? { root.node(at: path)?.origin }

    /// The configured origin before validation, useful when a bad value falls back.
    public func configuredOrigin(at path: [String]) -> SettingsOrigin? {
        configuredRoot.node(at: path)?.origin
    }

    public func folderOverride(for key: EditorToggle) -> SettingsLocation? {
        folderEditorOverride(for: key.rawValue)
    }

    public func folderEditorOverride(for key: String) -> SettingsLocation? {
        let editor = configuredRoot.node(at: ["editor"])
        // A malformed folder editor object can also shadow a user preference.
        let origin = configuredOrigin(at: ["editor", key]) ?? (editor?.object == nil ? editor?.origin : nil)
        return origin?.layer == .folder ? origin?.location : nil
    }

    private let configuredRoot: SettingNode

    public init(user: SettingsDocument? = nil, folder: SettingsDocument? = nil) {
        let defaults = SettingNode(.object([
            "editor": .object(EditorPreferences.defaults.fields),
            "lsp": .object(["servers": .object(LanguageServerSettings.defaults.mapValues { .object($0.fields) })]),
        ]), layer: .defaults)
        var root = defaults
        if let user { root = root.merging(SettingNode(user.value, layer: .user, document: user)) }
        var diagnostics: [SettingsDiagnostic] = []
        if let folder {
            let folder = SettingNode(folder.value, layer: .folder, document: folder)
            // Repair malformed trusted containers before folder options are applied.
            var trustedReader = SettingsValidator(root: root, defaults: defaults, diagnostics: [])
            trustedReader.checkObject(at: ["lsp"])
            trustedReader.checkObject(at: ["lsp", "servers"])
            for name in LanguageServerSettings.defaults.keys.sorted() {
                trustedReader.checkObject(at: ["lsp", "servers", name])
            }
            root = trustedReader.root
            diagnostics = trustedReader.diagnostics
            let trusted = root.node(at: ["lsp", "servers"])?.object ?? [:]
            root = root.merging(folder.restrictingFolderServers(trusted, diagnostics: &diagnostics))
        }
        configuredRoot = root

        var validator = SettingsValidator(root: root, defaults: defaults, diagnostics: diagnostics)
        editor = validator.readEditor()
        servers = validator.readServers()
        self.root = validator.root
        self.diagnostics = validator.diagnostics
    }
}

private struct SettingNode: Sendable {
    enum Contents: Sendable {
        case object([String: SettingNode])
        case array([SettingNode])
        case scalar(JSONValue)
    }

    var contents: Contents
    let origin: SettingsOrigin

    init(_ value: JSONValue, layer: SettingsLayer, document: SettingsDocument? = nil, path: [String] = []) {
        origin = .init(layer: layer, location: document?.location(at: path))
        switch value {
        case .object(let fields):
            var nodes: [String: SettingNode] = [:]
            for (key, child) in fields {
                nodes[key] = .init(child, layer: layer, document: document, path: path + [key])
            }
            contents = .object(nodes)
        case .array(let values):
            contents = .array(values.enumerated().map {
                .init($0.element, layer: layer, document: document, path: path + [String($0.offset)])
            })
        default: contents = .scalar(value)
        }
    }

    var value: JSONValue {
        switch contents {
        case .object(let fields): .object(fields.mapValues(\.value))
        case .array(let nodes): .array(nodes.map(\.value))
        case .scalar(let value): value
        }
    }

    var object: [String: SettingNode]? {
        if case .object(let fields) = contents { return fields }
        return nil
    }

    func node(at path: some Collection<String>) -> SettingNode? {
        guard let key = path.first else { return self }
        switch contents {
        case .object(let fields):
            return fields[key]?.node(at: path.dropFirst())
        case .array(let nodes):
            guard let index = Int(key), nodes.indices.contains(index) else { return nil }
            return nodes[index].node(at: path.dropFirst())
        case .scalar: return nil
        }
    }

    mutating func set(_ node: SettingNode, at path: ArraySlice<String>) {
        guard let key = path.first else { self = node; return }
        guard var fields = object else { return }
        if path.count == 1 {
            fields[key] = node
        } else {
            fields[key]?.set(node, at: path.dropFirst())
        }
        contents = .object(fields)
    }

    func merging(_ newer: Self) -> Self {
        guard let old = object, let new = newer.object else { return newer }
        var result = newer
        result.contents = .object(old.merging(new) { $0.merging($1) })
        return result
    }

    func restrictingFolderServers(
        _ trusted: [String: Self], diagnostics: inout [SettingsDiagnostic]
    ) -> Self {
        var result = self
        guard var fields = object, var lsp = fields.removeValue(forKey: "lsp") else { return self }
        if var lspFields = lsp.object {
            if var servers = lspFields.removeValue(forKey: "servers") {
                if var entries = servers.object {
                    for name in entries.keys.sorted() {
                        guard var entry = entries.removeValue(forKey: name) else { continue }
                        guard var options = entry.object else {
                            entry.report(.error, "lsp.servers.\(name) must be an object", to: &diagnostics)
                            continue
                        }
                        for key in options.keys.sorted() where !["enabled", "initializationOptions", "settings"].contains(key) {
                            options.removeValue(forKey: key)?.report(
                                .warning, "Folder setting lsp.servers.\(name).\(key) is ignored",
                                to: &diagnostics
                            )
                        }
                        guard trusted[name]?.object != nil else {
                            entry.report(
                                .warning, "Define language server '\(name)' in user settings first",
                                to: &diagnostics
                            )
                            continue
                        }
                        entry.contents = .object(options)
                        entries[name] = entry
                    }
                    servers.contents = .object(entries)
                    lspFields["servers"] = servers
                } else {
                    servers.report(.error, "lsp.servers must be an object", to: &diagnostics)
                }
            }
            lsp.contents = .object(lspFields)
            fields["lsp"] = lsp
        } else {
            lsp.report(.error, "lsp must be an object", to: &diagnostics)
        }
        result.contents = .object(fields)
        return result
    }

    func report(_ severity: SettingsDiagnostic.Severity, _ message: String, to diagnostics: inout [SettingsDiagnostic]) {
        guard let location = origin.location else { return }
        diagnostics.append(.init(severity: severity, location: location, message: message))
    }
}

private struct SettingsValidator {
    var root: SettingNode
    let defaults: SettingNode
    var diagnostics: [SettingsDiagnostic]

    mutating func readEditor() -> EditorPreferences {
        warnUnknown(at: [], known: ["editor", "lsp"])
        checkObject(at: ["editor"])
        warnUnknown(at: ["editor"], known: Set(EditorPreferences.defaults.fields.keys))
        func path(_ key: String) -> [String] { ["editor", key] }
        let fallback = EditorPreferences.defaults
        let tabSize = readTabSize(at: path("tabSize"), fallback: fallback.tabSize)
        let insertSpaces = read(path("insertSpaces"), "a Boolean", fallback: fallback.insertSpaces, Self.bool)
        return .init(
            fontFamily: read(path("fontFamily"), "a nonempty font family", fallback: fallback.fontFamily) {
                guard case .string(let family) = $0,
                      !family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !family.contains("\0") else { return nil }
                return family
            },
            fontSize: read(path("fontSize"), "a number from 1 to 256", fallback: fallback.fontSize) {
                Self.float($0, in: 1...256)
            },
            lineHeight: read(path("lineHeight"), "a number greater than 0 and at most 10", fallback: fallback.lineHeight) {
                guard let value = Self.float($0, in: 0...10), value > 0 else { return nil }
                return value
            },
            wordWrap: read(path("wordWrap"), "a Boolean", fallback: fallback.wordWrap, Self.bool),
            lineNumbers: read(path("lineNumbers"), "a Boolean", fallback: fallback.lineNumbers, Self.bool),
            highlightChangedLines: read(
                path("highlightChangedLines"), "a Boolean", fallback: fallback.highlightChangedLines, Self.bool
            ),
            tabSize: tabSize, insertSpaces: insertSpaces,
            detectIndentation: read(
                path("detectIndentation"), "a Boolean", fallback: fallback.detectIndentation, Self.bool
            ),
            warmSemanticTokens: read(
                path("warmSemanticTokens"), "a Boolean", fallback: fallback.warmSemanticTokens, Self.bool
            ),
            languageIndentation: readLanguageIndentation(tabSize: tabSize, insertSpaces: insertSpaces)
        )
    }

    private mutating func readLanguageIndentation(
        tabSize: Int, insertSpaces: Bool
    ) -> [String: EditorIndentationPreferences] {
        let path = ["editor", "languages"]
        guard checkObject(at: path), let languages = root.node(at: path)?.object else { return [:] }
        var result: [String: EditorIndentationPreferences] = [:]
        for language in languages.keys.sorted() {
            let entry = path + [language]
            guard checkObject(at: entry) else { continue }
            warnUnknown(at: entry, known: ["tabSize", "insertSpaces"])
            let sizePath = entry + ["tabSize"]
            let spacesPath = entry + ["insertSpaces"]
            let size = root.node(at: sizePath) == nil ? tabSize : readTabSize(at: sizePath, fallback: tabSize)
            let spaces = root.node(at: spacesPath) == nil ? insertSpaces : read(
                spacesPath, "a Boolean", fallback: insertSpaces, defaultValue: .bool(insertSpaces), Self.bool
            )
            result[language] = .init(tabSize: size, insertSpaces: spaces)
        }
        return result
    }

    private mutating func readTabSize(at path: [String], fallback: Int) -> Int {
        read(path, "an integer from 1 to 32", fallback: fallback, defaultValue: .number(String(fallback))) {
            guard case .number(let token) = $0, let value = Int(token), (1...32).contains(value) else { return nil }
            return value
        }
    }

    mutating func readServers() -> [String: LanguageServerSettings] {
        checkObject(at: ["lsp"])
        warnUnknown(at: ["lsp"], known: ["servers"])
        let path = ["lsp", "servers"]
        checkObject(at: path)
        let names = root.node(at: path)?.object?.keys.sorted() ?? []
        var servers: [String: LanguageServerSettings] = [:]
        for name in names {
            let server = path + [name]
            guard checkObject(at: server) else {
                // A malformed entry for a built-in server restores that definition.
                servers[name] = LanguageServerSettings.defaults[name]
                continue
            }
            let fallback = LanguageServerSettings.defaults[name] ?? .init()
            warnUnknown(at: server, known: Set(fallback.fields.keys).union(["initializationOptions", "settings"]))
            if fallback.command.isEmpty, let entry = root.node(at: server), entry.node(at: ["command"]) == nil {
                entry.report(.error, "\(server.joined(separator: ".")) needs a command", to: &diagnostics)
            }
            let command = read(
                server + ["command"], "a nonempty array of command strings", fallback: fallback.command,
                defaultValue: .array([])
            ) {
                guard let strings = Self.strings($0), let executable = strings.first,
                      !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      strings.allSatisfy({ !$0.contains("\0") }) else { return nil }
                return strings
            }
            servers[name] = .init(
                command: command,
                languages: read(server + ["languages"], "an array of strings", fallback: fallback.languages,
                                defaultValue: .array([]), Self.strings),
                rootMarkers: read(server + ["rootMarkers"], "an array of strings", fallback: fallback.rootMarkers,
                                  defaultValue: .array([]), Self.strings),
                enabled: read(server + ["enabled"], "a Boolean", fallback: fallback.enabled,
                              defaultValue: .bool(fallback.enabled), Self.bool),
                initializationOptions: root.node(at: server + ["initializationOptions"])?.value,
                settings: root.node(at: server + ["settings"])?.value
            )
        }
        return servers
    }

    @discardableResult
    mutating func checkObject(at path: [String]) -> Bool {
        guard let node = root.node(at: path) else {
            if let fallback = defaults.node(at: path) { root.set(fallback, at: path[...]) }
            return true
        }
        guard node.object == nil else { return true }
        invalid(node, at: path, expected: "an object", defaultValue: .object([:]))
        return false
    }

    private mutating func warnUnknown(at path: [String], known: Set<String>) {
        guard let fields = root.node(at: path)?.object else { return }
        for key in fields.keys.sorted() where !known.contains(key) {
            let name = (path + [key]).joined(separator: ".")
            fields[key]?.report(.warning, "Unknown setting \(name)", to: &diagnostics)
        }
    }

    private mutating func read<T>(
        _ path: [String], _ expected: String, fallback: T, defaultValue: JSONValue = .null,
        _ decode: (JSONValue) -> T?
    ) -> T {
        guard let node = root.node(at: path) else {
            root.set(defaults.node(at: path) ?? SettingNode(defaultValue, layer: .defaults), at: path[...])
            return fallback
        }
        if let value = decode(node.value) { return value }
        invalid(node, at: path, expected: expected, defaultValue: defaultValue)
        return fallback
    }

    private mutating func invalid(
        _ node: SettingNode, at path: [String], expected: String, defaultValue: JSONValue
    ) {
        node.report(.error, "\(path.joined(separator: ".")) must be \(expected)", to: &diagnostics)
        root.set(defaults.node(at: path) ?? SettingNode(defaultValue, layer: .defaults), at: path[...])
    }

    private static func bool(_ value: JSONValue) -> Bool? {
        if case .bool(let bool) = value { return bool }
        return nil
    }

    private static func float(_ value: JSONValue, in range: ClosedRange<Float>) -> Float? {
        guard case .number(let token) = value, let number = Float(token), range.contains(number) else { return nil }
        return number
    }

    private static func strings(_ value: JSONValue) -> [String]? {
        guard case .array(let values) = value else { return nil }
        let strings = values.compactMap { value -> String? in
            if case .string(let string) = value { return string }
            return nil
        }
        return strings.count == values.count ? strings : nil
    }
}
