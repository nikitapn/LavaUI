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
///
/// Its first line is a header on its own, with the source file's size and
/// modification time as they were when the tokens were written — enough for
/// `isCurrent` to tell, for a whole project, which entries are missing or
/// out of date by reading one line of each and nothing of the sources.
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
              let newline = data.firstIndex(of: 0x0a),
              let header = try? JSONDecoder().decode(Header.self, from: data[..<newline]),
              header.version == Header.currentVersion, header.path == path, header.server == server,
              header.length == text.utf8.count, header.hash == Self.hash(text),
              let stored = try? JSONDecoder().decode(Stored.self, from: data[(newline + 1)...]),
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

    /// Whether `server`'s entry for `path` was written for the file as it is
    /// on disk now, judged by its size and modification time — the one line
    /// of the entry, and a `stat` of the source.
    public func isCurrent(path: String, server: String) -> Bool {
        guard let source = Self.sourceStamp(path), let header = readHeader(path) else { return false }
        return header.version == Header.currentVersion && header.path == path && header.server == server
            && header.sourceSize == source.size && header.sourceModified == source.modified
    }

    /// Records that asking `server` about `path`, as it is on disk now, went
    /// wrong — it crashed the server or never answered — so that filling the
    /// cache in the background does not ask again, this session or the next,
    /// until the file changes. `isCurrent` is true for it; `load` finds
    /// nothing. A file the user opens is still asked: this is only for
    /// asking unprompted.
    public func quarantine(path: String, server: String) {
        guard let stamp = Self.sourceStamp(path) else { return }
        let header = Header(
            version: Header.currentVersion, path: path, server: server, length: stamp.size, hash: "",
            sourceSize: stamp.size, sourceModified: stamp.modified, quarantined: true
        )
        guard let head = try? JSONEncoder().encode(header) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (head + Data([0x0a])).write(to: file(for: path), options: .atomic)
        } catch {
            return
        }
    }

    /// Whether `path` is quarantined for `server` as the file is now.
    public func isQuarantined(path: String, server: String) -> Bool {
        isCurrent(path: path, server: server) && readHeader(path)?.quarantined == true
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
        // The source's stamp only when it is the text being recorded: a
        // buffer with unsaved edits is not what is on disk.
        let stamp = Self.sourceStamp(path).flatMap { $0.size == text.utf8.count ? $0 : nil }
        let header = Header(
            version: Header.currentVersion, path: path, server: server, length: text.utf8.count,
            hash: Self.hash(text), sourceSize: stamp?.size, sourceModified: stamp?.modified
        )
        let stored = Stored(encoding: encoding, types: types, modifiers: modifiers, data: data)
        guard let head = try? JSONEncoder().encode(header), let body = try? JSONEncoder().encode(stored) else { return }
        let encoded = head + Data([0x0a]) + body
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

    private func readHeader(_ path: String) -> Header? {
        guard let handle = FileHandle(forReadingAtPath: file(for: path).path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16 * 1024),
              let newline = head.firstIndex(of: 0x0a) else { return nil }
        return try? JSONDecoder().decode(Header.self, from: head[..<newline])
    }

    private static func sourceStamp(_ path: String) -> (size: Int, modified: Double)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return (size, modified.timeIntervalSince1970)
    }

    /// The first line: what the entry is for.
    private struct Header: Codable {
        static let currentVersion = 2
        let version: Int
        let path: String
        let server: String
        let length: Int
        let hash: String
        /// The source as it was when written, if the text was what it held.
        let sourceSize: Int?
        let sourceModified: Double?
        /// Asking about this file went wrong; see `quarantine`.
        var quarantined: Bool? = nil
    }

    /// The second: the tokens. Positions absolute rather than delta-encoded,
    /// so an entry can be read without the server's legend; types and
    /// modifiers are this entry's own tables.
    private struct Stored: Codable {
        let encoding: PositionEncoding
        let types: [String]
        let modifiers: [String]
        let data: [Int]
    }
}
