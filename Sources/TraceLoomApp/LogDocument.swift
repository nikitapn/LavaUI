import Foundation
import LavaUI
import TraceLoomCore

/// One open log: the text, the rules it is read with, and where the user was
/// looking at it.
///
/// A struct in an array rather than a class, so mutating one document is an
/// observable change to `TraceLoomSession.documents` and the view rebuilds. The
/// log itself is a `String`, which is a reference under the hood — copying a
/// document around costs a retain, not the 12 MB it appears to.
///
/// The chart and editor state live *here* rather than on the session because
/// that is what makes switching tabs feel like returning to something rather
/// than reopening it: the zoom, the scroll offset and the selection belong to
/// the log they were made against, not to the window.
struct LogDocument: Identifiable {
    let id: Int
    /// Tab title. The file's name, or "Sample" for the built-in one.
    var name: String
    /// Where it came from. Nil for the built-in sample, which is the one
    /// document that cannot be written into a workspace.
    var url: URL?
    var rules: String
    var log: String

    /// False when `url` is set but the text has not been read yet.
    ///
    /// Opening a workspace of ten logs must not read ten files: the nine that
    /// are not in front cost nothing until they are selected. This is the flag
    /// that makes that lazy read happen exactly once.
    var isLoaded: Bool
    /// Why the last read failed, if it did. Kept so the tab can say so instead
    /// of showing an empty buffer that looks like an empty log, and so the
    /// failed read is not retried on every switch.
    var loadError: String?

    /// Timeline domain. Nil means fit all parsed data.
    var zoomStart: Double?
    var zoomEnd: Double?
    /// Scroll offset and selection of the log editor.
    var position: EditorPosition?

    init(
        id: Int,
        name: String,
        url: URL? = nil,
        rules: String,
        log: String = "",
        isLoaded: Bool = true,
        loadError: String? = nil,
        zoomStart: Double? = nil,
        zoomEnd: Double? = nil,
        position: EditorPosition? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.rules = rules
        self.log = log
        self.isLoaded = isLoaded
        self.loadError = loadError
        self.zoomStart = zoomStart
        self.zoomEnd = zoomEnd
        self.position = position
    }

    /// What the switcher shows beside the name: enough to tell two `app.log`s
    /// apart, and short enough that the list stays a list.
    var detail: String {
        guard let url else { return "built-in sample" }
        let directory = LogDocument.shorten(url.deletingLastPathComponent().path)
        if loadError != nil { return "unavailable · \(directory)" }
        return isLoaded ? directory : "not read yet · \(directory)"
    }

    /// A directory, shortened from the front — the tail is the part that
    /// distinguishes two runs of the same service, and the head is the part
    /// every log in the list has in common.
    private static func shorten(_ path: String, limit: Int = 44) -> String {
        var text = path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if text == home {
            text = "~"
        } else if text.hasPrefix(home + "/") {
            text = "~" + text.dropFirst(home.count)
        }
        guard text.count > limit else { return text }

        // Whole components only: half a directory name is not a shorter name,
        // it is a wrong one.
        var kept: [Substring] = []
        var length = 1
        for component in text.split(separator: "/").reversed() {
            length += component.count + 1
            if length > limit, !kept.isEmpty { break }
            kept.insert(component, at: 0)
        }
        return "…/" + kept.joined(separator: "/")
    }

    /// The workspace record for this document, or nil for one that has no file
    /// behind it — see `Workspace`.
    var workspaceEntry: WorkspaceDocument? {
        guard let url else { return nil }
        return WorkspaceDocument(
            name: name,
            path: url.path,
            rules: rules,
            zoomStart: zoomStart,
            zoomEnd: zoomEnd,
            position: position.map {
                WorkspaceDocument.Position(
                    scrollX: $0.scrollX, scrollY: $0.scrollY,
                    anchor: $0.anchor, focus: $0.focus
                )
            }
        )
    }

    /// The inverse: a document that knows where its log is but has not read it.
    static func restoring(_ entry: WorkspaceDocument, id: Int) -> LogDocument {
        LogDocument(
            id: id,
            name: entry.name,
            url: URL(fileURLWithPath: entry.path),
            rules: entry.rules,
            log: "",
            isLoaded: false,
            zoomStart: entry.zoomStart,
            zoomEnd: entry.zoomEnd,
            position: entry.position.map {
                EditorPosition(
                    scrollX: $0.scrollX, scrollY: $0.scrollY,
                    anchor: $0.anchor, focus: $0.focus
                )
            }
        )
    }
}
