import Foundation
import LavaDiffCore
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
            highlighter: document.language.highlighter, documentID: document.id, isEditable: true
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
            highlighter: document.language.highlighter, documentID: document.id, isEditable: true
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
            open([url], mode: .preview)
            documentID = active.id
        }
        show(DiffModel(
            old: old, new: new, oldTitle: oldTitle, newTitle: newTitle,
            highlighter: language.highlighter, documentID: documentID,
            // Staged is the index, not the buffer; a deleted file has none.
            isEditable: item.group != .staged && documentID != nil, url: url
        ))
    }

    func closeDiff() {
        diff = nil
    }

    /// Brings the next or previous change to the middle of the new side;
    /// the old side follows through the shared scroll.
    func stepDiff(forward: Bool) {
        guard let diff = visibleDiff, let hunk = diff.step(forward: forward) else { return }
        // The caret at the change's first character, nothing selected. A
        // deletion has no line of its own on the new side, so it is the line
        // that now follows it — or the end, after the last.
        let lines = diff.diff.new
        let starts = DiffAlignment.lineStarts(lines)
        let offset = hunk.new.lowerBound < starts.count
            ? starts[hunk.new.lowerBound]
            : (starts.last ?? 0) + (lines.lines.last?.count ?? 0)
        let controller = diff.newController
        // Not mounted yet when the comparison has only just opened.
        if !controller.reveal(range: offset..<offset) {
            FrameTasks.after { controller.reveal(range: offset..<offset) }
        }
    }

    /// After an edit to the document a comparison is showing: re-diff.
    ///
    /// In the same frame as the edit whenever the last diff was quick, which
    /// is nearly always. The blank rows are stated in lines, so between an
    /// edit and its re-diff every gap below the edit sits a line out of place
    /// on the edited side, and the text around it jumped by a line and back.
    /// A file big enough that a diff costs a noticeable part of a frame waits
    /// for typing to pause instead, and takes the jump.
    func scheduleDiffRefresh() {
        guard let diff, diff.isEditable, diff.documentID == active.id,
              diff.newText != active.text else { return }
        diffGeneration &+= 1
        if diff.lastUpdateSeconds < 0.004 {
            diff.update(new: active.text)
            return
        }
        let generation = diffGeneration
        let owner = LanguageSessionRef(self)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12) {
            MainQueue.async {
                guard let session = owner.session, session.diffGeneration == generation,
                      let diff = session.diff, diff.documentID == session.active.id else { return }
                diff.update(new: session.active.text)
            }
        }
    }

    private func show(_ model: DiffModel) {
        notice = nil
        diff = model
        // Straight to the first change: that is what a comparison is opened
        // to look at, and a file with one edit in its last screen would
        // otherwise open on a page of context.
        if !model.diff.isEmpty { stepDiff(forward: true) }
    }
}
