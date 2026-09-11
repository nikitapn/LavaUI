import Foundation

/// Files dropped on a folder, sorted into what happens to each — before
/// anything is touched.
///
/// Planning and doing are separate on purpose. Whether a name is already
/// taken is a question the user has to answer before a byte moves; a copy
/// that discovered it halfway through would have to stop with half a drop on
/// the disk. So the plan finds every clash first, the window asks once, and
/// only then does `FileCopier` run.
public struct CopyPlan: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var source: String
        public var name: String
        public var isDirectory: Bool
        /// Something by this name is already in the destination — or an
        /// earlier item in the same drop will have put it there.
        public var clashes: Bool
    }

    public enum Refusal: Equatable, Sendable {
        /// Already in the folder it was dropped on. Nothing to do, and not an
        /// error: a file let go of where it was picked up.
        case alreadyThere(String)
        /// A folder dropped on itself or on something inside it — a copy that
        /// would keep finding its own output.
        case intoItself(String)
        case missing(String)
    }

    public var directory: String
    public var items: [Item]
    public var refused: [Refusal]

    public var clashes: [Item] { items.filter(\.clashes) }

    public static func make(
        sources: [String], into directory: String, source files: any FileSource
    ) -> CopyPlan {
        let target = CopyPaths.normalize(directory)
        var plan = CopyPlan(directory: target, items: [], refused: [])
        var seen = Set<String>()
        var names = Set<String>()
        for raw in sources {
            let path = CopyPaths.normalize(raw)
            guard seen.insert(path).inserted else { continue }
            guard let entry = try? files.entry(at: path) else {
                plan.refused.append(.missing(path))
                continue
            }
            if CopyPaths.normalize((path as NSString).deletingLastPathComponent) == target {
                plan.refused.append(.alreadyThere(path))
                continue
            }
            if entry.isDirectory, CopyPaths.contains(path, target) {
                plan.refused.append(.intoItself(path))
                continue
            }
            let name = (path as NSString).lastPathComponent
            let taken = files.exists(CopyPaths.join(target, name)) || names.contains(name)
            names.insert(name)
            plan.items.append(
                Item(source: path, name: name, isDirectory: entry.isDirectory, clashes: taken)
            )
        }
        return plan
    }
}

/// What to do with every name that is already taken.
///
/// One answer for the whole drop. Asking per file is what a copy dialog does
/// when it has a progress bar to hang the question from; this window has a
/// bar across the top, and a drop of twenty photos into a folder holding
/// three of them wants one answer, not three.
public enum ClashChoice: Equatable, Sendable {
    /// A file is replaced; a folder is merged into. See `FileCopier.replace`.
    case replace
    /// Copied under a free name — "report (2).pdf".
    case keepBoth
    case skip
}

public struct CopyOutcome: Equatable, Sendable {
    public var copied = 0
    public var skipped = 0
    public var failures: [FileAccessError] = []

    public init() {}
}

/// Free names for a copy that must not overwrite.
public enum CopyNaming {
    /// "report.pdf" → "report (2).pdf", then "(3)" and on, until `exists`
    /// says the name is free. A folder has no extension, and neither does a
    /// dotfile whose only dot is the leading one.
    public static func keepBoth(
        _ name: String, isDirectory: Bool, in directory: String,
        exists: (String) -> Bool
    ) -> String {
        let (stem, ext) = split(name, isDirectory: isDirectory)
        for n in 2...9_999 {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            if !exists(CopyPaths.join(directory, candidate)) { return candidate }
        }
        // Ten thousand copies of one name is not a folder anyone browses;
        // a unique suffix still beats refusing.
        return "\(stem) (\(UUID().uuidString.prefix(8)))" + (ext.isEmpty ? "" : ".\(ext)")
    }

    static func split(_ name: String, isDirectory: Bool) -> (String, String) {
        guard !isDirectory,
              let dot = name.lastIndex(of: "."),
              dot != name.startIndex
        else { return (name, "") }
        let ext = name[name.index(after: dot)...]
        guard !ext.isEmpty else { return (name, "") }
        return (String(name[..<dot]), String(ext))
    }
}

