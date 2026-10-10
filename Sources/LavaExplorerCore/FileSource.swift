import Foundation

/// What a file manager asks of a store of files.
///
/// Local first, and only listing plus identity. `docs/desktop-apps.md` wants
/// this seam from the first commit so a later SFTP or gvfs source is another
/// type rather than a retrofit. It also wants `write` and `delete` on the
/// protocol. Those are omitted on purpose: a listing has no business
/// removing anything. Throwing away is `TrashCan`, and removing for good is
/// `FileEraser`, reached only once the user has said yes.
public protocol FileSource: Sendable {
    /// Direct children of `directory`. Unsorted, including hidden names;
    /// filtering and ordering belong to `FolderListing`.
    func entries(in directory: String) throws -> [FileEntry]
    /// One path, for deciding whether an argument is a file or a folder.
    func entry(at path: String) throws -> FileEntry
    func exists(_ path: String) -> Bool
}

public struct FileAccessError: Error, Equatable, Sendable {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

/// The machine's own directories, through `FileManager`.
public struct LocalFileSource: FileSource {
    public init() {}

    public func entries(in directory: String) throws -> [FileEntry] {
        let url = URL(fileURLWithPath: directory)
        var isDir: ObjCBool = false
        let there = FileManager.default.fileExists(
            atPath: directory, isDirectory: &isDir
        )
        guard there else { throw FileAccessError(path: directory, message: "Not found") }
        guard isDir.boolValue else {
            throw FileAccessError(path: directory, message: "Not a folder")
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch {
            throw FileAccessError(
                path: directory,
                message: error.localizedDescription
            )
        }
        let folder = url.path
        return names.compactMap { FileEntry(directory: folder, name: $0) }
    }

    public func entry(at path: String) throws -> FileEntry {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: path) else {
            throw FileAccessError(path: path, message: "Not found")
        }
        let folder = url.deletingLastPathComponent().path
        guard let entry = FileEntry(directory: folder, name: url.lastPathComponent) else {
            throw FileAccessError(path: path, message: "Unreadable")
        }
        return entry
    }

    public func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

}

extension FileEntry {
    /// From `lstat` (and `stat`, for what a link points at) — the way every
    /// listing is built.
    ///
    /// Not `URL.resourceValues`, which is the obvious call and on Linux costs
    /// 0.6 ms a file: `/tmp` with 4,386 names took 2.7 s to list through it,
    /// against 7 ms of `lstat` for the same names. The answers are the same —
    /// a link is a folder when what it points at is one, its size is the
    /// target's, and a broken link is a file with no size.
    public init?(directory: String, name: String) {
        guard !name.isEmpty else { return nil }
        let path = directory == "/" ? "/" + name : directory + "/" + name
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let isLink = (info.st_mode & S_IFMT) == S_IFLNK
        var target = info
        // Followed for what the row shows; a broken link keeps its own.
        let followed = isLink && stat(path, &target) == 0
        let shown = followed ? target : info
        let isDirectory = (shown.st_mode & S_IFMT) == S_IFDIR
        self.init(
            path: path,
            name: name,
            isDirectory: isDirectory,
            size: isDirectory || (isLink && !followed) ? nil : Int64(shown.st_size),
            modified: Date(
                timeIntervalSince1970: TimeInterval(shown.st_mtim.tv_sec)
                    + TimeInterval(shown.st_mtim.tv_nsec) / 1_000_000_000
            ),
            isHidden: name.hasPrefix("."),
            isSymlink: isLink
        )
    }

    public init?(url: URL) {
        let values = try? url.resourceValues(forKeys: [
            .nameKey, .isDirectoryKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey, .isHiddenKey,
        ])
        let name = values?.name ?? url.lastPathComponent
        // A trailing slash on the path would make the last component empty,
        // and a nameless row is a row nobody can click.
        guard !name.isEmpty else { return nil }
        let hidden = values?.isHidden ?? name.hasPrefix(".")
        self.init(
            path: url.path,
            name: name,
            isDirectory: values?.isDirectory ?? false,
            size: values?.isDirectory == true ? nil : values?.fileSize.map(Int64.init),
            modified: values?.contentModificationDate,
            isHidden: hidden,
            isSymlink: values?.isSymbolicLink ?? false
        )
    }
}
