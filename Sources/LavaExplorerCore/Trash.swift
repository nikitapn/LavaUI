import Foundation

#if canImport(Glibc)
import Glibc
#endif

// The desktop's wastebasket, as the freedesktop.org Trash specification lays
// it out — so a file thrown away here is in the same Trash as one thrown
// away from Nautilus, Dolphin, Thunar or `gio trash`, and each can restore
// what the others put there.
//
// A trash directory holds `files/`, the trashed files under names unique
// within it, and `info/`, one `<name>.trashinfo` per file saying where it
// came from and when:
//
//     [Trash Info]
//     Path=/home/me/report%20final.pdf
//     DeletionDate=2026-09-24T10:30:00
//
// Throwing a file away is a `rename` into `files/`, never a copy. That is
// what the spec requires, and it is also the point: a copy of a 40 GB folder
// into the wastebasket would take as long as the disk takes and could fail
// halfway through. A file on another filesystem goes to a trash on *that*
// filesystem instead — `$topdir/.Trash/$uid` if the administrator made one,
// otherwise `$topdir/.Trash-$uid` — where its `Path` is relative to the top,
// so the drive still makes sense mounted somewhere else.

/// The address the Trash is browsed at. Not a folder: its listing is every
/// trash directory's contents together, named by where they came from.
public enum TrashPath {
    public static let uri = "trash:///"

    public static func isTrash(_ path: String) -> Bool { path.hasPrefix("trash:") }
}

/// One trash directory: `files/` and `info/` beneath `root`.
public struct TrashDirectory: Equatable, Sendable {
    public var root: String
    /// The top of the filesystem this trash serves, for a trash on another
    /// drive; `Path` in its info files is relative to it. Nil for the home
    /// trash, whose paths are absolute.
    public var topdir: String?

    public init(root: String, topdir: String? = nil) {
        self.root = root
        self.topdir = topdir
    }

    public var files: String { root + "/files" }
    public var info: String { root + "/info" }
}

/// What a `.trashinfo` file records.
public struct TrashInfo: Equatable, Sendable {
    /// Absolute for the home trash; relative to the drive's top otherwise.
    public var path: String
    public var deletionDate: Date?

    public init(path: String, deletionDate: Date?) {
        self.path = path
        self.deletionDate = deletionDate
    }

    /// Local time without a zone, which is what the spec says and what every
    /// other implementation writes.
    static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }

    public func serialized() -> String {
        let escaped = path.addingPercentEncoding(withAllowedCharacters: Self.pathAllowed) ?? path
        var text = "[Trash Info]\nPath=\(escaped)\n"
        if let deletionDate {
            text += "DeletionDate=\(Self.dateFormatter().string(from: deletionDate))\n"
        }
        return text
    }

    /// Nil for a file that is not a trash info file at all. Keys outside the
    /// `[Trash Info]` group are someone else's, and ignored.
    public static func parse(_ text: String) -> TrashInfo? {
        var inGroup = false
        var path: String?
        var date: Date?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inGroup = line == "[Trash Info]"
                continue
            }
            guard inGroup, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...])
            switch key {
            case "Path": path = value.removingPercentEncoding ?? value
            case "DeletionDate": date = dateFormatter().date(from: value)
            default: break
            }
        }
        guard let path, !path.isEmpty else { return nil }
        return TrashInfo(path: path, deletionDate: date)
    }

    /// What a URI path may carry as it is: the spec asks for `Path` escaped
    /// the way a `file://` URI's path is, and a slash is not escaped there.
    private static let pathAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~/!$&'()*+,;=:@")
        return set
    }()
}

/// Something in the Trash.
public struct TrashItem: Equatable, Sendable {
    /// Where it is now, in some trash directory's `files/`.
    public var trashedPath: String
    public var infoPath: String
    /// Where it came from, absolute.
    public var originalPath: String
    public var deletionDate: Date?
    public var isDirectory: Bool
    public var size: Int64?

    /// What it was called — `files/` names are made unique, and "report.2.pdf"
    /// is a trash implementation's business, not the user's.
    public var name: String { (originalPath as NSString).lastPathComponent }
    public var originalFolder: String { (originalPath as NSString).deletingLastPathComponent }
}