/// Carries out a `CopyPlan`.
///
/// Blocking, and meant for a worker thread: a folder of photos takes as long
/// as the disk takes, and a frame loop waiting on it is a window that stops
/// answering.
public enum FileCopier {
    public static func run(
        _ plan: CopyPlan, clashes choice: ClashChoice,
        fileManager: FileManager = .default
    ) -> CopyOutcome {
        var outcome = CopyOutcome()
        for item in plan.items {
            let destination = CopyPaths.join(plan.directory, item.name)
            do {
                // Asked again rather than read off the plan: the disk may
                // have changed since, and an earlier item in this drop can
                // have taken the name.
                guard fileManager.fileExists(atPath: destination) else {
                    try fileManager.copyItem(atPath: item.source, toPath: destination)
                    outcome.copied += 1
                    continue
                }
                switch choice {
                case .skip:
                    outcome.skipped += 1
                case .keepBoth:
                    let name = CopyNaming.keepBoth(
                        item.name, isDirectory: item.isDirectory, in: plan.directory,
                        exists: { fileManager.fileExists(atPath: $0) }
                    )
                    try fileManager.copyItem(
                        atPath: item.source, toPath: CopyPaths.join(plan.directory, name)
                    )
                    outcome.copied += 1
                case .replace:
                    try replace(source: item.source, destination: destination, fileManager: fileManager)
                    outcome.copied += 1
                }
            } catch let error as FileAccessError {
                outcome.failures.append(error)
            } catch {
                outcome.failures.append(
                    FileAccessError(path: item.source, message: error.localizedDescription)
                )
            }
        }
        return outcome
    }

    /// Replaces `destination` with a copy of `source`.
    ///
    /// A file is replaced only once its copy is whole: copied beside the
    /// original under a hidden temporary name, then renamed over it, which is
    /// atomic. A copy that fails halfway leaves the original as it was.
    ///
    /// A folder is **merged** into rather than replaced. Replacing it
    /// wholesale deletes everything in the destination the drop did not
    /// bring, and nobody answering "replace?" about a name means that — it is
    /// also what Windows Explorer does. Clashing files inside are replaced by
    /// the same rule, all the way down.
    static func replace(
        source: String, destination: String, fileManager: FileManager
    ) throws {
        var sourceIsDir: ObjCBool = false
        var destinationIsDir: ObjCBool = false
        _ = fileManager.fileExists(atPath: source, isDirectory: &sourceIsDir)
        _ = fileManager.fileExists(atPath: destination, isDirectory: &destinationIsDir)

        if sourceIsDir.boolValue, destinationIsDir.boolValue {
            for child in try fileManager.contentsOfDirectory(atPath: source) {
                let from = CopyPaths.join(source, child)
                let to = CopyPaths.join(destination, child)
                if fileManager.fileExists(atPath: to) {
                    try replace(source: from, destination: to, fileManager: fileManager)
                } else {
                    try fileManager.copyItem(atPath: from, toPath: to)
                }
            }
            return
        }
        guard sourceIsDir.boolValue == destinationIsDir.boolValue else {
            // A folder over a file or a file over a folder is not a
            // replacement anybody asked for by name.
            throw FileAccessError(
                path: destination,
                message: destinationIsDir.boolValue
                    ? "A folder with that name is in the way"
                    : "A file with that name is in the way"
            )
        }

        let directory = (destination as NSString).deletingLastPathComponent
        let name = (destination as NSString).lastPathComponent
        let temporary = CopyPaths.join(
            directory, ".\(name).lava-copy-\(UUID().uuidString.prefix(8))"
        )
        try fileManager.copyItem(atPath: source, toPath: temporary)
        guard rename(temporary, destination) == 0 else {
            let message = String(cString: strerror(errno))
            try? fileManager.removeItem(atPath: temporary)
            throw FileAccessError(path: destination, message: message)
        }
    }
}

enum CopyPaths {
    static func normalize(_ path: String) -> String {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        return standard.isEmpty ? "/" : standard
    }

    static func join(_ directory: String, _ name: String) -> String {
        (directory as NSString).appendingPathComponent(name)
    }

    /// Whether `inner` is `outer` or somewhere beneath it.
    static func contains(_ outer: String, _ inner: String) -> Bool {
        if outer == "/" { return true }
        return inner == outer || inner.hasPrefix(outer + "/")
    }
}
