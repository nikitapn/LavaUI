import CArchive
import Foundation

/// Archives through libarchive: listing, extracting and creating.
///
/// libarchive rather than zlib and containers of our own, because the
/// compression is the easy part. A zip is a central directory, zip64 past
/// 4 GiB, data descriptors and two ideas of what a name's bytes mean; a tar is
/// ustar, GNU long names and pax headers. Those are written against files
/// other people produced, which is where readers break — and libarchive also
/// reads the xz, zstd, 7z and rar people are actually handed. It is on every
/// machine this runs on already: pacman links it.
///
/// Every call here blocks and is meant for a worker thread, like
/// `FileCopier`: an archive takes as long as the disk and the compressor take.
public enum Archive {
    /// What is inside, in the order it is stored, without unpacking anything.
    ///
    /// Reads every header, which for a tarball means reading — and
    /// decompressing — the whole file: a tar has no index. A zip has one, but
    /// libarchive streams it the same way, so this is not free on a big
    /// archive either. Run it off the frame loop.
    public static func list(_ path: String) throws -> [ArchiveEntry] {
        try withUTF8Locale {
            let reader = try ArchiveReader(path: path)
            var entries: [ArchiveEntry] = []
            while let header = try reader.next() {
                guard let entry = ArchiveEntry(header) else { continue }
                entries.append(entry)
            }
            return entries
        }
    }

    /// Whether libarchive recognises the file as an archive at all — opens it
    /// and reads the first header. Cheap: one header, not the whole file.
    ///
    /// A plain `.gz` of a single file is not one: libarchive reads it only
    /// with the `raw` format, which would also make every file on the disk an
    /// "archive" of itself. A tarball inside the `.gz` is.
    public static func isArchive(_ path: String) -> Bool {
        withUTF8Locale {
            guard let reader = try? ArchiveReader(path: path) else { return false }
            return (try? reader.next()) != nil
        }
    }
}

/// One thing stored in an archive.
public struct ArchiveEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case file
        case directory
        case symlink
        /// Another name for an earlier entry (`linkTarget`). Tar only.
        case hardlink
        /// A device node, a FIFO, a socket. Listed, never extracted: nothing a
        /// file manager unpacks should be making device nodes.
        case other
    }

    /// The name as stored, tidied: no leading `./`, no trailing `/`. Not made
    /// safe — `../x` is listed as `../x`, so a listing shows what an archive
    /// really holds. `ArchivePaths.safeRelative` is the extraction rule.
    public var path: String
    public var kind: Kind
    /// Uncompressed size, when the header says. A zip written as a stream
    /// puts the size after the data, so its entries may not know.
    public var size: Int64?
    public var modified: Date?
    /// The permission bits, `mode & 0o7777`.
    public var permissions: UInt16
    public var linkTarget: String?
    /// Stored encrypted: extracting it needs `extract(password:)`.
    public var isEncrypted: Bool

    public init(
        path: String, kind: Kind, size: Int64? = nil, modified: Date? = nil,
        permissions: UInt16 = 0o644, linkTarget: String? = nil,
        isEncrypted: Bool = false
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.linkTarget = linkTarget
        self.isEncrypted = isEncrypted
    }

    /// Nil for the archive's own root (`.` or `./`), which names nothing.
    init?(_ header: OpaquePointer) {
        let name = ArchivePaths.tidy(ArchiveText.pathname(header))
        guard !name.isEmpty else { return nil }
        path = name
        if let hardlink = ArchiveText.hardlink(header) {
            kind = .hardlink
            linkTarget = ArchivePaths.tidy(hardlink)
        } else {
            switch Int32(bitPattern: archive_entry_filetype(header)) {
            case Int32(LAVA_AE_IFREG): kind = .file
            case Int32(LAVA_AE_IFDIR): kind = .directory
            case Int32(LAVA_AE_IFLNK): kind = .symlink
            default: kind = .other
            }
            linkTarget = kind == .symlink ? ArchiveText.symlink(header) : nil
        }
        size = archive_entry_size_is_set(header) != 0 ? archive_entry_size(header) : nil
        modified = archive_entry_mtime_is_set(header) != 0
            ? Date(
                timeIntervalSince1970: TimeInterval(archive_entry_mtime(header))
                    + TimeInterval(archive_entry_mtime_nsec(header)) / 1e9
            )
            : nil
        permissions = UInt16(truncatingIfNeeded: archive_entry_perm(header) & 0o7777)
        isEncrypted = archive_entry_is_encrypted(header) != 0
    }
}

