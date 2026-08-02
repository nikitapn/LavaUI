import Foundation

/// Cross-platform, file-backed key/value settings for LavaUI apps.
///
/// One JSON file per app under the platform config directory:
///
/// | Platform | Location |
/// | --- | --- |
/// | Linux | `~/.config/<AppName>/settings.json` (or `$XDG_CONFIG_HOME`) |
/// | macOS | `~/Library/Application Support/<AppName>/settings.json` |
/// | fallback | temp dir / `<AppName>/settings.json` |
///
/// Call `configure(appName:)` once at process start (before the first get/set),
/// typically next to `LavaApp.open`. Keys are plain strings; values are JSON
/// scalars or anything `Codable`. Writes are atomic and locked.
///
/// ```swift
/// AppSettings.configure(appName: "LavaSpotify")
/// AppSettings.set("midnight-groove", forKey: "theme.id")
/// let id = AppSettings.string(forKey: "theme.id")
/// ```
///
/// Not a replacement for secrets that need tighter permissioning — OAuth tokens
/// should stay in their own 0600 file — but fine for theme, window layout, and
/// other non-sensitive preferences.
public enum AppSettings {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var appName = "LavaUI"
    nonisolated(unsafe) private static var cache: [String: Any] = [:]
    nonisolated(unsafe) private static var loaded = false

    // MARK: - Setup

    /// Sets the product name used for the config directory. Safe to call more
    /// than once; reloads from the new path.
    public static func configure(appName: String) {
        let cleaned = sanitize(appName)
        lock.lock()
        defer { lock.unlock() }
        guard cleaned != self.appName || !loaded else { return }
        self.appName = cleaned
        loaded = false
        cache = [:]
    }

    /// Directory that holds `settings.json` (created on first write).
    public static var directoryURL: URL {
        lock.lock()
        let name = appName
        lock.unlock()
        return configRoot(for: name)
    }

    public static var fileURL: URL {
        directoryURL.appendingPathComponent("settings.json")
    }

    // MARK: - Scalars

    public static func string(forKey key: String) -> String? {
        value(forKey: key) as? String
    }

    public static func set(_ value: String, forKey key: String) {
        setValue(value, forKey: key)
    }

    public static func int(forKey key: String) -> Int? {
        switch value(forKey: key) {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        case let d as Double: return Int(d)
        case let s as String: return Int(s)
        default: return nil
        }
    }

    public static func set(_ value: Int, forKey key: String) {
        setValue(value, forKey: key)
    }

    public static func bool(forKey key: String) -> Bool? {
        switch value(forKey: key) {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        default: return nil
        }
    }

    public static func set(_ value: Bool, forKey key: String) {
        setValue(value, forKey: key)
    }

    public static func double(forKey key: String) -> Double? {
        switch value(forKey: key) {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    public static func set(_ value: Double, forKey key: String) {
        setValue(value, forKey: key)
    }

    // MARK: - Codable

    public static func value<T: Decodable>(forKey key: String, as type: T.Type) -> T? {
        lock.lock()
        ensureLoadedLocked()
        let raw = cache[key]
        lock.unlock()
        guard let raw else { return nil }
        if let already = raw as? T { return already }
        guard JSONSerialization.isValidJSONObject(boxed(raw)),
              let data = try? JSONSerialization.data(withJSONObject: boxed(raw))
        else {
            // Scalars: encode as a single JSON value.
            if let data = try? JSONSerialization.data(withJSONObject: [raw]),
               let arr = try? JSONDecoder().decode([T].self, from: data)
            {
                return arr.first
            }
            // Or a JSON string / number fragment via Codable container.
            return decodeScalar(raw, as: type)
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public static func set<T: Encodable>(_ value: T, forKey key: String) {
        if let s = value as? String {
            setValue(s, forKey: key)
            return
        }
        if let i = value as? Int {
            setValue(i, forKey: key)
            return
        }
        if let b = value as? Bool {
            setValue(b, forKey: key)
            return
        }
        if let d = value as? Double {
            setValue(d, forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return }
        setValue(obj, forKey: key)
    }

    // MARK: - Bookkeeping

    public static func remove(_ key: String) {
        lock.lock()
        ensureLoadedLocked()
        cache.removeValue(forKey: key)
        persistLocked()
        lock.unlock()
    }

    public static func removeAll() {
        lock.lock()
        ensureLoadedLocked()
        cache.removeAll()
        persistLocked()
        lock.unlock()
    }

    /// All keys currently stored (for diagnostics).
    public static var keys: [String] {
        lock.lock()
        ensureLoadedLocked()
        let k = Array(cache.keys).sorted()
        lock.unlock()
        return k
    }

    // MARK: - Internals

    private static func value(forKey key: String) -> Any? {
        lock.lock()
        ensureLoadedLocked()
        let v = cache[key]
        lock.unlock()
        return v
    }

    private static func setValue(_ value: Any, forKey key: String) {
        lock.lock()
        ensureLoadedLocked()
        cache[key] = value
        persistLocked()
        lock.unlock()
    }

    private static func ensureLoadedLocked() {
        guard !loaded else { return }
        loaded = true
        let url = configRoot(for: appName).appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else {
            cache = [:]
            return
        }
        cache = dict
    }

    private static func persistLocked() {
        let url = configRoot(for: appName).appendingPathComponent("settings.json")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard JSONSerialization.isValidJSONObject(cache),
              let data = try? JSONSerialization.data(
                withJSONObject: cache,
                options: [.prettyPrinted, .sortedKeys]
              )
        else { return }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    private static func configRoot(for name: String) -> URL {
        #if os(macOS)
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(name, isDirectory: true)
        #else
        // XDG Base Directory on Linux; fall back to ~/.config.
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        #endif
    }

    private static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "LavaUI" }
        // Keep path segments safe: no slashes or nulls.
        let cleaned = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        return cleaned.isEmpty ? "LavaUI" : cleaned
    }

    private static func boxed(_ raw: Any) -> Any {
        if JSONSerialization.isValidJSONObject(raw) { return raw }
        return [raw]
    }

    private static func decodeScalar<T: Decodable>(_ raw: Any, as type: T.Type) -> T? {
        // Wrap a scalar in an array so JSONDecoder has a container.
        guard let data = try? JSONSerialization.data(withJSONObject: [raw]),
              let arr = try? JSONDecoder().decode([T].self, from: data)
        else { return nil }
        return arr.first
    }
}
