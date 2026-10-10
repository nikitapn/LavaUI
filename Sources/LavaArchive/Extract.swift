import CArchive
import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// What an extraction did, entry by entry. Errors with one entry do not stop
/// the rest — a zip with one corrupt member still has ninety-nine good ones —
/// so they are collected here, and only a broken archive throws.
public struct ExtractOutcome: Equatable, Sendable {
    /// Entries written: files, folders and links alike.
    public var extracted = 0
    /// Left alone because something by that name was already there and the
    /// call was not told to replace. Relative to the destination.
    public var skipped: [String] = []
    /// Entries that could not be written, and entries refused outright — a
    /// name that climbs out of the folder, a device node, an encrypted file.
    public var failures: [ArchiveError] = []
    /// The top-level paths the extraction brought into being, absolute and in
    /// the order they first appeared: what Undo would take away, and what a
    /// window selects afterwards. A folder that existed before and was merged
    /// into is not in it.
    public var created: [String] = []
    /// Stopped by the progress callback. What was written up to then stays,
    /// and is in `created`; the entry being written when it stopped does not.
    public var cancelled = false
    /// Stopped at the first encrypted entry, with no password to open it.
    /// Ask for one and run again; what came before it was written.
    public var needsPassword = false
    /// Stopped because the password given does not open the archive.
    public var wrongPassword = false

    public init() {}
}

extension Archive {
    /// Unpacks `path` into `directory`, which must exist.
    ///
    /// Nothing is written outside `directory`: names with `..` are refused,
    /// absolute names are made relative to it, and libarchive is told to
    /// refuse writing *through* a symlink — so an archive that first makes
    /// `x → /etc` and then writes `x/passwd` gets the link and not the file.
    /// Symlinks themselves are extracted as they are, wherever they point:
    /// a link is not a write.
    ///
    /// Ownership is not restored (it is not ours to give away), and neither
    /// are setuid bits; permissions are what the archive says less the umask,
    /// as `tar` does for anyone but root. Modification times are kept.
    ///
    /// `password` opens an encrypted zip. Without one, extraction stops at the
    /// first encrypted entry and says so (`needsPassword`); with a wrong one
    /// it stops there too (`wrongPassword`) — a caller asks and runs again,
    /// rather than getting an archive's worth of identical failures. Only zip
    /// is decrypted: libarchive can *see* an encrypted 7z or rar entry but
    /// not open it, and that is a plain failure, since no password would help.
    ///
    /// With `replace` false, a name that is already taken is skipped — a
    /// folder is merged into, never skipped, since its contents are asked
    /// about one by one. With it true, files are overwritten.
    ///
    /// Throws when the archive cannot be read at all, or the folder is not
    /// there. A header that turns out corrupt partway is a failure in the
    /// outcome and ends the run: there is no next header to find after it.
    public static func extract(
        _ path: String, into directory: String, replace: Bool = false,
        password: String? = nil,
        progress: ((ArchiveProgress) -> Bool)? = nil
    ) throws -> ExtractOutcome {
        try withUTF8Locale {
            try extractUnlocked(
                path, into: directory, replace: replace, password: password,
                progress: progress
            )
        }
    }

    private static func extractUnlocked(
        _ path: String, into directory: String, replace: Bool,
        password: String?, progress: ((ArchiveProgress) -> Bool)?
    ) throws -> ExtractOutcome {
        // Resolved, because the symlink check below covers every component of
        // the name it is given — including the folder's own, which may well
        // sit under a link the user made on purpose (`~/Downloads` → a second
        // disk). Checked from a real path, only the archive's part is judged.
        guard let real = realpath(directory, nil) else {
            throw ArchiveError(path: directory, message: String(cString: strerror(errno)))
        }
        let root = String(cString: real)
        free(real)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir),
              isDir.boolValue
        else { throw ArchiveError(path: directory, message: "Not a folder") }

        let reader = try ArchiveReader(path: path, password: password)
        let total = (try? FileManager.default.attributesOfItem(atPath: path)[.size]
            as? Int64) ?? 0
        guard let disk = archive_write_disk_new() else {
            throw ArchiveError(path: path, message: "Out of memory")
        }
        defer { archive_write_free(disk) }
        let flags = ARCHIVE_EXTRACT_TIME
            | ARCHIVE_EXTRACT_SECURE_SYMLINKS
            | ARCHIVE_EXTRACT_SECURE_NODOTDOT
        archive_write_disk_set_options(disk, flags)

        var outcome = ExtractOutcome()
        var topLevel: [String: Bool] = [:]
        var block = (UnsafeRawPointer?.none, 0, Int64(0))

        func keepGoing(_ entry: String) -> Bool {
            guard let progress else { return true }
            return progress(ArchiveProgress(
                entry: entry, bytesDone: reader.bytesRead, bytesTotal: total
            ))
        }

