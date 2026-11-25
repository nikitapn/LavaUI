import Foundation

/// A language server's last semantic tokens per file, kept on disk, so a file
/// opened again is coloured the moment it is shown rather than when the
/// server has warmed up — 4 to 8 seconds for sourcekit-lsp on a package,
/// 4 to 5 for clangd, both measured on this repository. The server's own
/// caches do not cover this: clangd's `.cache/clangd` is a symbol index, and
/// both rebuild a file's AST on every start before they can colour it.
///
/// An entry is used only for **exactly the text it was made from** (its
/// length and a hash of its bytes) and the server that made it. It is a
/// stand-in until the server answers, and can be a little off where the
/// colouring depended on other files that have changed since — a name that
/// became a type elsewhere — for those seconds.
///
/// One small file per source file, written atomically, so two editors racing
/// to write one leave one whole entry; anything unreadable is a miss. The
/// directory keeps the `maximumEntries` most recently written.
public struct SemanticTokenCache: Sendable {
    public let directory: URL
    public let maximumEntries: Int

    public init(directory: URL, maximumEntries: Int = 2000) {
        self.directory = directory
        self.maximumEntries = maximumEntries
    }

    /// `$XDG_CACHE_HOME/lavaeditor/semantic-tokens`, else `~/.cache/…`.
    public static var standard: SemanticTokenCache {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return SemanticTokenCache(directory: base.appendingPathComponent("lavaeditor/semantic-tokens"))
    }

    public struct Entry: Sendable, Equatable {
        public let encoding: PositionEncoding
        public let tokens: [SemanticToken]
    }

    /// The tokens `server` gave for `text` at `path`, if they are on disk.
    public func load(path: String, text: String, server: String) -> Entry? {
        guard let data = try? Data(contentsOf: file(for: path)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == Stored.currentVersion, stored.path == path, stored.server == server,
              stored.length == text.utf8.count, stored.hash == Self.hash(text),
              stored.data.count.isMultiple(of: 5)
        else { return nil }
        var tokens: [SemanticToken] = []
        tokens.reserveCapacity(stored.data.count / 5)
        for index in stride(from: 0, to: stored.data.count, by: 5) {
            let type = stored.data[index + 3], bits = stored.data[index + 4]
            guard stored.types.indices.contains(type), stored.data[index + 2] > 0 else { return nil }
            let modifiers = stored.modifiers.indices.filter { bits & (1 << $0) != 0 }.map { stored.modifiers[$0] }
            tokens.append(SemanticToken(
                line: stored.data[index], start: stored.data[index + 1], length: stored.data[index + 2],
                type: stored.types[type], modifiers: modifiers
            ))
        }
        return Entry(encoding: stored.encoding, tokens: tokens)
    }

    /// Records `tokens` as what `server` gave for `text` at `path`.
    /// Failures are silent: a cache that cannot be written is a slower
    /// start, not an error worth a notice.
    public func store(
        path: String, text: String, server: String, encoding: PositionEncoding, tokens: [SemanticToken]
    ) {
        var types: [String] = []
        var typeIndex: [String: Int] = [:]
        var modifiers: [String] = []
        var modifierIndex: [String: Int] = [:]
        var data: [Int] = []
        data.reserveCapacity(tokens.count * 5)
        for token in tokens {
            let type = typeIndex[token.type] ?? {
                types.append(token.type)
                typeIndex[token.type] = types.count - 1
                return types.count - 1
            }()
            var bits = 0
            for modifier in token.modifiers {
                let index = modifierIndex[modifier] ?? {
                    modifiers.append(modifier)
                    modifierIndex[modifier] = modifiers.count - 1
                    return modifiers.count - 1
                }()
                if index < Int.bitWidth - 1 { bits |= 1 << index }
            }
            data += [token.line, token.start, token.length, type, bits]
        }
        let stored = Stored(
            version: Stored.currentVersion, path: path, server: server, length: text.utf8.count,
            hash: Self.hash(text), encoding: encoding, types: types, modifiers: modifiers, data: data
        )
        guard let encoded = try? JSONEncoder().encode(stored) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoded.write(to: file(for: path), options: .atomic)
        } catch {
            return
        }
        prune()
    }

    /// Down to `maximumEntries`, oldest written first.
    func prune() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)
        ), files.count > maximumEntries else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - maximumEntries) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func file(for path: String) -> URL {
        directory.appendingPathComponent(Self.hash(path) + ".json")
    }

    /// FNV-1a, 64 bits: a cache key, not a defence — `path` and `length`
    /// are checked alongside it.
    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value &*= 0x0000_0100_0000_01b3
        }
        return String(value, radix: 16)
    }

    /// Positions absolute rather than delta-encoded, so an entry can be read
    /// without the server's legend. Types and modifiers are this entry's own
    /// tables.
    private struct Stored: Codable {
        static let currentVersion = 1
        let version: Int
        let path: String
        let server: String
        let length: Int
        let hash: String
        let encoding: PositionEncoding
        let types: [String]
        let modifiers: [String]
        let data: [Int]
    }
}