/// Moves files into the Trash, and out of it again.
///
/// Every operation is a rename or a removal, so none of them is slow except
/// erasing — which walks whatever it is erasing, and belongs on a worker.
public struct TrashCan: Sendable {
    public var home: TrashDirectory
    public var uid: UInt32
    /// Device of a path, not following a final symlink. Injectable so the
    /// choice of trash for a file on another drive can be tested without one.
    public var deviceOf: @Sendable (String) -> UInt64?
    /// Where filesystems are mounted, for finding the trash directories on
    /// other drives when listing.
    public var mountPoints: @Sendable () -> [String]

    public init(
        dataHome: String? = nil,
        uid: UInt32 = getuid(),
        deviceOf: @escaping @Sendable (String) -> UInt64? = TrashCan.device(of:),
        mountPoints: @escaping @Sendable () -> [String] = TrashCan.mountedFilesystems
    ) {
        let env = ProcessInfo.processInfo.environment
        let data = dataHome
            ?? env["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? NSHomeDirectory() + "/.local/share"
        self.home = TrashDirectory(root: data + "/Trash")
        self.uid = uid
        self.deviceOf = deviceOf
        self.mountPoints = mountPoints
    }

    // MARK: Throwing away

    /// Moves `path` into the trash on its own filesystem. Returns where it
    /// went.
    @discardableResult
    public func trash(_ path: String, now: Date = Date()) throws -> TrashItem {
        let path = CopyPaths.normalize(path)
        guard path != "/" else { throw FileAccessError(path: path, message: "Cannot trash /") }
        guard let device = deviceOf(path) else {
            throw FileAccessError(path: path, message: "Not found")
        }
        for trash in directories() {
            if CopyPaths.contains(trash.root, path) {
                throw FileAccessError(path: path, message: "Already in the Trash")
            }
            if CopyPaths.contains(path, trash.root) {
                throw FileAccessError(path: path, message: "It holds the Trash")
            }
        }
        let trash = try directory(for: path, device: device)
        let isDirectory = Self.isDirectory(path)
        let recorded = trash.topdir.map { Self.relative(path, to: $0) } ?? path
        let info = TrashInfo(path: recorded, deletionDate: now)

        // The info file is created first, exclusively: that is the lock on
        // the name. Two processes trashing "report.pdf" at once each get a
        // name of their own, and a file never sits in `files/` without saying
        // where it came from.
        let (name, infoPath) = try reserveName(
            (path as NSString).lastPathComponent, isDirectory: isDirectory,
            in: trash, contents: info.serialized()
        )
        let destination = trash.files + "/" + name
        guard rename(path, destination) == 0 else {
            let message = errno == EXDEV
                ? "Cannot move across drives into the Trash"
                : String(cString: strerror(errno))
            unlink(infoPath)
            throw FileAccessError(path: path, message: message)
        }
        return TrashItem(
            trashedPath: destination, infoPath: infoPath, originalPath: path,
            deletionDate: now, isDirectory: isDirectory, size: Self.size(of: destination)
        )
    }

    /// Which trash a file on `device` goes to, created if need be.
    func directory(for path: String, device: UInt64) throws -> TrashDirectory {
        try Self.makeDirectory(home.root, private: true)
        try Self.makeDirectory(home.files, private: true)
        try Self.makeDirectory(home.info, private: true)
        if deviceOf(home.root) == device { return home }

        let top = topdir(of: path, device: device)
        // An administrator's `.Trash`, shared and sticky, with a directory per
        // user in it. The spec's checks are what keep another user from
        // planting a symlink there that aims our files somewhere else.
        let shared = top + "/.Trash"
        if Self.isStickyRealDirectory(shared) {
            let mine = shared + "/\(uid)"
            if (try? Self.makeDirectory(mine, private: true)) != nil,
               Self.isOwnedRealDirectory(mine, uid: uid)
            {
                return try prepared(TrashDirectory(root: mine, topdir: top))
            }
        }
        let own = top + "/.Trash-\(uid)"
        do {
            try Self.makeDirectory(own, private: true)
        } catch {
            throw FileAccessError(path: path, message: "This drive has no Trash")
        }
        guard Self.isOwnedRealDirectory(own, uid: uid) else {
            throw FileAccessError(path: path, message: "This drive's Trash is not yours")
        }
        return try prepared(TrashDirectory(root: own, topdir: top))
    }

    private func prepared(_ trash: TrashDirectory) throws -> TrashDirectory {
        try Self.makeDirectory(trash.files, private: true)
        try Self.makeDirectory(trash.info, private: true)
        return trash
    }

    /// The highest folder above `path` still on `device`: where that
    /// filesystem is mounted.
    func topdir(of path: String, device: UInt64) -> String {
        var top = (path as NSString).deletingLastPathComponent
        if top.isEmpty { return "/" }
        while top != "/" {
            let parent = (top as NSString).deletingLastPathComponent
            let up = parent.isEmpty ? "/" : parent
            guard deviceOf(up) == device else { break }
            top = up
        }
        return top
    }

    private func reserveName(
        _ name: String, isDirectory: Bool, in trash: TrashDirectory, contents: String
    ) throws -> (String, String) {
        let (stem, ext) = CopyNaming.split(name, isDirectory: isDirectory)
        for n in 1...10_000 {
            let candidate = n == 1 ? name
                : ext.isEmpty ? "\(stem).\(n)" : "\(stem).\(n).\(ext)"
            let infoPath = trash.info + "/" + candidate + ".trashinfo"
            // A file in `files/` with no info beside it is a leftover from an
            // interrupted trash; its name is still taken.
            if Self.lexists(trash.files + "/" + candidate) { continue }
            let fd = open(infoPath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd < 0 {
                if errno == EEXIST { continue }
                throw FileAccessError(path: infoPath, message: String(cString: strerror(errno)))
            }
            let bytes = Array(contents.utf8)
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
            guard written == bytes.count else {
                unlink(infoPath)
                throw FileAccessError(path: infoPath, message: "Could not write the Trash record")
            }
            return (candidate, infoPath)
        }
        throw FileAccessError(path: name, message: "No free name in the Trash")
    }

    // MARK: Looking inside

    /// Every trash directory there is: this user's home trash, then one per
    /// mounted filesystem that has one.
    public func directories() -> [TrashDirectory] {
        var out = [home]
        for top in mountPoints() {
            let own = TrashDirectory(root: top + "/.Trash-\(uid)", topdir: top)
            let shared = TrashDirectory(root: top + "/.Trash/\(uid)", topdir: top)
            for candidate in [shared, own] where Self.isOwnedRealDirectory(candidate.root, uid: uid) {
                if !out.contains(candidate) { out.append(candidate) }
            }
        }
        return out
    }

    public func items() -> [TrashItem] {
        directories().flatMap(items(in:))
    }

    func items(in trash: TrashDirectory) -> [TrashItem] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: trash.info) else {
            return []
        }
        return names.compactMap { infoName -> TrashItem? in
            guard infoName.hasSuffix(".trashinfo") else { return nil }
            let name = String(infoName.dropLast(".trashinfo".count))
            let infoPath = trash.info + "/" + infoName
            let trashed = trash.files + "/" + name
            // An info file whose file is gone describes nothing, and the
            // spec says to ignore it.
            guard Self.lexists(trashed),
                  let text = try? String(contentsOfFile: infoPath, encoding: .utf8),
                  let info = TrashInfo.parse(text)
            else { return nil }
            let original = info.path.hasPrefix("/")
                ? info.path
                : CopyPaths.join(trash.topdir ?? "/", info.path)
            return TrashItem(
                trashedPath: trashed, infoPath: infoPath,
                originalPath: CopyPaths.normalize(original),
                deletionDate: info.deletionDate,
                isDirectory: Self.isDirectory(trashed), size: Self.size(of: trashed)
            )
        }
    }

