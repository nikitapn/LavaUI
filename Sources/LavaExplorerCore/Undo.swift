import Foundation

/// Something this window did to the disk that it can take back.
///
/// Every undo here is a trip through the Trash, one way or the other, or a
/// rename back, and that is the rule that decides what is on the list. Moving to the Trash is undone
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

    public var count: Int {
        switch self {
        case .trashed(let items): items.count
        case .restored(let paths), .copied(let paths), .created(let paths): paths.count
        case .renamed: 1
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
