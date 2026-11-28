import Foundation
import LavaMenu

struct ExtensionCommand: Decodable, Sendable {
    enum Kind: String, Decodable { case command, selectionEdit, documentActions, markdownPreview, embeddedSurface }

    let id: String
    let title: String
    let kind: Kind
    let languages: [String]?
    let fileExtensions: [String]?
    /// `"Ctrl+Alt+J"`, as `KeyShortcut(label:)` reads it. Only for the kinds
    /// that are menu items — `command` and `selectionEdit`.
    let shortcut: String?

    /// Whether it is a row of the Extensions menu, and so of Alt+X.
    var isMenuCommand: Bool { kind == .command || kind == .selectionEdit }

    var keyShortcut: KeyShortcut? { shortcut.flatMap(KeyShortcut.init(label:)) }

    /// Whether it applies to a tab with no document — a preview or a
    /// terminal: only a command that names no language or file type, since
    /// one that does is about a kind of document.
    var appliesWithoutDocument: Bool {
        kind == .command && languages == nil && fileExtensions == nil
    }

    func matches(language: String, url: URL?) -> Bool {
        if languages == nil && fileExtensions == nil { return true }
        if languages?.contains(language) == true { return true }
        guard let suffix = url?.pathExtension.lowercased(), !suffix.isEmpty else { return false }
        return fileExtensions?.contains { $0.lowercased() == suffix } == true
    }
}

struct InstalledCommand: Sendable {
    let extensionID: String
    let library: URL
    let command: ExtensionCommand

    var menuID: String { "extensions.run.\(extensionID)/\(command.id)" }
}

private struct ExtensionManifest: Decodable {
    let schemaVersion: Int
    let id: String
    let library: String
    let commands: [ExtensionCommand]

    func validate(in bundle: URL) throws -> [InstalledCommand] {
        func identifier(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy {
                (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
            }
        }
        guard schemaVersion == 1, identifier(id), !library.contains("/"), library.hasSuffix(".so"),
              !commands.isEmpty, Set(commands.map(\.id)).count == commands.count,
              commands.allSatisfy({ identifier($0.id) && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw SelectionExtension.Failure(message: "Invalid extension ID, library, commands or schema version.") }
        for command in commands {
            guard let shortcut = command.shortcut else { continue }
            guard command.isMenuCommand else {
                throw SelectionExtension.Failure(message: "\(command.id): only command and selectionEdit take a shortcut.")
            }
            guard KeyShortcut(label: shortcut) != nil else {
                throw SelectionExtension.Failure(message: "\(command.id): cannot read the shortcut \"\(shortcut)\".")
            }
        }
        let url = bundle.appendingPathComponent(library)
        guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw SelectionExtension.Failure(message: "Expected a library file named \(library).")
        }
        return commands.map { InstalledCommand(extensionID: id, library: url, command: $0) }
    }
}

struct ExtensionCatalog {
    var commands: [InstalledCommand] = []
    var errors: [String] = []

    static func discover() -> Self {
        let files = FileManager.default
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
            .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? files.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        let directory = base.appendingPathComponent("lavaeditor/extensions")
        var catalog = Self()
        let bundles: [URL]
        do {
            bundles = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                    options: .skipsHiddenFiles)
        } catch CocoaError.fileReadNoSuchFile { return catalog }
        catch { catalog.errors.append(error.localizedDescription); return catalog }

        var installed = Set<String>()
        for bundle in bundles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifestURL = bundle.appendingPathComponent("extension.json")
            guard files.fileExists(atPath: manifestURL.path) else { continue }
            do {
                let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: manifestURL))
                let commands = try manifest.validate(in: bundle)
                guard installed.insert(manifest.id).inserted else {
                    throw SelectionExtension.Failure(message: "Duplicate extension ID \(manifest.id).")
                }
                catalog.commands.append(contentsOf: commands)
            } catch {
                catalog.errors.append("\(bundle.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return catalog
    }
}