    public func item(trashedPath: String) -> TrashItem? {
        let folder = (trashedPath as NSString).deletingLastPathComponent
        let trash = directories().first { $0.files == folder }
        return trash.flatMap { items(in: $0).first { $0.trashedPath == trashedPath } }
    }

    // MARK: Taking out

    /// Puts `item` back where it came from, recreating the folder it was in
    /// if that has gone too. Refuses rather than overwrite: something new by
    /// that name is not what anybody means by "restore".
    @discardableResult
    public func restore(_ item: TrashItem) throws -> String {
        let destination = item.originalPath
        if Self.lexists(destination) {
            throw FileAccessError(
                path: destination,
                message: "\u{201C}\(item.name)\u{201D} is already in \(item.originalFolder)"
            )
        }
        try FileManager.default.createDirectory(
            atPath: item.originalFolder, withIntermediateDirectories: true
        )
        if rename(item.trashedPath, destination) != 0 {
            // Another implementation may have put a file from elsewhere in the
            // home trash by copying; then it goes back the same way.
            guard errno == EXDEV else {
                throw FileAccessError(path: destination, message: String(cString: strerror(errno)))
            }
            try FileManager.default.moveItem(atPath: item.trashedPath, toPath: destination)
        }
        unlink(item.infoPath)
        return destination
    }

