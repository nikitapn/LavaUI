import Foundation
import LavaUI
import Observation
import TraceLoomCore

/// Shared document + chrome state for TraceLoom.
///
/// Menu actions live outside the view tree (`LavaHost.run(menu:)`), while the
/// UI is a `View` with `@State`. Connecting them with closures that capture
/// `@State` does not work — those wrappers are value copies. An `@Observable`
/// class is the join: the menu mutates the same instance the view reads, and
/// Observation marks the view body dirty the same way as local `@State`.
///
/// Pattern:
/// ```swift
/// let session = TraceLoomSession()
/// LavaHost.run(editor: editor, menu: { … session.openLogFile() … }) {
///     TraceLoom(session: session)
/// }
/// ```
@Observable
final class TraceLoomSession {
    var rules: String
    var log: String

    /// Non-nil while a file load is in flight (status line under the header).
    var loadingPath: String?
    /// Outcome of the last load until the next one starts.
    var notice: TraceLoomNotice?

    var showSettings = false

    /// Timeline domain. Nil means fit all parsed data.
    var zoomStart: Double?
    var zoomEnd: Double?

    /// `lanes` gives each series its own strip; `overlay` stacks them in one
    /// plot so a long rule list does not squash every chart to a few pixels.
    var timelineLayout: TimelineLayout = .lanes

    /// Share of the window below the header that the timeline gets; the log
    /// editor takes the rest. Lives here rather than in the view so the split
    /// survives whatever else rebuilds the body — and so a future "restore my
    /// layout" has one number to write down.
    var timelineSplit: Float = 0.62

    init(
        rules: String = TraceLoom.sampleRules,
        log: String = TraceLoom.sampleLog
    ) {
        self.rules = rules
        self.log = log
    }

    // MARK: - File actions (menu + in-window chrome)

    func openLogFile() {
        guard let url = FileDialog.openFile(
            title: "Open Log File",
            filters: [FileDialog.Filter(name: "Log/text files", extensions: ["log", "txt"])]
        ) else { return }
        loadLog(from: [url])
    }

    /// Shared by the file dialog, menu, and `.onDrop`.
    func loadLog(from urls: [URL]) {
        guard let url = urls.first else { return }
        notice = nil
        loadingPath = url.path
        // Paint "Loading…" before the read/parse (can be multi-second).
        FrameTasks.after { [weak self] in self?.completeLoad(url) }
    }

    func reloadSample() {
        rules = TraceLoom.sampleRules
        log = TraceLoom.sampleLog
        notice = nil
        loadingPath = nil
        resetZoom()
    }

    func openSettings() {
        showSettings = true
    }

    func resetZoom() {
        zoomStart = nil
        zoomEnd = nil
    }

    private func completeLoad(_ url: URL) {
        defer { loadingPath = nil }
        do {
            let loaded = try LogFile.read(at: url)
            log = loaded.text
            resetZoom()
            if let warning = loaded.warning {
                notice = TraceLoomNotice(text: warning, isError: false)
                report(warning)
            }
        } catch {
            notice = TraceLoomNotice(text: "\(error)", isError: true)
            report("\(error)")
        }
    }

    private func report(_ message: String) {
        FileHandle.standardError.write(Data("TraceLoom: \(message)\n".utf8))
    }
}

enum TimelineLayout: String, CaseIterable, Sendable {
    case lanes
    case overlay
}

struct TraceLoomNotice {
    var text: String
    var isError: Bool
}
