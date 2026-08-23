import Foundation
import LavaUI

/// One open file.
///
/// A struct in an array, so mutating one is an observable change to
/// `EditorSession.documents` and the window rebuilds. `text` is a `String`,
/// which is a reference underneath — moving a document around costs a retain
/// rather than a copy of the file.
struct EditorDocument: Identifiable {
    let id: Int
    /// Where it came from, and where `Save` writes. Nil for a file that has
    /// never been saved, which is what makes `Save` fall back to `Save As`.
    var url: URL?
    var text: String

    /// Whether the buffer differs from what is on disk.
    ///
    /// A flag rather than a comparison against a kept copy of the saved text.
    /// The comparison is the obvious implementation and it is wrong twice
    /// over: it doubles the memory a large file costs, and it runs on every
    /// keystroke over the whole buffer to answer a question the keystroke
    /// already knew the answer to.
    var isModified = false

    /// Where the editor was left. Restored when this document comes back to
    /// the front — see `EditorController.restore`.
    var position: EditorPosition?

    /// False when `url` is set but the bytes have not been read yet. Opening
    /// eight files must not read eight files: only the one in front is read,
    /// and the rest when they are first selected.
    var isLoaded = true
    /// Why the last read failed. Kept so the tab can say so instead of showing
    /// an empty buffer, which looks exactly like an empty file.
    var loadError: String?

    /// What the tab and the title bar call it.
    var name: String { url?.lastPathComponent ?? "Untitled \(id)" }

    /// Directory, for telling two files of the same name apart.
    var detail: String? {
        url?.deletingLastPathComponent().path
    }

    var language: Language { Language.of(url) }

    /// Reads the file into `text`. Returns false and fills `loadError` on
    /// failure, leaving the buffer alone.
    ///
    /// Anything that is not valid UTF-8 is refused rather than repaired.
    /// Guessing an encoding and guessing wrong writes a file back with its
    /// non-ASCII bytes silently replaced, and the user finds out much later —
    /// so a file this cannot read is a file it will not offer to save.
    mutating func load() -> Bool {
        guard let url else { return true }
        do {
            let data = try Data(contentsOf: url)
            guard let decoded = String(data: data, encoding: .utf8) else {
                loadError = "Not valid UTF-8 — this editor cannot open it safely"
                isLoaded = false
                return false
            }
            text = decoded
            isLoaded = true
            isModified = false
            loadError = nil
            return true
        } catch {
            loadError = error.localizedDescription
            isLoaded = false
            return false
        }
    }

    /// Writes `text` to `target`, adopting it as this document's file.
    ///
    /// `.atomic` so a failed write leaves the previous contents rather than a
    /// truncated file: the failure mode of a plain write is losing the version
    /// that was already safe on disk.
    mutating func save(to target: URL) -> String? {
        do {
            try Data(text.utf8).write(to: target, options: .atomic)
            url = target
            isModified = false
            loadError = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
