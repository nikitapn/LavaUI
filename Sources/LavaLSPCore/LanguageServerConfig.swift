import Foundation

public struct LanguageServerConfig: Codable, Sendable, Equatable {
    public var name: String
    public var command: [String]
    public var languages: [String]
    public var rootMarkers: [String]
    public var initializationOptions: JSON?
    public var settings: JSON?

    public init(name: String, command: [String], languages: [String], rootMarkers: [String] = [],
                initializationOptions: JSON? = nil, settings: JSON? = nil) {
        self.name = name
        self.command = command
        self.languages = languages
        self.rootMarkers = rootMarkers
        self.initializationOptions = initializationOptions
        self.settings = settings
    }

    /// First matching language wins. Pass the editor's language ID when it differs from the extension.
    public static func select(for file: URL, in workspaceRoot: URL, configs: [Self],
                              language: String? = nil) async -> (config: Self, root: URL)? {
        await withCheckedContinuation { result in
            DispatchQueue.global(qos: .utility).async {
                result.resume(returning: match(file, workspaceRoot, configs, language))
            }
        }
    }

    private static func match(_ file: URL, _ workspaceRoot: URL, _ configs: [Self],
                              _ language: String?) -> (config: Self, root: URL)? {
        let language = (language ?? file.pathExtension).lowercased()
        guard let config = configs.first(where: { $0.languages.contains { $0.lowercased() == language } })
        else { return nil }
        var directory = file.standardizedFileURL.deletingLastPathComponent()
        while true {
            if config.rootMarkers.contains(where: {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            }) {
                return (config, directory)
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return (config, workspaceRoot)
    }
}