/// What went wrong, and with which file — the archive itself or one entry.
public struct ArchiveError: Error, Equatable, Sendable {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

}

/// Where a long operation has got to. Return false from the callback to stop.
public struct ArchiveProgress: Equatable, Sendable {
    /// The entry being worked on, as stored.
    public var entry: String
    /// Extracting: compressed bytes read out of the archive file, against its
    /// size — the only total known before the end, since a tarball's
    /// uncompressed size is not written anywhere. Creating: bytes of the
    /// sources read, against what they add up to.
    public var bytesDone: Int64
    public var bytesTotal: Int64

    public var fraction: Double {
        bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0
    }
}

/// What `create` can write.
public enum ArchiveFormat: String, CaseIterable, Equatable, Sendable {
    case zip
    case tar
    case tarGzip
    case tarBzip2
    case tarXz
    case tarZstd
    case sevenZip

    /// The extension a new archive is given.
    public var fileExtension: String {
        switch self {
        case .zip: "zip"
        case .tar: "tar"
        case .tarGzip: "tar.gz"
        case .tarBzip2: "tar.bz2"
        case .tarXz: "tar.xz"
        case .tarZstd: "tar.zst"
        case .sevenZip: "7z"
        }
    }

    /// The format a name says it is, by extension and ignoring case —
    /// including the short forms (`.tgz`). Nil for anything else; extraction
    /// does not need this, libarchive reads what is there whatever the name.
    public static func forFileName(_ name: String) -> ArchiveFormat? {
        let lower = name.lowercased()
        let suffixes: [(String, ArchiveFormat)] = [
            (".tar.gz", .tarGzip), (".tgz", .tarGzip),
            (".tar.bz2", .tarBzip2), (".tbz2", .tarBzip2), (".tbz", .tarBzip2),
            (".tar.xz", .tarXz), (".txz", .tarXz),
            (".tar.zst", .tarZstd), (".tzst", .tarZstd),
            (".tar", .tar), (".zip", .zip), (".7z", .sevenZip),
        ]
        return suffixes.first { lower.hasSuffix($0.0) }?.1
    }

    /// Whether `create` can encrypt it. Zip only: libarchive writes no
    /// encrypted 7z or tar.
    public var supportsPassword: Bool { self == .zip }

    /// What a menu calls it.
    public var title: String {
        switch self {
        case .zip: "Zip"
        case .tar: "Tar (uncompressed)"
        case .tarGzip: "Tar + gzip"
        case .tarBzip2: "Tar + bzip2"
        case .tarXz: "Tar + xz"
        case .tarZstd: "Tar + zstd"
        case .sevenZip: "7-Zip"
        }
    }

    /// The name without the archive's extension: what "Extract here" calls
    /// the folder. Nil when the name has none this knows.
    public static func stem(of name: String) -> String? {
        let lower = name.lowercased()
        let known = [
            ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tbz", ".tar.xz", ".txz",
            ".tar.zst", ".tzst", ".tar", ".zip", ".7z", ".rar", ".gz", ".bz2",
            ".xz", ".zst", ".iso", ".cpio",
        ]
        guard let suffix = known.first(where: { lower.hasSuffix($0) }),
              name.count > suffix.count
        else { return nil }
        return String(name.dropLast(suffix.count))
    }
}

/// The rule for what an entry's name may turn into on disk.
public enum ArchivePaths {
    /// `./a/b/` → `a/b`. Repeated slashes and `.` components go too.
    static func tidy(_ raw: String) -> String {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
        let joined = parts.joined(separator: "/")
        return raw.hasPrefix("/") && !joined.isEmpty ? "/" + joined : joined
    }

