import Foundation

/// Freedesktop MIME type of a path, and which application owns it.
///
/// Types are the `shared-mime-info` names desktop entries declare
/// (`image/png`, `inode/directory`). The lookup is an extension table, not
/// `gio` or `xdg-mime`: those are subprocesses, and a file manager that
/// asked them from a view body — once per visible row, because a presented
/// overlay's content stays mounted while hidden — stalled the frame on
/// `waitUntilExit`. Sniffing a file's bytes is a better answer for one
/// Open With click; it is not a better answer thirty times a scroll.
public enum MimeApps {
    public static func type(of path: String, isDirectory: Bool) -> String {
        if isDirectory { return "inode/directory" }
        return typeFromExtension(path)
    }

    /// The desktop-file id currently registered for `mime`, or nil.
    ///
    /// Read from `mimeapps.list`, not `xdg-mime query default`. Same file
    /// that command writes; no child process.
    public static func defaultHandler(for mime: String) -> String? {
        defaults()[canonicalType(mime)]?.first
    }

    /// Resolve the saved default against installed entries, skipping stale ids.
    /// File activation and the context menu use this same decision.
    public static func preferredApplication(for mime: String, applications: [DesktopEntry]) -> DesktopEntry? {
        preferredApplication(for: mime, applications: applications, candidates: defaults())
    }

    static func preferredApplication(
        for mime: String, applications: [DesktopEntry], candidates: [String: [String]]
    ) -> DesktopEntry? {
        for id in candidates[canonicalType(mime)] ?? [] {
            if let app = applications.first(where: { $0.desktopFileId == id }) { return app }
        }
        return nil
    }

    /// MIME aliases in desktop entries and mimeapps.list identify the same type.
    public static func canonicalType(_ mime: String) -> String {
        canonicalType(mime, aliases: aliases)
    }

    static func canonicalType(_ mime: String, aliases: [String: String]) -> String {
        var type = mime
        var seen = Set<String>()
        while let next = aliases[type], seen.insert(type).inserted { type = next }
        return type
    }

