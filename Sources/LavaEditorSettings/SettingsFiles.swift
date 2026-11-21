import Foundation

public struct EditorSettingsLoader {
    private var lastGood: [URL: SettingsDocument] = [:]

    public init() {}

    public mutating func load(user: URL, folder: URL?) -> (EditorSettings, [SettingsDiagnostic]) {
        var diagnostics: [SettingsDiagnostic] = []
        let userDocument = read(user, diagnostics: &diagnostics)
        let folderDocument = folder.flatMap { read($0, diagnostics: &diagnostics) }
        let settings = EditorSettings(user: userDocument, folder: folderDocument)
        return (settings, diagnostics + settings.diagnostics)
    }

    private mutating func read(_ file: URL, diagnostics: inout [SettingsDiagnostic]) -> SettingsDocument? {
        do {
            lastGood[file] = try SettingsDocument.read(at: file)
        } catch let diagnostic as SettingsDiagnostic {
            diagnostics.append(diagnostic)
        } catch {
            diagnostics.append(.init(
                severity: .error, location: .init(file: file, line: 1, column: 1),
                message: error.localizedDescription
            ))
        }
        return lastGood[file]
    }
}

public enum EditorToggle: String, CaseIterable, Sendable {
    case wordWrap, lineNumbers, highlightChangedLines

    public var path: [String] { ["editor", rawValue] }
    public var legacyKey: String { self == .wordWrap ? "wraps" : rawValue }

    public func value(in preferences: EditorPreferences) -> Bool {
        switch self {
        case .wordWrap: preferences.wordWrap
        case .lineNumbers: preferences.lineNumbers
        case .highlightChangedLines: preferences.highlightChangedLines
        }
    }
}

public enum UserSettingsFile {
    /// Re-reads the user file under a lock and rewrites it as sorted JSON.
    /// A settings write removes comments and rewrites formatting.
    public static func set(_ key: EditorToggle, to value: Bool, at userFile: URL) throws {
        try setEditorFields([key.rawValue: .bool(value)], at: userFile)
    }

    /// Update both preferences in one atomic write so the watcher sees a pair.
    public static func setFont(family: String, size: Int, at userFile: URL) throws {
        try setEditorFields(["fontFamily": .string(family), "fontSize": .number(String(size))], at: userFile)
    }

    private static func setEditorFields(_ updates: [String: JSONValue], at userFile: URL) throws {
        let directory = userFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockFile = userFile.appendingPathExtension("lock")
        let descriptor = open(lockFile.path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw currentPOSIXError() }
        }

        let document = try SettingsDocument.read(at: userFile)
        var fields = document?.value.object ?? [:]
        let group = "editor"
        var editor = fields[group]?.object ?? [:]
        if fields[group] != nil, fields[group]?.object == nil, let location = document?.location(at: [group]) {
            throw SettingsDiagnostic(severity: .error, location: location, message: "\(group) must be an object")
        }
        editor.merge(updates) { _, value in value }
        fields[group] = .object(editor)
        try encoded(.object(fields)).write(to: userFile, options: .atomic)
    }

    /// Reads legacy values only when the user file is absent.
    public static func migrate(at userFile: URL, legacyBool: (String) -> Bool?) throws {
        guard !FileManager.default.fileExists(atPath: userFile.path) else { return }
        var editor: [String: JSONValue] = [:]
        for key in EditorToggle.allCases {
            editor[key.rawValue] = legacyBool(key.legacyKey).map(JSONValue.bool)
        }
        guard !editor.isEmpty else { return }
        try createIfMissing(.object(["editor": .object(editor)]), at: userFile)
    }

    public static func createIfMissing(at file: URL) throws {
        try createIfMissing(.object([:]), at: file)
    }

    private static func createIfMissing(_ value: JSONValue, at file: URL) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: file.path) else { return }
        let directory = file.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try encoded(value).write(to: temporary, options: .withoutOverwriting)
        defer { try? manager.removeItem(at: temporary) }
        // Publish the complete file only if another process hasn't created it.
        if link(temporary.path, file.path) != 0, errno != EEXIST { throw currentPOSIXError() }
    }

    private static func encoded(_ value: JSONValue) throws -> Data {
        Data(try (value.formatted() + "\n").utf8)
    }

    private static func currentPOSIXError() -> POSIXError {
        .init(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
