import CArchive
import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// What `create` packed.
public struct CreateOutcome: Equatable, Sendable {
    /// Entries written: files, folders and links alike.
    public var added = 0
    /// Things under the sources that could not be read — a file without
    /// permission, one that vanished mid-walk. Left out; the archive is still
    /// made from the rest.
    public var failures: [ArchiveError] = []
    /// Stopped by the progress callback, in which case there is no archive:
    /// half of one is not something anyone wants left behind.
    public var cancelled = false

    public init() {}
}

extension Archive {
    /// Packs `sources` into a new archive at `archivePath`.
    ///
    /// Each source goes in under its own name, so selecting `photos` and
    /// `notes.txt` in a folder gives an archive with `photos/…` and
    /// `notes.txt` at the top — what every file manager does. Symlinks are
    /// stored as links, not followed.
    ///
    /// Written beside the destination under a hidden name and renamed into
    /// place only when complete, so a failed or cancelled run leaves nothing,
    /// and nobody ever opens a half-written archive by the name it will have.
    /// Refuses a destination that already exists; choosing a free name is the
    /// caller's (`CopyNaming.keepBoth` in the explorer).
    ///
    /// With a `password`, every file's contents are encrypted with WinZip
    /// AES-256. Zip only (`ArchiveFormat.supportsPassword`): libarchive's 7z
    /// and tar writers have no encryption. The names stay readable — zip
    /// encrypts contents, never the directory — which is worth knowing before
    /// a file name is the secret.
    ///
    /// Throws when the archive cannot be written at all — the folder is not
    /// writable, the disk filled up — or a password was given for a format
    /// that cannot hold one.
    public static func create(
        _ archivePath: String, format: ArchiveFormat, from sources: [String],
        password: String? = nil,
        progress: ((ArchiveProgress) -> Bool)? = nil
    ) throws -> CreateOutcome {
        try withUTF8Locale {
            try createUnlocked(
                archivePath, format: format, from: sources, password: password,
                progress: progress
            )
        }
    }

