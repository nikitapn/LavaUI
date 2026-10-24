import Foundation

/// Which freedesktop icon stands for a file, as names to look for in a theme.
///
/// Names rather than paths, and several of them best first: a theme is free to
/// leave out the specific one (`folder-download`, `application-pdf`), and the
/// generic one after it is what every theme has. Finding the file is the
/// app's business — this is only the naming convention, which is pure.
///
/// By extension, not by sniffing contents. A listing names thousands of files
/// and reads none of them; an icon that is wrong about a `.txt` that is really
/// a PNG is a fair price for a directory that opens instantly.
public enum FileIcon {
    /// The drawer of an icon theme a name is filed in.
    public enum Context: String, Sendable {
        case places
        case mimetypes
        case devices
    }

    /// One name to try, and where to look for it.
    public struct Candidate: Equatable, Sendable {
        public var context: Context
        public var name: String

        public init(_ context: Context, _ name: String) {
            self.context = context
            self.name = name
        }
    }

    /// What to try for `entry`, best first, ending in one every theme has.
    public static func candidates(
        for entry: FileEntry, home: String = NSHomeDirectory()
    ) -> [Candidate] {
        entry.isDirectory
            ? folder(entry.path, home: home)
            : fileNames(entry.name).map { Candidate(.mimetypes, $0) }
    }

    /// A folder's icon, ending in the plain `folder`.
    public static func folder(_ path: String, home: String = NSHomeDirectory()) -> [Candidate] {
        let normalized = path.count > 1 && path.hasSuffix("/")
            ? String(path.dropLast()) : path
        // The machine itself is a disk, not a folder, and themes keep that
        // with the hardware.
        if normalized == "/" {
            return [Candidate(.devices, "drive-harddisk"), Candidate(.devices, "computer"),
                    Candidate(.places, "folder")]
        }
        return folderNames(normalized, home: home).map { Candidate(.places, $0) }
    }

    /// The `places` names for a folder: the special ones by where they are,
    /// the rest plain.
    public static func folderNames(_ path: String, home: String = NSHomeDirectory()) -> [String] {
        let normalized = path.count > 1 && path.hasSuffix("/")
            ? String(path.dropLast()) : path
        if normalized == home { return ["user-home", "folder"] }
        if TrashPath.isTrash(normalized) { return ["user-trash", "folder"] }
        // Only directly under home: `~/projects/Music` is somebody's project,
        // not the music library.
        let parent = (normalized as NSString).deletingLastPathComponent
        if parent == home {
            let name = (normalized as NSString).lastPathComponent
            if let special = homeFolders[name] { return [special, "folder"] }
        }
        return ["folder"]
    }

    /// The XDG user directories under their default English names, which is
    /// what `Place` lists too.
    static let homeFolders: [String: String] = [
        "Desktop": "user-desktop",
        "Documents": "folder-documents",
        "Downloads": "folder-download",
        "Music": "folder-music",
        "Pictures": "folder-pictures",
        "Videos": "folder-videos",
        "Templates": "folder-templates",
        "Public": "folder-publicshare",
    ]

    /// A file's icon from its extension.
    public static func fileNames(_ name: String) -> [String] {
        let ext = (name as NSString).pathExtension.lowercased()
        if let specific = byExtension[ext] { return specific + ["text-x-generic"] }
        return ["text-x-generic"]
    }

    /// Specific name first where the spec has one, then the generic family
    /// icon (`image-x-generic`), which is what Adwaita mostly ships.
    static let byExtension: [String: [String]] = {
        var map: [String: [String]] = [:]
        func add(_ exts: [String], _ names: [String]) {
            for ext in exts { map[ext] = names }
        }
        add(["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "svg",
             "heic", "avif", "ico", "cr2", "nef", "arw", "dng"],
            ["image-x-generic"])
        add(["mp4", "mkv", "webm", "avi", "mov", "m4v", "wmv", "flv", "mpg", "mpeg"],
            ["video-x-generic"])
        add(["mp3", "flac", "ogg", "opus", "wav", "m4a", "aac", "wma"],
            ["audio-x-generic"])
        add(["zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "deb",
             "rpm", "jar", "apk", "iso"],
            ["package-x-generic"])
        add(["pdf"], ["application-pdf", "x-office-document"])
        add(["doc", "docx", "odt", "rtf", "epub"], ["x-office-document"])
        add(["xls", "xlsx", "ods", "csv"], ["x-office-spreadsheet"])
        add(["ppt", "pptx", "odp"], ["x-office-presentation"])
        add(["html", "htm", "xhtml"], ["text-html"])
        add(["sh", "bash", "zsh", "py", "rb", "pl", "js", "ts", "swift", "c",
             "h", "cpp", "hpp", "cc", "rs", "go", "java", "kt", "lua"],
            ["text-x-script"])
        add(["ttf", "otf", "woff", "woff2"], ["font-x-generic"])
        add(["so", "a", "o"], ["application-x-sharedlib", "application-x-executable"])
        add(["exe", "appimage", "bin", "run"], ["application-x-executable"])
        return map
    }()
}
