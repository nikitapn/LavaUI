import Foundation

/// What a file manager asks of a store of files.
///
/// Local first, and only listing plus identity. `docs/desktop-apps.md` wants
/// this seam from the first commit so a later SFTP or gvfs source is another
/// type rather than a retrofit. It also wants `write` and `delete` on the
/// protocol. Those are omitted on purpose: this app does not throw files away,
/// and a method nobody is allowed to call is a method somebody will call.
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
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Self.keys,
                options: []
            )
        } catch {
            throw FileAccessError(
                path: directory,
                message: error.localizedDescription
            )
        }
        return urls.compactMap(FileEntry.init(url:))
    }

    public func entry(at path: String) throws -> FileEntry {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw FileAccessError(path: path, message: "Not found")
        }
        guard let entry = FileEntry(url: url) else {
            throw FileAccessError(path: path, message: "Unreadable")
        }
        return entry
    }

    public func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private static let keys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey, .isHiddenKey,
    ]
}

extension FileEntry {
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
