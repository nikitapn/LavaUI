import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// Renaming many things in one folder at once, from a text buffer that holds
/// one new name per line — line *n* is the new name of item *n*.
///
/// The buffer is the interface on purpose: a find/replace, a case change and
/// a hand edit of one line are all just edits to it, and so is a round trip
/// through `$EDITOR`. This type only answers two questions about it — what
/// would happen (`plan`), and doing it (`apply`) — and the second is the hard
/// one, because a list of independent `rename(2)`s is wrong as soon as two
/// names trade places: "a → b" first overwrites b, and "b → a" second then
/// moves a's contents back where they came from. So `apply` orders the moves
/// by what is free, breaks a cycle through a hidden temporary name, never
/// replaces anything, and puts everything back if any step fails.
public enum BulkRename {
    /// What becomes of one item.
    public enum Outcome: Equatable, Sendable {
        /// Its line is its own name; nothing is done to it.
        case unchanged
        case renamed
        /// Why this line cannot be applied. Any one of these blocks the lot:
        /// half a bulk rename is a folder nobody asked for.
        case problem(String)
    }

    public struct Row: Equatable, Sendable {
        public var name: String
        public var newName: String
        public var outcome: Outcome
    }

    public struct Plan: Equatable, Sendable {
        public var directory: String
        public var rows: [Row]
        /// What is wrong with the buffer as a whole — the wrong number of
        /// lines — as opposed to with one row.
        public var problem: String?
        /// The renames, as whole paths, for the rows that change.
        public var moves: [FileMove]

        public var canApply: Bool {
            problem == nil && !moves.isEmpty && !rows.contains {
                if case .problem = $0.outcome { true } else { false }
            }
        }
    }

    /// The buffer an edit starts from: the names, one a line.
    public static func text(of names: [String]) -> String {
        names.joined(separator: "\n")
    }

    /// The buffer's lines. A trailing newline is not a line — every editor
    /// that saves a file adds one — and neither is a `\r` from one that saves
    /// CRLF.
    public static func lines(of text: String) -> [String] {
        // "\r\n" is one Character in Swift, so splitting on "\n" alone
        // never finds it.
        var lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
            .map(String.init)
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }

    /// What applying `text` to `names` (in `directory`, in the order the
    /// buffer was made from) would do, against the disk.
    public static func plan(directory: String, names: [String], text: String) -> Plan {
        plan(directory: directory, names: names, text: text) { name, source in
            let path = CopyPaths.join(directory, name)
            // On a case-insensitive filesystem "a" → "A" finds "A" already
            // there, and it is the same file.
            return TrashCan.lexists(path)
                && !Rename.sameFile(CopyPaths.join(directory, source), path)
        }
    }

    /// The same, with the folder's contents behind `isTaken(name, source)`:
    /// whether `name` is held by something other than the item `source`.
    /// Only asked about names that are not themselves being renamed away.
    public static func plan(
        directory: String, names: [String], text: String,
        isTaken: (_ name: String, _ source: String) -> Bool
    ) -> Plan {
        let lines = lines(of: text)
        var problem: String?
        if lines.count != names.count {
            problem = "\(lines.count) \(lines.count == 1 ? "name" : "names") for "
                + "\(names.count) \(names.count == 1 ? "item" : "items")"
        }

        var rows: [Row] = names.enumerated().map { index, name in
            guard index < lines.count else {
                return Row(name: name, newName: name, outcome: .problem("No line for this item"))
            }
            let newName = lines[index].trimmingCharacters(in: .whitespaces)
            if newName == name { return Row(name: name, newName: name, outcome: .unchanged) }
            if let why = NewFolder.problem(with: newName) {
                return Row(name: name, newName: newName, outcome: .problem(why))
            }
            return Row(name: name, newName: newName, outcome: .renamed)
        }

        // Two rows ending under one name. An unchanged row counts: it keeps
        // the name it has.
        var holders: [String: [Int]] = [:]
        for (index, row) in rows.enumerated() {
            holders[row.newName, default: []].append(index)
        }
        for (name, indices) in holders where indices.count > 1 {
            for index in indices where rows[index].outcome == .renamed {
                rows[index].outcome = .problem("\u{201C}\(name)\u{201D} is on another line too")
            }
        }

        // A name something outside the list already has. A name in the list
        // is either left by its row, and free by the time it is needed, or
        // kept by it, which was caught just above.
        let listed = Set(names)
        for index in rows.indices where rows[index].outcome == .renamed {
            let target = rows[index].newName
            if !listed.contains(target), isTaken(target, rows[index].name) {
                rows[index].outcome = .problem("\u{201C}\(target)\u{201D} is already here")
            }
        }

        let moves = rows.filter { $0.outcome == .renamed }.map {
            FileMove(from: CopyPaths.join(directory, $0.name), to: CopyPaths.join(directory, $0.newName))
        }
        return Plan(directory: directory, rows: rows, problem: problem, moves: moves)
    }

    /// `moves` as steps to replay, one at a time, on paths that point into
    /// them — tabs, history, remembered views (`FolderHistory.rebased`).
    ///
    /// The moves happened together, and replaying them in order is wrong as
    /// soon as two folders traded names: "a → b" sends a tab in a to b, and
    /// "b → a" then sends it straight back, along with the tab that really was
    /// in b. So when any target is also a source, everything goes through a
    /// placeholder first — a path with a NUL in it, which no file can have.
    public static func relocationSteps(_ moves: [FileMove]) -> [FileMove] {
        let sources = Set(moves.map(\.from))
        guard moves.contains(where: { sources.contains($0.to) }) else { return moves }
        let parked = moves.indices.map { "/\u{0}lava-bulk-rename/\($0)" }
        return moves.indices.map { FileMove(from: moves[$0].from, to: parked[$0]) }
            + moves.indices.map { FileMove(from: parked[$0], to: moves[$0].to) }
    }

