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
        defaults()[mime]
    }

    /// Writes `~/.config/mimeapps.list` through `xdg-mime default`, then
    /// drops the in-process cache so the next Open With checkmark is true.
    @discardableResult
    public static func setDefault(_ desktopFileId: String, for mime: String) -> Bool {
        guard let xdg = which("xdg-mime") else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xdg)
        process.arguments = ["default", desktopFileId, mime]
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
        var inDefaults = false
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                inDefaults = line == "[Default Applications]"
                continue
            }
            guard inDefaults, let eq = line.firstIndex(of: "=") else { continue }
            let mime = String(line[..<eq])
            let rest = line[line.index(after: eq)...]
            guard let first = rest.split(separator: ";")
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { !$0.isEmpty })
            else { continue }
            out[mime] = first
        }
        return out
    }

    /// Extension → type, for when gio is not on PATH and for tests.
    ///
    /// Unknown extensions are `application/octet-stream`, which is the
    /// honest "this is a pile of bytes" rather than a guess.
    public static func typeFromExtension(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return Self.extensions[ext] ?? "application/octet-stream"
    }

    // MARK: - Cache

    nonisolated(unsafe) private static var cachedDefaults: [String: String]?

    public static func invalidateDefaults() {
        cachedDefaults = nil
    }

    private static func defaults() -> [String: String] {
        if let cachedDefaults { return cachedDefaults }
        var merged: [String: String] = [:]
        // Least specific first so the user's file overwrites.
        for path in mimeappsPaths().reversed() {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8)
            else { continue }
            for (mime, desktop) in parseDefaults(text) {
                merged[mime] = desktop
            }
        }
        cachedDefaults = merged
        return merged
    }

    private static func mimeappsPaths() -> [String] {
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        let config = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home + "/.config"
        let data = env["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home + "/.local/share"
        return [
            config + "/mimeapps.list",
            data + "/applications/mimeapps.list",
        ]
    }

    private static let extensions: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "jpe": "image/jpeg",
        "gif": "image/gif",
        "bmp": "image/bmp",
        "svg": "image/svg+xml",
        "webp": "image/webp",
        "tif": "image/tiff", "tiff": "image/tiff",
        "txt": "text/plain",
        "md": "text/markdown",
        "html": "text/html", "htm": "text/html",
        "xml": "text/xml",
        "json": "application/json",
        "pdf": "application/pdf",
        "zip": "application/zip",
        "gz": "application/gzip",
        "tar": "application/x-tar",
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "ogg": "audio/ogg",
        "mp4": "video/mp4",
        "webm": "video/webm",
        "mkv": "video/x-matroska",
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
