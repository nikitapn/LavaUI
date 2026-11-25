import Foundation
import LavaDiffCore
import LavaText
import LavaUI
import Observation

/// One open comparison: the old text, the new one, what differs, and what
/// two editors side by side need to show it.
///
/// The new side is often the document itself, edited in place: then every
/// edit re-diffs (debounced by the session) and the blank rows, fills and
/// changed words follow. The old side never changes.
@Observable
final class DiffModel {
    /// What the old side is: "HEAD", a path.
    let oldTitle: String
    /// What the new side is: "Working tree", a path.
    let newTitle: String
    /// The document the comparison is shown over — what `Done` goes back to.
    let documentID: Int?
    /// Whether the new side *is* that document's text, and so editable. Not
    /// when it is the index, or a file that has no tab.
    let isEditable: Bool
    /// The file compared, for a comparison with no document to ask — a
    /// deleted file. Only its language is read from it.
    let url: URL?

    let oldText: String
    /// The new side as last diffed. For an editable diff the editor shows the
    /// document's own text, which may be a pause ahead of this.
    private(set) var newText: String
    private(set) var diff: TextDiff
    private(set) var alignment: DiffAlignment

    /// Set when the new side is an inline chat's proposal rather than a
    /// file: the toolbar offers Accept and Reject instead of Done.
    @ObservationIgnored let proposalAccept: (() -> Void)?
    @ObservationIgnored let highlighter: SyntaxHighlighter
    /// Both editors scroll as one.
    @ObservationIgnored let scrollLink = EditorScrollLink()
    /// The new side's editor, for Next / Previous.
    @ObservationIgnored let newController = EditorController()
    /// The hunk last navigated to.
    @ObservationIgnored var currentHunk: Int?

    init(
        old: String, new: String, oldTitle: String, newTitle: String,
        highlighter: SyntaxHighlighter, documentID: Int?, isEditable: Bool, url: URL? = nil,
        proposalAccept: (() -> Void)? = nil
    ) {
        self.url = url
        self.proposalAccept = proposalAccept
        self.oldTitle = oldTitle
        self.newTitle = newTitle
        self.documentID = documentID
        self.isEditable = isEditable && documentID != nil
        self.highlighter = highlighter
        oldText = old
        newText = new
        let diff = TextDiff(old: old, new: new)
        self.diff = diff
        alignment = DiffAlignment(diff)
    }

    /// How long the last re-diff took. Under a frame's share, the session
    /// re-diffs in the keystroke's own frame; over it, after typing pauses.
    @ObservationIgnored private(set) var lastUpdateSeconds: Double = 0

    /// Re-diffs against an edited new side.
    func update(new text: String) {
        guard text != newText else { return }
        let start = DispatchTime.now().uptimeNanoseconds
        newText = text
        diff = TextDiff(old: oldText, new: text)
        alignment = DiffAlignment(diff)
        if let current = currentHunk, current >= diff.hunks.count { currentHunk = nil }
        lastUpdateSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    // MARK: - Navigation

    /// The next (or previous) hunk after the current one, wrapping round,
    /// made current. Nil when nothing differs.
    func step(forward: Bool) -> DiffHunk? {
        let count = diff.hunks.count
        guard count > 0 else { return nil }
        let next: Int
        if let current = currentHunk {
            next = ((forward ? current + 1 : current - 1) % count + count) % count
        } else {
            next = forward ? 0 : count - 1
        }
        currentHunk = next
        return diff.hunks[next]
    }
}