    // MARK: - Applying

    /// Performs `moves` — all of them, or, if any step fails, none: what was
    /// done is put back before the error is thrown. Checked against the disk
    /// first, because a plan can be minutes old by the time it is applied and
    /// an undo can be hours old.
    ///
    /// Every step refuses to replace anything (`RENAME_NOREPLACE`), so a file
    /// that appears under a target name between the check and the step makes
    /// the step fail rather than vanish.
    @discardableResult
    public static func apply(_ moves: [FileMove]) throws -> [FileMove] {
        let moves = moves.filter { $0.from != $0.to }
        try check(moves)
        var done: [FileMove] = []
        do {
            try perform(moves, recording: &done)
        } catch let error as FileAccessError {
            let stuck = rollBack(done)
            guard stuck.isEmpty else {
                let names = stuck.map { "\u{201C}\(($0 as NSString).lastPathComponent)\u{201D}" }
                throw FileAccessError(
                    path: error.path,
                    message: error.message + "; could not put back " + names.joined(separator: ", ")
                )
            }
            throw error
        }
        return moves
    }

    static func check(_ moves: [FileMove]) throws {
        let sources = Set(moves.map(\.from))
        var targets = Set<String>()
        for move in moves {
            let name = "\u{201C}\((move.from as NSString).lastPathComponent)\u{201D}"
            guard TrashCan.lexists(move.from) else {
                throw FileAccessError(path: move.from, message: "\(name) is no longer here")
            }
            let target = "\u{201C}\((move.to as NSString).lastPathComponent)\u{201D}"
            guard targets.insert(move.to).inserted else {
                throw FileAccessError(path: move.to, message: "\(target) is named twice")
            }
            if TrashCan.lexists(move.to), !sources.contains(move.to),
               !Rename.sameFile(move.from, move.to) {
                throw FileAccessError(path: move.to, message: "\(target) is already here")
            }
        }
    }

    /// Does whichever move has a free target, until none has: what is left
    /// then is cycles — every target is the source of another pending move —
    /// and one of them steps aside to a temporary name, which frees its old
    /// place for the move that was waiting on it.
    static func perform(_ moves: [FileMove], recording done: inout [FileMove]) throws {
        var pending = moves
        while !pending.isEmpty {
            let occupied = Set(pending.map(\.from))
            if let index = pending.firstIndex(where: { !occupied.contains($0.to) }) {
                let move = pending.remove(at: index)
                try step(move.from, move.to)
                done.append(move)
            } else {
                let move = pending[0]
                let temporary = try freeTemporaryName(beside: move.from)
                try step(move.from, temporary)
                done.append(FileMove(from: move.from, to: temporary))
                pending[0].from = temporary
            }
        }
    }

    /// Undoes `done`, newest first. Returns the paths left where they should
    /// not be.
    static func rollBack(_ done: [FileMove]) -> [String] {
        var stuck: [String] = []
        for move in done.reversed() {
            do { try step(move.to, move.from) } catch { stuck.append(move.to) }
        }
        return stuck
    }

    private static let temporaryPrefix = ".lava-rename-"

    static func freeTemporaryName(beside path: String) throws -> String {
        let directory = (path as NSString).deletingLastPathComponent
        for _ in 0..<16 {
            let name = temporaryPrefix + "\(getpid())-" + String(UInt64.random(in: 0...UInt64.max), radix: 36)
            let candidate = CopyPaths.join(directory, name)
            if !TrashCan.lexists(candidate) { return candidate }
        }
        throw FileAccessError(path: directory, message: "No free temporary name")
    }

    /// One rename that never replaces. A case-only change on a filesystem
    /// that folds case finds its own file at the target, which is the one
    /// exclusion that is not a clash.
    static func step(_ from: String, _ to: String) throws {
        if renameNoReplace(from, to) == 0 { return }
        let failure = errno
        if failure == EEXIST, Rename.sameFile(from, to), Glibc.rename(from, to) == 0 { return }
        let message = failure == EEXIST
            ? "\u{201C}\((to as NSString).lastPathComponent)\u{201D} is already here"
            : String(cString: strerror(failure))
        throw FileAccessError(path: from, message: message)
    }

    // `renameat2` is not in Swift's Glibc module (it is behind _GNU_SOURCE),
    // so it is found at run time. Where it is missing, or the filesystem
    // refuses the flag (EINVAL: some FUSE and network ones), a check before a
    // plain rename is the best there is — the window it leaves is the one
    // `Rename.rename` has always had.
    typealias RenameAt2 = @convention(c) (
        Int32, UnsafePointer<CChar>, Int32, UnsafePointer<CChar>, UInt32
    ) -> Int32

    static let renameat2: RenameAt2? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "renameat2") else { return nil }
        return unsafeBitCast(symbol, to: RenameAt2.self)
    }()

    private static let renameNoReplaceFlag: UInt32 = 1  // RENAME_NOREPLACE

    static func renameNoReplace(_ from: String, _ to: String) -> Int32 {
        if let renameat2 {
            let result = renameat2(AT_FDCWD, from, AT_FDCWD, to, renameNoReplaceFlag)
            if result == 0 || (errno != EINVAL && errno != ENOSYS) { return result }
        }
        if TrashCan.lexists(to) {
            errno = EEXIST
            return -1
        }
        return Glibc.rename(from, to)
    }
}