        entries: while true {
            let header: OpaquePointer
            do {
                guard let next = try reader.next() else { break }
                header = next
            } catch let error as ArchiveError {
                outcome.failures.append(error)
                break
            }
            guard let entry = ArchiveEntry(header) else { continue }
            guard let relative = ArchivePaths.safeRelative(entry.path) else {
                outcome.failures.append(
                    ArchiveError(path: entry.path, message: "Refused: it would land outside the folder")
                )
                continue
            }
            if entry.kind == .other {
                outcome.failures.append(
                    ArchiveError(path: relative, message: "Not a file, folder or link — left out")
                )
                continue
            }
            if entry.isEncrypted {
                let format = archive_format(reader.handle) & ARCHIVE_FORMAT_BASE_MASK
                guard format == ARCHIVE_FORMAT_ZIP else {
                    outcome.failures.append(ArchiveError(
                        path: relative, message: "Encrypted, and only an encrypted zip can be opened"
                    ))
                    continue
                }
                if password?.isEmpty ?? true {
                    outcome.needsPassword = true
                    break
                }
            }
            if entry.kind == .hardlink {
                guard let target = entry.linkTarget.flatMap(ArchivePaths.safeRelative)
                else {
                    outcome.failures.append(
                        ArchiveError(path: relative, message: "Refused: a link to outside the folder")
                    )
                    continue
                }
                archive_entry_update_hardlink_utf8(header, root + "/" + target)
            }

            let destination = root + "/" + relative
            let top = String(relative.prefix { $0 != "/" })
            if topLevel[top] == nil {
                let existed = lexists(root + "/" + top)
                topLevel[top] = existed
                if !existed { outcome.created.append(root + "/" + top) }
            }
            if !replace, lexists(destination),
               !(entry.kind == .directory && isDirectory(destination))
            {
                outcome.skipped.append(relative)
                continue
            }

            archive_entry_update_pathname_utf8(header, destination)
            guard keepGoing(entry.path) else {
                outcome.cancelled = true
                break
            }
            let wrote = archive_write_header(disk, header)
            if wrote < ARCHIVE_WARN {
                outcome.failures.append(
                    ArchiveError(path: relative, message: ArchiveText.error(disk))
                )
                if wrote == ARCHIVE_FATAL { break }
                continue
            }

            // `read_data_block` rather than `read_data`: it hands back the
            // offset as well, so a sparse file in a tar stays sparse.
            while true {
                let read = archive_read_data_block(
                    reader.handle, &block.0, &block.1, &block.2
                )
                if read == ARCHIVE_EOF { break }
                if read < ARCHIVE_WARN {
                    let message = ArchiveText.error(reader.handle)
                    archive_write_finish_entry(disk)
                    unlink(destination)
                    // libarchive's word for it, from both zip ciphers. Asked
                    // of the message because the code is the same as for a
                    // corrupt entry, which a new password would not fix.
                    if entry.isEncrypted, message.lowercased().contains("passphrase") {
                        outcome.wrongPassword = true
                        break entries
                    }
                    outcome.failures.append(ArchiveError(path: relative, message: message))
                    if read == ARCHIVE_FATAL { break entries }
                    continue entries
                }
                if archive_write_data_block(disk, block.0, block.1, block.2) < ARCHIVE_WARN {
                    outcome.failures.append(
                        ArchiveError(path: relative, message: ArchiveText.error(disk))
                    )
                    archive_write_finish_entry(disk)
                    unlink(destination)
                    continue entries
                }
                guard keepGoing(entry.path) else {
                    outcome.cancelled = true
                    archive_write_finish_entry(disk)
                    unlink(destination)
                    break entries
                }
            }
            if archive_write_finish_entry(disk) < ARCHIVE_WARN {
                outcome.failures.append(
                    ArchiveError(path: relative, message: ArchiveText.error(disk))
                )
                continue
            }
            outcome.extracted += 1
        }
        // Folder times are set here, not as each folder is made: writing
        // the files into a folder would move its time on again.
        archive_write_close(disk)
        return outcome
    }

    static func lexists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Runs `body` with this thread's character set as UTF-8.
    ///
    /// libarchive converts every name through the locale's charset, and a
    /// Swift process stays in "C", where nothing outside ASCII converts —
    /// "Can't translate pathname" on the first accented file name. Per
    /// thread, through `uselocale`, so the rest of the process keeps the
    /// locale it had; a worker thread is what calls this anyway.
    static func withUTF8Locale<T>(_ body: () throws -> T) rethrows -> T {
        guard let utf8 = newlocale(LC_CTYPE_MASK, "C.UTF-8", nil) else {
            return try body()
        }
        let previous = uselocale(utf8)
        defer {
            uselocale(previous)
            freelocale(utf8)
        }
        return try body()
    }
}
