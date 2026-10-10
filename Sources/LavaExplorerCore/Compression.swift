import Foundation
import LavaArchive

/// "Compress…": the selection into one new archive beside it.
public enum ArchivePacker {
    /// What the name field starts with. One thing selected is named after
    /// itself, less its extension — `report.pdf` packs to `report.zip`, not
    /// `report.pdf.zip`. Several are named after the folder they are in, which
    /// is what they have in common; at the root there is no such name.
    public static func suggestedName(for paths: [String]) -> String {
        if paths.count == 1 {
            let name = (paths[0] as NSString).lastPathComponent
            return TrashCan.isDirectory(paths[0])
                ? name
                : ArchiveFormat.stem(of: name) ?? CopyNaming.split(name, isDirectory: false).0
        }
        let parent = paths.first.map { ($0 as NSString).deletingLastPathComponent } ?? ""
        let name = (parent as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? "Archive" : name
    }

    /// The path the archive is written to: `name` with the format's
    /// extension, in `directory`, numbered when taken — "photos (2).tar.gz",
    /// not "photos.tar (2).gz", which is what a split at the last dot gives.
    /// An extension typed into the name is not doubled.
    public static func destination(
        named raw: String, format: ArchiveFormat, in directory: String,
        exists: ((String) -> Bool)? = nil
    ) -> String {
        let exists = exists ?? { TrashCan.lexists($0) }
        var name = raw.trimmingCharacters(in: .whitespaces)
        let ext = "." + format.fileExtension
        if name.lowercased().hasSuffix(ext) { name = String(name.dropLast(ext.count)) }
        if name.isEmpty { name = "Archive" }
        let plain = CopyPaths.join(directory, name + ext)
        guard exists(plain) else { return plain }
        for n in 2...9_999 {
            let candidate = CopyPaths.join(directory, "\(name) (\(n))\(ext)")
            if !exists(candidate) { return candidate }
        }
        return CopyPaths.join(directory, "\(name) (\(UUID().uuidString.prefix(8)))\(ext)")
    }

    /// A name the field must refuse: one that is not a single file name.
    public static func isUsableName(_ raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }
}
