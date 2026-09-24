import Foundation

/// One item that went from one place to another.
public struct FileMove: Equatable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Something this window did to the disk that it can take back.
///
/// Every undo here is a trip through the Trash, one way or the other, or a
/// rename or move back, and that is the rule that decides what is on the list. Moving to the Trash is undone
/// by restoring; restoring is undone by moving back; a copy is undone by
/// moving the copies to the Trash — never by deleting them, so an undo that
/// was a mistake is itself recoverable, and redo is the same operation seen
/// from the other side. What cannot go through the Trash is not undoable:
/// anything deleted for good, and a file a copy replaced, whose old contents
/// are gone.
public enum FileChange: Equatable, Sendable {
    /// Moved to the Trash; these are where they went.
    case trashed([TrashItem])
    /// Put back from the Trash, at these paths.
    case restored([String])
    /// New files and folders a copy made.
    case copied([String])
    /// Folders made with New Folder.
    case created([String])
    /// Given another name in the same folder.
    case renamed(from: String, to: String)
    /// Moved by a drop, within one filesystem.
    case moved([FileMove])
    /// One drop that moved some things and copied others: one step to undo.
    case combined([FileChange])

    public var count: Int {
        switch self {
        case .trashed(let items): items.count
        case .restored(let paths), .copied(let paths), .created(let paths): paths.count
        case .renamed: 1
        case .moved(let moves): moves.count
        case .combined(let changes): changes.reduce(0) { $0 + $1.count }
        }
    }
}

/// What reversing a change did.
public struct FileChangeReversal: Equatable, Sendable {
    /// The change that undoes this one — what goes on the other stack. Nil
    /// when nothing at all could be reversed.
    public var inverse: FileChange?
    public var failures: [FileAccessError]
    /// Folders whose contents changed, for the tabs showing them.
    public var folders: [String]
}

extension FileChange {
    /// What went from one path to another in this change, for tabs to follow:
    /// a renamed or moved folder with a tab open inside it.
    public var relocations: [FileMove] {
        switch self {
        case .renamed(let from, let to): [FileMove(from: from, to: to)]
        case .moved(let moves): moves
        case .combined(let changes): changes.flatMap(\.relocations)
        default: []
        }
    }

    public func reversed(using trash: TrashCan) -> FileChangeReversal {
        var failures: [FileAccessError] = []
        switch self {
        case .trashed(let items):
            var restored: [String] = []
            for item in items {
                do {
                    restored.append(try trash.restore(item))
                } catch let error as FileAccessError {
                    failures.append(error)
                } catch {
                    failures.append(FileAccessError(path: item.originalPath, message: error.localizedDescription))
                }
            }
            return FileChangeReversal(
                inverse: restored.isEmpty ? nil : .restored(restored),
                failures: failures,
                folders: restored.map { ($0 as NSString).deletingLastPathComponent }
            )
        case .moved(let moves):
            var back: [FileMove] = []
            for move in moves {
                // Never over something that has since taken the old place.
                if TrashCan.lexists(move.from) {
                    failures.append(FileAccessError(
                        path: move.from,
                        message: "Something new is at \u{201C}\((move.from as NSString).lastPathComponent)\u{201D}"
                    ))
                    continue
                }
                do {
                    try FileManager.default.createDirectory(
                        atPath: (move.from as NSString).deletingLastPathComponent,
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.moveItem(atPath: move.to, toPath: move.from)
                    back.append(FileMove(from: move.to, to: move.from))
                } catch {
                    failures.append(FileAccessError(path: move.to, message: error.localizedDescription))
                }
            }
            return FileChangeReversal(
                inverse: back.isEmpty ? nil : .moved(back),
                failures: failures,
                folders: back.flatMap {
                    [($0.from as NSString).deletingLastPathComponent,
                     ($0.to as NSString).deletingLastPathComponent]
                }
            )
        case .combined(let changes):
            // Last done, first undone.
            var inverses: [FileChange] = []
            var folders: [String] = []
            for change in changes.reversed() {
                let reversal = change.reversed(using: trash)
                if let inverse = reversal.inverse { inverses.append(inverse) }
                failures += reversal.failures
                folders += reversal.folders
            }
            return FileChangeReversal(
                inverse: inverses.isEmpty ? nil : .combined(inverses),
                failures: failures, folders: folders
            )
        case .renamed(let from, let to):
            let back = (from as NSString).lastPathComponent
            do {
                let restored = try Rename.rename(to, to: back)
                return FileChangeReversal(
                    inverse: .renamed(from: to, to: restored), failures: [],
                    folders: [(restored as NSString).deletingLastPathComponent]
                )
            } catch {
                let failure = (error as? FileAccessError)
                    ?? FileAccessError(path: to, message: error.localizedDescription)
                return FileChangeReversal(inverse: nil, failures: [failure], folders: [])
            }
        case .restored(let paths), .copied(let paths), .created(let paths):
            var trashed: [TrashItem] = []
            for path in paths {
                do {
                    trashed.append(try trash.trash(path))
                } catch let error as FileAccessError {
                    failures.append(error)
                } catch {
                    failures.append(FileAccessError(path: path, message: error.localizedDescription))
                }
            }
            return FileChangeReversal(
                inverse: trashed.isEmpty ? nil : .trashed(trashed),
                failures: failures,
                folders: trashed.map(\.originalFolder)
            )
        }
    }
}

/// Undo and redo, for one window.
///
/// Anything new that is done clears redo — the same rule as a text editor:
/// once the timeline forks, the other branch is gone. Bounded, because each
/// entry names files and nobody undoes their way back through a hundred
/// operations.
public struct FileUndoHistory: Equatable, Sendable {
    public private(set) var undoStack: [FileChange] = []
    public private(set) var redoStack: [FileChange] = []
    public static let limit = 50

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func record(_ change: FileChange) {
        guard change.count > 0 else { return }
        undoStack.append(change)
        if undoStack.count > Self.limit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Reverses the newest change. Its inverse becomes something to redo.
    public mutating func undo(using trash: TrashCan) -> (FileChange, FileChangeReversal)? {
        guard let change = undoStack.popLast() else { return nil }
        let reversal = change.reversed(using: trash)
        if let inverse = reversal.inverse { redoStack.append(inverse) }
        return (change, reversal)
    }

    /// Reverses the newest undo — which is the same thing as doing it again.
    public mutating func redo(using trash: TrashCan) -> (FileChange, FileChangeReversal)? {
        guard let change = redoStack.popLast() else { return nil }
        let reversal = change.reversed(using: trash)
        if let inverse = reversal.inverse {
            undoStack.append(inverse)
            if undoStack.count > Self.limit { undoStack.removeFirst() }
        }
        return (change, reversal)
    }
}
