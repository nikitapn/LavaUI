import Foundation

/// Small persistent cache for Spotify's read-only catalog responses.
///
/// The cover bytes themselves live in `CoverCache`. This cache keeps the JSON
/// that describes albums, artists, searches, and their poster URLs, so moving
/// back and forth through the catalog does not repeatedly hit the Web API.
enum CatalogCache {
    private static let lock = NSLock()
    private static let lifetime: TimeInterval = 60 * 60
    private static let maximumFiles = 512
    nonisolated(unsafe) private static var memory: [String: (Date, Data)] = [:]
    nonisolated(unsafe) private static var root: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("LavaSpotify/catalog", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static func value(for key: String, now: Date = Date()) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = memory[key], now.timeIntervalSince(cached.0) < lifetime {
            return cached.1
        }

        let url = fileURL(for: key)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              now.timeIntervalSince(modified) < lifetime,
              let data = try? Data(contentsOf: url), !data.isEmpty
        else {
            memory.removeValue(forKey: key)
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        memory[key] = (modified, data)
        return data
    }

    static func store(_ data: Data, for key: String, now: Date = Date()) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        memory[key] = (now, data)
        if memory.count > maximumFiles,
           let oldestKey = memory.min(by: { $0.value.0 < $1.value.0 })?.key
        {
            memory.removeValue(forKey: oldestKey)
        }
        let url = fileURL(for: key)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        pruneIfNeeded()
    }

    /// Query dictionaries have no stable iteration order, so sort them before
    /// deriving the cache key.
    static func key(path: String, query: [String: String]) -> String {
        let suffix = query.keys.sorted().map { "\($0)=\(query[$0]!)" }.joined(separator: "&")
        return suffix.isEmpty ? path : "\(path)?\(suffix)"
    }

    private static func fileURL(for key: String) -> URL {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return root.appendingPathComponent(String(format: "%016llx.json", hash))
    }

    private static func pruneIfNeeded() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(keys)
        ), files.count > maximumFiles else { return }
        let oldestFirst = files.sorted {
            let lhs = try? $0.resourceValues(forKeys: keys).contentModificationDate
            let rhs = try? $1.resourceValues(forKeys: keys).contentModificationDate
            return (lhs ?? .distantPast) < (rhs ?? .distantPast)
        }
        for file in oldestFirst.prefix(files.count - maximumFiles) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
