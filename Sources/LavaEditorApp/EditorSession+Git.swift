import Foundation
import LavaDiffCore
import LavaGitCore
import LavaUI

/// The last commit's copy of a document, split into lines once, which every
/// keystroke after that is diffed against.
struct GitBaseline {
    /// HEAD's lines, hashed once on the worker that fetched them: the gutter
    /// diffs every keystroke against them, and hashing the whole commit's
    /// copy each time was most of that diff.
    let lines: DiffBaseline
    /// Bumped on every fetch, so the marks memo knows a commit made in a
    /// terminal since is a different baseline even if the text is not.
    let generation: Int
}

/// Bars and fills down the editor for what changed since the last commit —
/// the gutter every editor with git in it has.
///
/// The commit's copy is fetched once per document, on a worker, and kept;
/// every edit after that is an in-memory diff against it. Asking git per
/// keystroke would be two process spawns per character typed.
extension EditorSession {
    /// Fetches HEAD's copy of the document at `index` and keeps it. Quietly
    /// keeps nothing for a file outside a repository, untracked or not text:
    /// none of those has a gutter to show.
    func refreshBaseline(_ index: Int) {
        guard documents.indices.contains(index), let url = documents[index].url else { return }
        let id = documents[index].id
        let owner = SessionRef(session: self)
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: DiffBaseline?
            if let repository = GitRepository.containing(url),
               case .text(let text)? = try? repository.contents(of: url, at: .head)
            {
                lines = DiffBaseline(TextLines(text).lines)
            }
            let fetched = lines
            MainQueue.async {
                let session = owner.session
                if let fetched {
                    session.baselineGeneration &+= 1
                    session.gitBaselines[id] = GitBaseline(
                        lines: fetched, generation: session.baselineGeneration
                    )
                } else if session.gitBaselines[id] != nil {
                    session.gitBaselines[id] = nil
                }
            }
        }
    }

    /// Marks for the document in front: what it has gained, changed and lost
    /// since the last commit. Empty without a baseline.
    ///
    /// Memoised on the document, its revision and length, the baseline and
    /// the look — the body is rebuilt for reasons that have nothing to do
    /// with the text, and a diff of a large file is not free. Not observed,
    /// for the same reason as `activeLineCount`'s memo: a write from inside
    /// the body that reads it would invalidate that body.
    func changeMarks(_ appearance: EditorAppearance) -> [EditorLineMark] {
        let document = active
        guard let base = gitBaselines[document.id], document.isLoaded else { return [] }
        let bytes = document.text.utf8.count
        // A few megabytes of buffer is a diff per keystroke the typing would
        // feel; nobody reads a gutter on a file that size anyway.
        guard bytes <= 4 << 20 else { return [] }
        let key = MarksKey(
            document: document.id, revision: revision, bytes: bytes,
            baseline: base.generation, fills: highlightsChangedLines,
            paper: appearance.usesPaper
        )
        if let cached = marksCache, cached.key == key { return cached.marks }

        let hunks = LineDiff.hunks(from: base.lines, to: TextLines(document.text).lines)
        let colors = ChangeColors(appearance)
        let fills = highlightsChangedLines
        let marks = hunks.map { hunk -> EditorLineMark in
            if hunk.isDeletion {
                return EditorLineMark(lines: hunk.new, bar: colors.removed)
            }
            let added = hunk.isInsertion
            return EditorLineMark(
                lines: hunk.new,
                bar: added ? colors.added : colors.modified,
                fill: fills ? (added ? colors.addedFill : colors.modifiedFill) : nil
            )
        }
        marksCache = (key, marks)
        return marks
    }
}

struct MarksKey: Equatable {
    var document: Int
    var revision: Int
    var bytes: Int
    var baseline: Int
    var fills: Bool
    var paper: Bool
}

/// The session, carried to a worker and back. Only ever dereferenced inside
/// `MainQueue.async`, which runs on the frame loop's thread.
struct SessionRef: @unchecked Sendable {
    let session: EditorSession
}

/// Gutter colours: green for lines added, blue for lines changed, red for a
/// notch where lines were removed — the convention every editor shares, so
/// nobody has to learn it.
struct ChangeColors {
    let added: Color
    let modified: Color
    let removed: Color
    let addedFill: Color
    let modifiedFill: Color

    init(_ appearance: EditorAppearance) {
        if appearance.usesPaper {
            added = Color(rgb24: 0x5c_a0_3a)
            modified = Color(rgb24: 0x4a_7f_b5)
            removed = Color(rgb24: 0xc4_3d_2f)
            addedFill = Color(rgb24: 0xee_f6_e4)
            modifiedFill = Color(rgb24: 0xea_f0_f6)
        } else {
            added = Color(rgb24: 0x5f_b0_4a)
            modified = Color(rgb24: 0x4f_8f_d6)
            removed = Color(rgb24: 0xd9_53_4f)
            addedFill = Color(rgb24: 0x1b_2b_20)
            modifiedFill = Color(rgb24: 0x1b_25_33)
        }
    }
}
