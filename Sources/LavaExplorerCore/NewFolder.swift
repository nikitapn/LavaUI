import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// Making a folder: the name it is offered under, what a name may be, and
/// the `mkdir` itself.
public enum NewFolder {
    public static let suggestedName = "New Folder"

    /// "New Folder", or "New Folder (2)" and on when that is taken — the name
    /// offered, selected, for the user to type over.
    public static func freeName(
        in directory: String, exists: (String) -> Bool
    ) -> String {
        guard exists(CopyPaths.join(directory, suggestedName)) else { return suggestedName }
        return CopyNaming.keepBoth(
            suggestedName, isDirectory: true, in: directory, exists: exists
        )
    }

    /// Why `name` cannot be a name in a folder, or nil when it can. Only what
    /// the filesystem itself refuses — a slash, the two names that already
    /// mean something, more than a name's 255 bytes — plus an empty one.
    /// Spaces at the ends are trimmed by the caller, not refused here.
    public static func problem(with name: String) -> String? {
        if name.isEmpty { return "A name cannot be empty" }
        if name == "." || name == ".." { return "\u{201C}\(name)\u{201D} is taken by the system" }
        if name.contains("/") { return "A name cannot contain \u{201C}/\u{201D}" }
        if name.contains("\0") { return "A name cannot contain a null character" }
        if name.utf8.count > 255 { return "That name is too long" }
        return nil
    }

    /// Makes `name` in `directory` and returns its path. Never merges into or
    /// replaces something already there: that is a different request.
    public static func make(named raw: String, in directory: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if let problem = problem(with: name) {
            throw FileAccessError(path: directory, message: problem)
        }
        let path = CopyPaths.join(directory, name)
        guard mkdir(path, 0o755) == 0 else {
            let message = errno == EEXIST
                ? "\u{201C}\(name)\u{201D} is already here"
                : String(cString: strerror(errno))
            throw FileAccessError(path: path, message: message)
        }
        return path
    }
}

/// Giving something in a folder another name.
public enum Rename {
    /// How much of `name` a rename selects to begin with: all of it for a
    /// folder, the part before the extension for a file — "report" of
    /// "report.pdf", which is what gets retyped far more often than the
    /// type. A dotfile's leading dot is not an extension.
    public static func stemLength(of name: String, isDirectory: Bool) -> Int {
        let (stem, ext) = CopyNaming.split(name, isDirectory: isDirectory)
        return ext.isEmpty ? name.count : stem.count
    }

    /// Renames `path` in place and returns its new path. The same name is no
    /// change; a name something else already has is refused, never replaced.
    public static func rename(_ path: String, to raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if let problem = NewFolder.problem(with: name) {
            throw FileAccessError(path: path, message: problem)
        }
        let directory = (path as NSString).deletingLastPathComponent
        let destination = CopyPaths.join(directory, name)
        if destination == path { return path }
        // On a case-insensitive filesystem "a" → "A" finds "A" already there,
        // and it is the same file: that one is a rename, not a clash.
        if TrashCan.lexists(destination), !sameFile(path, destination) {
            throw FileAccessError(
                path: destination, message: "\u{201C}\(name)\u{201D} is already here"
            )
        }
        guard Glibc.rename(path, destination) == 0 else {
            throw FileAccessError(path: path, message: String(cString: strerror(errno)))
        }
        return destination
    }

    static func sameFile(_ a: String, _ b: String) -> Bool {
        var sa = stat()
        var sb = stat()
        guard lstat(a, &sa) == 0, lstat(b, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }
}
