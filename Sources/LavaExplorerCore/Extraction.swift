import Foundation
import LavaArchive

#if canImport(Glibc)
import Glibc
#endif

/// "Extract here": an archive's contents next to it, under a name nobody
/// else is using.
///
/// The rule every file manager converged on. An archive that holds one thing
/// at the top — `project/…`, or a single file — gives that thing, under its
/// own name. One that holds several gives a folder named after the archive
/// with all of them inside, because spilling forty files into Downloads is
/// the one outcome nobody wants. A name already taken gets "(2)", as a copy
/// does: extracting never overwrites.
///
/// Which case it is cannot be known without reading the archive, and reading
/// a tarball means decompressing all of it. So it is extracted once, into a
/// hidden folder beside the archive, and the answer is read off what landed
/// there — then renamed into place, which on one filesystem is free. The
/// hidden folder also means a cancelled or broken run leaves nothing behind
/// but what it says it left.
public enum ArchiveUnpacker {
    public struct Outcome: Equatable, Sendable {
        /// Where the contents ended up — the one item, or the folder holding
        /// several. Nil when nothing was extracted at all.
        public var result: String?
        /// The entry-by-entry account, for failures and skips.
        public var extraction: ExtractOutcome
    }

    /// Unpacks `archive` into `directory` by the rule above. Blocking.
    ///
    /// Throws only when there is nothing to show for it: the archive cannot
    /// be opened, or the folder cannot be written to. A run cancelled from
    /// `progress`, or stopped for a password (`extraction.needsPassword`,
    /// `.wrongPassword`), returns with `result` nil and the half-extracted
    /// contents removed — an archive is extracted whole or not at all, so
    /// asking for a password and running again starts from nothing.
    public static func extractHere(
        _ archive: String, into directory: String, password: String? = nil,
        progress: ((ArchiveProgress) -> Bool)? = nil
    ) throws -> Outcome {
        let name = (archive as NSString).lastPathComponent
        let stem = ArchiveFormat.stem(of: name) ?? name
        let staging = CopyPaths.join(
            directory, ".\(stem).lava-extract-\(UUID().uuidString.prefix(8))"
        )
        do {
            try FileManager.default.createDirectory(
                atPath: staging, withIntermediateDirectories: false
            )
        } catch {
            throw FileAccessError(path: directory, message: error.localizedDescription)
        }

        let extraction: ExtractOutcome
        do {
            extraction = try Archive.extract(
                archive, into: staging, password: password, progress: progress
            )
        } catch {
            try? FileManager.default.removeItem(atPath: staging)
            throw error
        }
        let landed = (try? FileManager.default.contentsOfDirectory(atPath: staging)) ?? []
        guard !extraction.cancelled, !extraction.needsPassword,
              !extraction.wrongPassword, !landed.isEmpty
        else {
            try? FileManager.default.removeItem(atPath: staging)
            return Outcome(result: nil, extraction: extraction)
        }

        do {
            if landed.count == 1 {
                let only = CopyPaths.join(staging, landed[0])
                let result = freeName(
                    landed[0], isDirectory: TrashCan.isDirectory(only), in: directory
                )
                try move(only, to: result)
                try? FileManager.default.removeItem(atPath: staging)
                return Outcome(result: result, extraction: extraction)
            }
            let result = freeName(stem, isDirectory: true, in: directory)
            try move(staging, to: result)
            return Outcome(result: result, extraction: extraction)
        } catch {
            try? FileManager.default.removeItem(atPath: staging)
            throw error
        }
    }

    /// `name` itself if nothing is using it, otherwise the next free
    /// "name (n)". `CopyNaming.keepBoth` starts at "(2)" — it is only asked
    /// once the plain name is known to be taken.
    private static func freeName(
        _ name: String, isDirectory: Bool, in directory: String
    ) -> String {
        let plain = CopyPaths.join(directory, name)
        guard TrashCan.lexists(plain) else { return plain }
        return CopyPaths.join(directory, CopyNaming.keepBoth(
            name, isDirectory: isDirectory, in: directory, exists: TrashCan.lexists
        ))
    }

    /// `rename(2)`, which here never crosses a filesystem: the staging
    /// folder is made beside its destination for exactly that reason.
    private static func move(_ from: String, to: String) throws {
        guard rename(from, to) == 0 else {
            throw FileAccessError(path: to, message: String(cString: strerror(errno)))
        }
    }

    /// Whether a file is worth offering "Extract here" for. By name, because
    /// a menu is built on every right-click and opening the file to look is
    /// not something a menu should do.
    public static func looksLikeArchive(_ entry: FileEntry) -> Bool {
        !entry.isDirectory && ArchiveFormat.stem(of: entry.name) != nil
    }
}
