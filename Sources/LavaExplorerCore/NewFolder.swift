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
        if name.isEmpty { return "A folder needs a name" }
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
