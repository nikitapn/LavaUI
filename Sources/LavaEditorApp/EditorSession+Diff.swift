import Foundation
import LavaGitCore
import LavaProjectCore
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
        // The comparison just asked git anyway: let the gutter catch up with
        // a commit made since the file was opened.
        refreshBaseline(activeIndex)
        let newTitle = document.isModified ? "Editor · \(path) (unsaved)" : "Working tree · \(path)"
        show(DiffModel(
            old: headText, new: document.text, oldTitle: oldTitle, newTitle: newTitle,
            highlighter: document.language.highlighter, documentID: document.id
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
            highlighter: document.language.highlighter, documentID: document.id
        ))
    }

    /// The name first, then where it is: a title is cut at its right edge,
    /// and two long paths that share a prefix would otherwise both show only
    /// the part they have in common.
    private static func title(_ url: URL) -> String {
        "\(url.lastPathComponent) · \(url.deletingLastPathComponent().path)"
    }

    /// The diff a Source Control row opens, as VS Code shows it: for a
    /// change, what is staged (the index) against the working file; for a
    /// staged change, the last commit against what is staged. The working
    /// side is the open buffer when the file has a tab — what the user is
    /// looking at — and the file on disk otherwise.
    func compareChange(_ item: SourceControlList.Item) {
        guard let project, let repository = project.repository else { return }
        let url = repository.root.appendingPathComponent(item.path)
        func read(_ revision: GitRepository.Revision, _ path: String) throws -> String? {
            let file = repository.root.appendingPathComponent(path)
            switch try repository.contents(of: file, at: revision) {
            case .text(let text): return text
            case .absent: return ""
            case .binary: return nil
            }
        }
        let old: String?, new: String?
        let oldTitle: String, newTitle: String
        do {
            if item.group == .staged {
                old = try read(.head, item.originalPath ?? item.path)
                new = try read(.index, item.path)
                oldTitle = "HEAD · \(item.originalPath ?? item.path)"
                newTitle = "Staged · \(item.path)"
            } else {
                old = item.isUntracked ? "" : try read(.index, item.path)
                if item.change == .deleted {
                    new = ""
                } else if let open = documents.first(where: {
                    $0.url?.standardizedFileURL == url.standardizedFileURL && $0.isLoaded
                }) {
                    new = open.text
                } else {
                    new = (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
                }
                // The index, which equals HEAD for a file with nothing staged —
                // "Staged" would claim a staged change that is not there.
                oldTitle = item.isUntracked ? "Not tracked" : "Index · \(item.path)"
                newTitle = item.change == .deleted ? "Deleted" : "Working tree · \(item.path)"
            }
        } catch {
            notice = "git: \(error)"
            return
        }
        guard let old, let new else {
            notice = "\(item.name) is not text, so there is nothing to show line by line."
            return
        }
        let language = Language.of(url)
        // A file that still exists opens in its tab with the diff over it,
        // so Done lands in the file; a deleted one has no tab to open.
        var documentID: Int?
        if item.change != .deleted, FileManager.default.fileExists(atPath: url.path) {
            open([url])
            documentID = active.id
        }
        show(DiffModel(
            old: old, new: new, oldTitle: oldTitle, newTitle: newTitle,
            highlighter: language.highlighter, documentID: documentID
        ))
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
