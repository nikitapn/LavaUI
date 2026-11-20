import Foundation
import LavaGitCore
import LavaUI

/// Comparisons: the document in front against what git has, or one file
/// against another.
extension EditorSession {
    /// The comparison to draw in place of the editor, if it belongs to the
    /// document in front.
    var visibleDiff: DiffModel? {
        guard let diff, diff.documentID == nil || diff.documentID == active.id else { return nil }
        return diff
    }

    /// Compares the buffer in front — unsaved edits included — with the file
    /// as it was in the last commit.
    ///
    /// Blocking: two `git` processes, a few milliseconds each. Fine on a
    /// menu command; not something to run per keystroke.
    func compareWithHEAD() {
        if visibleDiff != nil {
            closeDiff()
            return
        }
        let document = active
        guard let url = document.url else {
            notice = "Save the file first: an untitled buffer has no history to compare with."
            return
        }
        guard let repository = GitRepository.containing(url) else {
            notice = "\(document.name) is not in a git repository."
            return
        }
        let headText: String
        let oldTitle: String
        let path = repository.relativePath(of: url) ?? document.name
        do {
            switch try repository.contents(of: url, at: .head) {
            case .text(let text):
                headText = text
                oldTitle = "HEAD · \(path)"
            case .absent:
                // A new file: everything in it is an addition, which is what
                // the comparison should say rather than refusing.
                headText = ""
                oldTitle = "HEAD · not tracked"
            case .binary:
                notice = "\(document.name) is not text at HEAD, so there is nothing to show line by line."
                return
            }
        } catch {
            notice = "git: \(error)"
            return
        }
        let newTitle = document.isModified ? "Editor · \(path) (unsaved)" : "Working tree · \(path)"
        show(DiffModel(
            old: headText, new: document.text, oldTitle: oldTitle, newTitle: newTitle,
            rules: document.language.rules, documentID: document.id
        ))
    }

    /// Opens `new` (if it is not already) and compares `old` with it.
    func compare(_ old: URL, with new: URL) {
        let oldText: String
        do {
            oldText = try String(contentsOf: old, encoding: .utf8)
        } catch {
            notice = "Could not read \(old.path): \(error.localizedDescription)"
            return
        }
        open([new])
        let document = active
        guard document.url?.standardizedFileURL == new.standardizedFileURL, document.isLoaded else {
            return
        }
        show(DiffModel(
            old: oldText, new: document.text, oldTitle: Self.title(old), newTitle: Self.title(new),
            rules: document.language.rules, documentID: document.id
        ))
    }

    /// The name first, then where it is: a title is cut at its right edge,
    /// and two long paths that share a prefix would otherwise both show only
    /// the part they have in common.
    private static func title(_ url: URL) -> String {
        "\(url.lastPathComponent) · \(url.deletingLastPathComponent().path)"
    }

    func closeDiff() {
        diff = nil
    }

    /// Scrolls to the next or previous change, leaving a few lines above it so
    /// it reads in context rather than pinned to the top edge.
    func stepDiff(forward: Bool) {
        guard let diff = visibleDiff, let row = diff.step(forward: forward) else { return }
        let lineH = (documentFont ?? FontStore.default)?.lineHeight ?? 20
        diffScroll.scroll(to: Float(max(0, row - 3)) * lineH)
    }

    private func show(_ model: DiffModel) {
        notice = nil
        diff = model
        diffScroll.scrollToTop()
        // Straight to the first change: that is what a comparison is opened
        // to look at, and a file with one edit in its last screen would
        // otherwise open on a page of context.
        if !model.diff.isEmpty { stepDiff(forward: true) }
    }
}
