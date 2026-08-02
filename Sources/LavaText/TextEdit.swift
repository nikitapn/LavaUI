import Foundation

/// One reversible edit: replace a range of the buffer with new text.
///
/// Offsets are **UTF-8 byte** offsets, not `String.Index` and not characters.
/// Indices are invalidated by the very mutation being recorded, so they cannot
/// survive in a history — but the choice between bytes and characters is a
/// performance one, and it is the difference between a usable editor and an
/// unusable one on a large file.
///
/// A character offset costs `String.distance(from: startIndex, to:)` to
/// produce and the same to consume: a full grapheme-break walk of everything
/// before the edit. Recording one keystroke needs three of them (the edit
/// position, the anchor, the focus) and restoring the caret needs a fourth, so
/// typing at the end of a 10 MB buffer cost ~64 ms *per keypress*. A UTF-8
/// offset is O(1) in both directions — `String.Index` stores the encoded byte
/// offset, so producing one is a subtraction.
///
/// Bytes are no less grapheme-correct here, because every offset stored is
/// produced from a real `String.Index`, which is always on a character
/// boundary. Converting back snaps down (see `index(atUTF8Offset:)`) so a
/// buffer edited into a different shape can never leave a caret inside a
/// `"\r\n"` or a ZWJ sequence.
public struct TextEdit: Equatable {
    /// UTF-8 offset where the replacement begins.
    public var offset: Int
    /// What used to be there — this is what makes the edit reversible.
    public var removed: String
    /// What replaced it.
    public var inserted: String
    /// Selection at the moment before the edit, so undo restores not just the
    /// text but where the user was. Restoring text alone feels broken.
    public var anchorBefore: Int
    public var focusBefore: Int

    public init(
        offset: Int, removed: String, inserted: String,
        anchorBefore: Int, focusBefore: Int
    ) {
        self.offset = offset
        self.removed = removed
        self.inserted = inserted
        self.anchorBefore = anchorBefore
        self.focusBefore = focusBefore
    }

    /// The same edit run backwards.
    public var inverted: TextEdit {
        TextEdit(
            offset: offset, removed: inserted, inserted: removed,
            anchorBefore: anchorBefore, focusBefore: focusBefore
        )
    }

    var isPureInsertion: Bool { removed.isEmpty && !inserted.isEmpty }
    var isPureDeletion: Bool { inserted.isEmpty && !removed.isEmpty }
}

/// Undo/redo history for a single buffer.
///
/// Coalescing is deliberately **time-free**. A timer makes the split points
/// depend on how fast someone types, which is both untestable and surprising
/// ("why did that undo only half a word?"). Instead a run breaks on a word
/// boundary, a direction change, or anything that is not a simple continuation
/// — deterministic, and it matches where a user thinks a word ended.
public struct UndoStack: Equatable {
    private var undoable: [TextEdit] = []
    private var redoable: [TextEdit] = []

    public init() {}

    public var canUndo: Bool { !undoable.isEmpty }
    public var canRedo: Bool { !redoable.isEmpty }

    public mutating func record(_ edit: TextEdit) {
        // Any fresh edit invalidates the redo branch — the future it described
        // no longer exists.
        redoable.removeAll()

        if let last = undoable.last, let merged = Self.coalesce(last, edit) {
            undoable[undoable.count - 1] = merged
            return
        }
        undoable.append(edit)
    }

    public mutating func popUndo() -> TextEdit? {
        guard let edit = undoable.popLast() else { return nil }
        redoable.append(edit)
        return edit
    }

    public mutating func popRedo() -> TextEdit? {
        guard let edit = redoable.popLast() else { return nil }
        undoable.append(edit)
        return edit
    }

    public mutating func clear() {
        undoable.removeAll()
        redoable.removeAll()
    }

    /// Merges `next` into `previous` when they read as one user action.
    static func coalesce(_ previous: TextEdit, _ next: TextEdit) -> TextEdit? {
        if previous.isPureInsertion, next.isPureInsertion {
            // Must continue exactly where the last one ended.
            guard next.offset == previous.offset + previous.inserted.utf8.count else {
                return nil
            }
            // Break *after* whitespace so "hello " and "world" are separate
            // undo steps, which is where a user expects the boundary.
            guard let tail = previous.inserted.last, !tail.isWhitespace else {
                return nil
            }
            return TextEdit(
                offset: previous.offset,
                removed: "",
                inserted: previous.inserted + next.inserted,
                anchorBefore: previous.anchorBefore,
                focusBefore: previous.focusBefore
            )
        }

        if previous.isPureDeletion, next.isPureDeletion {
            // Backspace runs leftward: each deletion ends where the next begins.
            guard next.offset + next.removed.utf8.count == previous.offset else {
                return nil
            }
            guard let head = previous.removed.first, !head.isWhitespace else {
                return nil
            }
            return TextEdit(
                offset: next.offset,
                removed: next.removed + previous.removed,
                inserted: "",
                anchorBefore: previous.anchorBefore,
                focusBefore: previous.focusBefore
            )
        }

        return nil
    }
}