    /// The name an entry may be written under, relative to the folder it is
    /// extracted into — or nil when it would land outside it.
    ///
    /// A leading `/` is dropped rather than refused, as tar does: an archive
    /// made with absolute names is common and harmless once they are made
    /// relative. A `..` anywhere is refused: there is no reading of
    /// `a/../../b` that stays inside, and an archive carrying one either was
    /// made carelessly or was made to do exactly that. Empty is nil too —
    /// it names the folder itself.
    public static func safeRelative(_ raw: String) -> String? {
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts.joined(separator: "/")
    }
}

// MARK: - libarchive plumbing

/// Names in and out of libarchive as UTF-8, whatever the process locale.
///
/// libarchive keeps a name in several encodings and converts between them
/// through the *locale*, and a Swift process never calls `setlocale` — it
/// runs in "C", where nothing outside ASCII converts. The `_utf8` accessors
/// sidestep that for reading; the raw bytes are the fallback for a name that
/// is not valid UTF-8 at all, so it is shown mangled rather than dropped.
enum ArchiveText {
    static func pathname(_ entry: OpaquePointer) -> String {
        string(archive_entry_pathname_utf8(entry), archive_entry_pathname(entry)) ?? ""
    }

    static func hardlink(_ entry: OpaquePointer) -> String? {
        string(archive_entry_hardlink_utf8(entry), archive_entry_hardlink(entry))
    }

    static func symlink(_ entry: OpaquePointer) -> String? {
        string(archive_entry_symlink_utf8(entry), archive_entry_symlink(entry))
    }

    private static func string(
        _ utf8: UnsafePointer<CChar>?, _ raw: UnsafePointer<CChar>?
    ) -> String? {
        if let utf8 { return String(cString: utf8) }
        if let raw { return String(decoding: UnsafeRawBufferPointer(
            start: raw, count: strlen(raw)
        ), as: UTF8.self) }
        return nil
    }

    static func error(_ archive: OpaquePointer?) -> String {
        guard let archive, let message = archive_error_string(archive) else {
            return "Unknown error"
        }
        return String(cString: message)
    }
}

/// A `struct archive *` opened for reading a file, closed with it.
final class ArchiveReader {
    let handle: OpaquePointer
    let path: String

    init(path: String, password: String? = nil) throws {
        guard let handle = archive_read_new() else {
            throw ArchiveError(path: path, message: "Out of memory")
        }
        self.handle = handle
        self.path = path
        archive_read_support_filter_all(handle)
        archive_read_support_format_all(handle)
        // Names in a zip without the UTF-8 flag are whatever the tool that
        // wrote it thought; libarchive's guess for those is the locale's,
        // which here is "C". UTF-8 is the right guess for anything made this
        // century on a machine that is not Windows.
        archive_read_set_options(handle, "hdrcharset=UTF-8")
        if let password, !password.isEmpty {
            archive_read_add_passphrase(handle, password)
        }
        // 64 KiB blocks: big enough that the read syscalls are noise.
        // Every property is set by now, so a throw still runs `deinit`,
        // which is what frees the handle.
        guard archive_read_open_filename(handle, path, 65_536) == ARCHIVE_OK else {
            throw ArchiveError(path: path, message: ArchiveText.error(handle))
        }
    }

    deinit { archive_read_free(handle) }

    /// The next header, nil at the end. The entry is libarchive's and is
    /// valid until the following call.
    func next() throws -> OpaquePointer? {
        var entry: OpaquePointer?
        switch archive_read_next_header(handle, &entry) {
        case ARCHIVE_OK, ARCHIVE_WARN:
            return entry
        case ARCHIVE_EOF:
            return nil
        default:
            throw ArchiveError(path: path, message: ArchiveText.error(handle))
        }
    }

    /// Compressed bytes consumed so far.
    var bytesRead: Int64 { archive_filter_bytes(handle, -1) }
}