    /// Writes `~/.config/mimeapps.list` through `xdg-mime default`, then
    /// drops the in-process cache so the next Open With checkmark is true.
    @discardableResult
    public static func setDefault(_ desktopFileId: String, for mime: String) -> Bool {
        guard let xdg = which("xdg-mime") else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xdg)
        process.arguments = ["default", desktopFileId, canonicalType(mime)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            invalidateDefaults()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// `[Default Applications]` as mime → first desktop-file id.
    public static func parseDefaults(_ text: String) -> [String: String] {
        parseDefaultLists(text).compactMapValues(\.first)
    }

    static func parseDefaultLists(_ text: String) -> [String: [String]] {
        var inDefaults = false
        var out: [String: [String]] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                inDefaults = line == "[Default Applications]"
                continue
            }
            guard inDefaults, let eq = line.firstIndex(of: "=") else { continue }
            let mime = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let rest = line[line.index(after: eq)...]
            let ids = rest.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !ids.isEmpty { out[mime] = ids }
        }
        return out
    }

    /// Extension → type, for when gio is not on PATH and for tests.
    ///
    /// Unknown extensions are `application/octet-stream`, which is the
    /// honest "this is a pile of bytes" rather than a guess.
    public static func typeFromExtension(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return canonicalType(Self.extensions[ext] ?? "application/octet-stream")
    }

    // MARK: - Cache

    nonisolated(unsafe) private static var cachedDefaults: [String: [String]]?

    public static func invalidateDefaults() { cachedDefaults = nil }

    private static func defaults() -> [String: [String]] {
        if let cachedDefaults { return cachedDefaults }
        let texts = mimeappsPaths(environment: ProcessInfo.processInfo.environment).compactMap {
            try? String(contentsOfFile: $0, encoding: .utf8)
        }
        let merged = mergeDefaults(texts, aliases: aliases)
        cachedDefaults = merged
        return merged
    }

    /// Highest-precedence file first. Aliases are folded within each file
    /// before merging, so a user override beats a system default under either name.
    static func mergeDefaults(_ texts: [String], aliases: [String: String]) -> [String: [String]] {
        var merged: [String: [String]] = [:]
        for text in texts {
            let parsed = parseDefaultLists(text)
            // Prefer the canonical spelling if both occur in one file.
            let types = parsed.keys.sorted {
                let a = canonicalType($0, aliases: aliases) == $0
                let b = canonicalType($1, aliases: aliases) == $1
                return a == b ? $0 < $1 : a
            }
            for type in types {
                let canonical = canonicalType(type, aliases: aliases)
                for id in parsed[type] ?? [] where !(merged[canonical] ?? []).contains(id) {
                    merged[canonical, default: []].append(id)
                }
            }
        }
        return merged
    }

    static func mimeappsPaths(environment env: [String: String]) -> [String] {
        let home = env["HOME"] ?? NSHomeDirectory()
        func value(_ key: String, _ fallback: String) -> String {
            env[key].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
        let config = value("XDG_CONFIG_HOME", home + "/.config")
        let data = value("XDG_DATA_HOME", home + "/.local/share")
        let configs = value("XDG_CONFIG_DIRS", "/etc/xdg").split(separator: ":").map(String.init)
        let datas = value("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(separator: ":").map(String.init)
        let desktops = value("XDG_CURRENT_DESKTOP", "").split(separator: ":").map { $0.lowercased() }
        func paths(_ directory: String) -> [String] {
            desktops.map { directory + "/" + $0 + "-mimeapps.list" } + [directory + "/mimeapps.list"]
        }
        return ([config] + configs).flatMap(paths)
            + ([data] + datas).flatMap { paths($0 + "/applications") }
    }

    private static let aliases: [String: String] = {
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        let user = env["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/share"
        let system = env["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/share:/usr/share"
        let roots = [user] + system.split(separator: ":").map(String.init)
        var aliases: [String: String] = [:]
        for root in roots {
            guard let text = try? String(contentsOfFile: root + "/mime/aliases", encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.count == 2, aliases[String(fields[0])] == nil {
                    aliases[String(fields[0])] = String(fields[1])
                }
            }
        }
        if aliases.isEmpty {
            aliases = ["video/x-matroska": "video/matroska", "audio/x-matroska": "audio/matroska"]
        }
        return aliases
    }()

    private static let extensions: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "jpe": "image/jpeg",
        "gif": "image/gif",
        "bmp": "image/bmp",
        "svg": "image/svg+xml",
        "webp": "image/webp",
        "tif": "image/tiff", "tiff": "image/tiff",
        "txt": "text/plain",
        "log": "text/x-log",
        "md": "text/markdown",
        "html": "text/html", "htm": "text/html",
        "xml": "text/xml",
        "json": "application/json",
        "pdf": "application/pdf",
        "kdbx": "application/x-keepass2",
        "zip": "application/zip",
        "gz": "application/gzip",
        "tar": "application/x-tar",
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "ogg": "audio/ogg",
        "flac": "audio/flac", "m4a": "audio/mp4", "aac": "audio/aac",
        "opus": "audio/ogg", "mka": "audio/x-matroska",
        "aif": "audio/x-aiff", "aiff": "audio/x-aiff",
        "mp4": "video/mp4",
        "webm": "video/webm",
        "mkv": "video/x-matroska", "mk3d": "video/x-matroska-3d",
        "mov": "video/quicktime", "qt": "video/quicktime",
        "avi": "video/x-msvideo", "mpg": "video/mpeg", "mpeg": "video/mpeg",
        "m4v": "video/mp4", "ogv": "video/ogg", "flv": "video/x-flv",
        "wmv": "video/x-ms-wmv", "mts": "video/mp2t", "m2ts": "video/mp2t",
        "3gp": "video/3gpp", "3gpp": "video/3gpp",
        "swift": "text/x-swift",
        "c": "text/x-csrc",
        "h": "text/x-chdr",
        "py": "text/x-python",
        "rs": "text/rust",
        "go": "text/x-go",
        "sh": "application/x-shellscript",
    ]

    private static func which(_ binary: String) -> String? {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
        {
            let candidate = "\(dir)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