    /// Gone for good. The file before its info, so an interrupted erase
    /// leaves an info file the listing ignores rather than a file it cannot
    /// name.
    public func erase(_ item: TrashItem) throws {
        if Self.lexists(item.trashedPath) {
            try FileManager.default.removeItem(atPath: item.trashedPath)
        }
        unlink(item.infoPath)
    }

    /// Everything in every trash directory — leftovers with no info included.
    public func empty() -> [FileAccessError] {
        var failures: [FileAccessError] = []
        for trash in directories() {
            for folder in [trash.files, trash.info] {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
                for name in names {
                    let path = folder + "/" + name
                    do {
                        try FileManager.default.removeItem(atPath: path)
                    } catch {
                        failures.append(FileAccessError(path: path, message: error.localizedDescription))
                    }
                }
            }
        }
        return failures
    }

    // MARK: Filesystem

    public static func device(of path: String) -> UInt64? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return UInt64(st.st_dev)
    }

    /// From `/proc/self/mounts`; the second field, with the kernel's octal
    /// escapes for spaces undone.
    public static func mountedFilesystems() -> [String] {
        guard let text = try? String(contentsOfFile: "/proc/self/mounts", encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count > 1 else { return nil }
            return String(fields[1])
                .replacingOccurrences(of: "\\040", with: " ")
                .replacingOccurrences(of: "\\011", with: "\t")
                .replacingOccurrences(of: "\\134", with: "\\")
        }
    }

    static func lexists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    public static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func size(of path: String) -> Int64? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR else { return nil }
        return Int64(st.st_size)
    }

    static func isStickyRealDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
            && (st.st_mode & S_ISVTX) != 0
    }

    static func isOwnedRealDirectory(_ path: String, uid: UInt32) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == uid
    }

    static func makeDirectory(_ path: String, private: Bool) throws {
        if mkdir(path, `private` ? 0o700 : 0o755) == 0 || errno == EEXIST { return }
        throw FileAccessError(path: path, message: String(cString: strerror(errno)))
    }

    static func relative(_ path: String, to top: String) -> String {
        if top == "/" { return String(path.dropFirst()) }
        return String(path.dropFirst(top.count + 1))
    }
}

/// Removes files for good — Shift+Delete, and Delete inside the Trash.
public enum FileEraser {
    public static func erase(_ paths: [String]) -> [FileAccessError] {
        paths.compactMap { path in
            do {
                try FileManager.default.removeItem(atPath: path)
                return nil
            } catch {
                return FileAccessError(path: path, message: error.localizedDescription)
            }
        }
    }
}

/// A `FileSource` that also answers for `trash:///`, by listing every
/// trash directory as one folder. Entries keep their real path in `files/` —
/// that is what opens, drags and restores — under the name they had.
public struct TrashListingSource: FileSource {
    public var base: any FileSource
    public var trash: TrashCan

    public init(base: any FileSource, trash: TrashCan) {
        self.base = base
        self.trash = trash
    }

    public func entries(in directory: String) throws -> [FileEntry] {
        guard TrashPath.isTrash(directory) else { return try base.entries(in: directory) }
        return trash.items().map { item in
            FileEntry(
                path: item.trashedPath, name: item.name, isDirectory: item.isDirectory,
                size: item.size, modified: item.deletionDate,
                isHidden: item.name.hasPrefix(".")
            )
        }
    }

    public func entry(at path: String) throws -> FileEntry {
        if TrashPath.isTrash(path) {
            return FileEntry(path: TrashPath.uri, name: "Trash", isDirectory: true)
        }
        return try base.entry(at: path)
    }

    public func exists(_ path: String) -> Bool {
        TrashPath.isTrash(path) || base.exists(path)
    }
}