    private static func createUnlocked(
        _ archivePath: String, format: ArchiveFormat, from sources: [String],
        password: String?, progress: ((ArchiveProgress) -> Bool)?
    ) throws -> CreateOutcome {
        guard !lexists(archivePath) else {
            throw ArchiveError(path: archivePath, message: "Already exists")
        }
        let password = password.flatMap { $0.isEmpty ? nil : $0 }
        if password != nil, !format.supportsPassword {
            throw ArchiveError(
                path: archivePath, message: "A \(format.fileExtension) cannot have a password"
            )
        }
        let folder = (archivePath as NSString).deletingLastPathComponent
        let name = (archivePath as NSString).lastPathComponent
        let temporary = (folder.isEmpty ? "." : folder)
            + "/.\(name).lava-archive-\(UUID().uuidString.prefix(8))"

        guard let writer = archive_write_new() else {
            throw ArchiveError(path: archivePath, message: "Out of memory")
        }
        defer { archive_write_free(writer) }
        try configure(writer, format: format, path: archivePath)
        if let password {
            // AES rather than the original zip cipher, which is broken to
            // the point of being a formality. The cost is the reader: Windows'
            // own zip support and Info-ZIP `unzip` open only the old one; 7-Zip,
            // libarchive and every Linux archive tool open this.
            guard archive_write_set_options(writer, "zip:encryption=aes256") == ARCHIVE_OK,
                  archive_write_set_passphrase(writer, password) == ARCHIVE_OK
            else {
                throw ArchiveError(path: archivePath, message: ArchiveText.error(writer))
            }
        }
        guard archive_write_open_filename(writer, temporary) == ARCHIVE_OK else {
            throw ArchiveError(path: archivePath, message: ArchiveText.error(writer))
        }

        guard let disk = archive_read_disk_new() else {
            throw ArchiveError(path: archivePath, message: "Out of memory")
        }
        defer { archive_read_free(disk) }
        // Store a link as a link. Following it would pack whatever it points
        // at — a link to `/` would try to pack the machine.
        archive_read_disk_set_symlink_physical(disk)
        // Owner and group names, which tar records beside the ids.
        archive_read_disk_set_standard_lookup(disk)

        let total = sources.reduce(Int64(0)) { $0 + bytes(under: $1) }
        var done: Int64 = 0
        var outcome = CreateOutcome()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var fatal: ArchiveError?

        sources: for raw in sources {
            let source = ArchivePaths.tidy(raw)
            let base = (source as NSString).lastPathComponent
            guard archive_read_disk_open(disk, source) == ARCHIVE_OK else {
                outcome.failures.append(
                    ArchiveError(path: source, message: ArchiveText.error(disk))
                )
                continue
            }
            defer { archive_read_close(disk) }
            while true {
                guard let entry = archive_entry_new() else { break sources }
                defer { archive_entry_free(entry) }
                let read = archive_read_next_header2(disk, entry)
                if read == ARCHIVE_EOF { break }
                if read < ARCHIVE_WARN {
                    outcome.failures.append(
                        ArchiveError(path: source, message: ArchiveText.error(disk))
                    )
                    if read == ARCHIVE_FATAL { break }
                    continue
                }
                let onDisk = archive_entry_sourcepath(entry).map { String(cString: $0) }
                    ?? source
                // Into a folder it is packing: never pack the output.
                if onDisk == temporary || onDisk.hasSuffix("/" + (temporary as NSString).lastPathComponent) {
                    continue
                }
                // Folders are only walked into when asked, which is the place
                // to skip one; nothing is skipped, so always ask.
                archive_read_disk_descend(disk)
                let stored = base + onDisk.dropFirst(source.count)
                archive_entry_update_pathname_utf8(entry, stored)

                guard progress?(ArchiveProgress(
                    entry: stored, bytesDone: done, bytesTotal: total
                )) ?? true else {
                    outcome.cancelled = true
                    break sources
                }
                let wrote = archive_write_header(writer, entry)
                if wrote < ARCHIVE_WARN {
                    let error = ArchiveError(path: stored, message: ArchiveText.error(writer))
                    if wrote == ARCHIVE_FATAL {
                        fatal = error
                        break sources
                    }
                    outcome.failures.append(error)
                    continue
                }
                if archive_entry_filetype(entry) == UInt32(LAVA_AE_IFREG) {
                    while true {
                        let count = buffer.withUnsafeMutableBytes {
                            archive_read_data(disk, $0.baseAddress, $0.count)
                        }
                        if count == 0 { break }
                        if count < 0 {
                            outcome.failures.append(
                                ArchiveError(path: stored, message: ArchiveText.error(disk))
                            )
                            break
                        }
                        let put = buffer.withUnsafeBytes {
                            archive_write_data(writer, $0.baseAddress, count)
                        }
                        if put < 0 {
                            fatal = ArchiveError(path: stored, message: ArchiveText.error(writer))
                            break sources
                        }
                        done += Int64(count)
                        guard progress?(ArchiveProgress(
                            entry: stored, bytesDone: done, bytesTotal: total
                        )) ?? true else {
                            outcome.cancelled = true
                            break sources
                        }
                    }
                }
                outcome.added += 1
            }
        }

        // Close before judging: the last compressed block and a zip's whole
        // central directory are written here, and a full disk shows up now.
        let closed = archive_write_close(writer)
        if fatal == nil, closed != ARCHIVE_OK {
            fatal = ArchiveError(path: archivePath, message: ArchiveText.error(writer))
        }
        if let fatal {
            unlink(temporary)
            throw fatal
        }
        if outcome.cancelled {
            unlink(temporary)
            return outcome
        }
        guard rename(temporary, archivePath) == 0 else {
            let message = String(cString: strerror(errno))
            unlink(temporary)
            throw ArchiveError(path: archivePath, message: message)
        }
        return outcome
    }

    private static func configure(
        _ writer: OpaquePointer, format: ArchiveFormat, path: String
    ) throws {
        var result: Int32
        switch format {
        case .zip:
            result = archive_write_set_format_zip(writer)
            archive_write_zip_set_compression_deflate(writer)
        case .sevenZip:
            result = archive_write_set_format_7zip(writer)
        case .tar, .tarGzip, .tarBzip2, .tarXz, .tarZstd:
            // What bsdtar writes: plain ustar, with pax headers only for
            // what ustar cannot say — a long or non-ASCII name, a big file.
            result = archive_write_set_format_pax_restricted(writer)
        }
        guard result == ARCHIVE_OK else {
            throw ArchiveError(path: path, message: ArchiveText.error(writer))
        }
        switch format {
        case .tarGzip: result = archive_write_add_filter_gzip(writer)
        case .tarBzip2: result = archive_write_add_filter_bzip2(writer)
        case .tarXz: result = archive_write_add_filter_xz(writer)
        case .tarZstd: result = archive_write_add_filter_zstd(writer)
        case .zip, .tar, .sevenZip: result = ARCHIVE_OK
        }
        guard result == ARCHIVE_OK else {
            throw ArchiveError(path: path, message: ArchiveText.error(writer))
        }
    }

    /// What the regular files under `path` add up to — the denominator for
    /// progress. Links are not followed, as the packing does not follow them.
    static func bytes(under path: String) -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        if (info.st_mode & S_IFMT) == S_IFREG { return Int64(info.st_size) }
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              let children = try? FileManager.default.contentsOfDirectory(atPath: path)
        else { return 0 }
        return children.reduce(0) { $0 + bytes(under: path + "/" + $1) }
    }
}
