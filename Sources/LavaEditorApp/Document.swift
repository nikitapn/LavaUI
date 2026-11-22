import Foundation
import LavaProjectCore
import LavaUI

/// One open file.
///
/// A struct in an array, so mutating one is an observable change to
/// `EditorSession.documents` and the window rebuilds. `text` is a `String`,
/// which is a reference underneath — moving a document around costs a retain
/// rather than a copy of the file.
struct EditorDocument: EditorTab {
    let id: Int
    /// Where it came from, and where `Save` writes. Nil for a file that has
    /// never been saved, which is what makes `Save` fall back to `Save As`.
    var url: URL?
    var text: String
    var preview: DocumentPreview?
    var tabState: EditorTabState = .open

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
    /// Invalid UTF-8 was replaced for display, so this buffer cannot round-trip.
    private(set) var hasInvalidUTF8 = false

    var saveUnavailable: String? {
        if preview != nil { return "Preview tabs are read-only." }
        guard isLoaded else { return loadError ?? "The file has not been loaded." }
        return hasInvalidUTF8 ? "This file is read-only because it contains invalid UTF-8." : nil
    }

    /// What the tab and the title bar call it.
    var name: String { preview?.tabTitle ?? url?.lastPathComponent ?? "Untitled \(id)" }

    /// Directory, for telling two files of the same name apart.
    var detail: String? {
        url?.deletingLastPathComponent().path
    }

    var language: Language { Language.of(url) }

    /// Reads the file into `text`. Returns false and fills `loadError` on
    /// failure, leaving the buffer alone.
    ///
    /// Invalid UTF-8 is displayed with replacement characters in read-only mode.
    mutating func load() -> Bool {
        guard let url else { return true }
        do {
            let data = try Data(contentsOf: url)
            let decoded = String(data: data, encoding: .utf8)
            hasInvalidUTF8 = decoded == nil
            text = decoded ?? String(decoding: data, as: UTF8.self)
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
        if let saveUnavailable { return saveUnavailable }
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
