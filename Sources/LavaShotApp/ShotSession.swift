import Foundation
import LavaShotCore
import LavaUI
import Observation

/// Everything LavaShot knows: the frozen picture, what has been drawn on it,
/// and what it is about to do with the result.
@Observable
final class ShotSession {
    /// The file the compositor wrote and the texture it became.
    ///
    /// A path because a picture cannot cross a shared-memory reply — and the
    /// path is better than the bytes would have been anyway: it goes straight
    /// back to `registerImage`, so the compositor decodes its own file and the
    /// pixels never travel at all. Ours to delete, which is what `discard`
    /// is for.
    @ObservationIgnored private(set) var shotPath: String?
    @ObservationIgnored private(set) var shot: UIImage?
    /// The captured size in framebuffer pixels, which is what the crop at the
    /// end is expressed in and is not the same as the window's size on a
    /// scaled output.
    @ObservationIgnored private(set) var shotWidth: Int = 0
    @ObservationIgnored private(set) var shotHeight: Int = 0

    /// The region being kept, in window coordinates. Nil until the first drag,
    /// when the whole screen is dimmed and nothing is selected yet.
    private(set) var selection: ShotRect?
    private(set) var tool: ShotTool = .select
    private(set) var colorIndex = 0
    private(set) var widthIndex = 1
    private(set) var document = ShotDocument()

    /// A message shown in place of the hint, after something happened that has
    /// no other visible result — a file written, a picture copied.
    private(set) var notice: String?

    /// The stroke being drawn right now, which is not in the document yet: it
    /// is not a mark until the button comes up.
    private(set) var drafting: ShotStroke?

    /// One frame with no interface on it, so the export captures the picture
    /// and the annotations and nothing else. See `beforePaint`.
    ///
    /// Deliberately not observed: it is changed from inside a paint closure,
    /// and observed state written there re-dirties the frame being painted.
    @ObservationIgnored private var exporting: Exporting?
    @ObservationIgnored private var exportArmed = false
    @ObservationIgnored private var askedFullscreen = false
    @ObservationIgnored private var askedCapture = false

    /// Whether this frame is the clean one. Read by the view to leave the dim,
    /// the outline and the toolbar unpainted.
    var isExporting: Bool { exporting != nil }

    enum Exporting: Equatable {
        case copy
        case save(URL)
    }

    var color: ShotColor { ShotColor.palette[colorIndex] }
    var strokeWidth: Float { ShotOutput.widths[widthIndex] }
    var hasShot: Bool { shot != nil }

    private let editor: Editor
    private var quit: () -> Void = {}

    init(editor: Editor) {
        self.editor = editor
    }

    func onQuit(_ handler: @escaping () -> Void) { quit = handler }

    // MARK: - The picture

    /// Covers the screen, then photographs it — on the first frame, not at
    /// startup.
    ///
    /// The bridges this needs are installed by `LavaHost.run`, which has not
    /// been called yet while `main` is still assembling things; asking earlier
    /// gets a nil provider and a window that never went fullscreen. So the
    /// first paint does it, in two steps a frame apart: fullscreen first, so
    /// the shot is taken with this window already the size of the output and
    /// the compositor's exclusion doing the work — a window that grew *after*
    /// the shot would leave a rectangle of stale desktop in the middle of it.
    func ensureReady() {
        if !askedFullscreen {
            askedFullscreen = true
            WindowBridge.setFullscreen?(true)
            ViewInvalidation.markNeedsRedraw()
            FrameScheduler.requestWake(in: 0.05)
            return
        }
        guard !askedCapture else { return }
        askedCapture = true
        capture()
    }

    /// Photographs the desktop and keeps it.
    ///
    /// This window is already up by then — it has to be, or there would be
    /// nothing to ask with — so the capture leaves it out. What comes back is
    /// the desktop as it was a moment before the tool appeared, which is the
    /// shot the user meant.
    private func capture() {
        guard let path = ScreenCapture.screen(includeSelf: false) else {
            notice = "This build cannot photograph the desktop"
            ViewInvalidation.markDirty()
            return
        }
        shotPath = path
        shot = ImageStore.load(path: path, into: editor)
        if let shot {
            shotWidth = Int(shot.pixelWidth)
            shotHeight = Int(shot.pixelHeight)
        } else {
            notice = "The screen could not be decoded"
        }
        ViewInvalidation.markDirty()
    }

    // MARK: - Drawing

    func beginDraw(at point: ShotPoint, screen: ShotRect) {
        notice = nil
        if tool == .select || selection == nil {
            // The first drag makes the selection whatever tool is chosen: there
            // is nothing to annotate until there is something to keep.
            drafting = ShotStroke(
                tool: .select, color: color, width: strokeWidth,
                points: [point, point]
            )
            selection = ShotRect(x: point.x, y: point.y, w: 0, h: 0)
            ViewInvalidation.markDirty()
            return
        }
        drafting = ShotStroke(
            tool: tool, color: color, width: strokeWidth, points: [point]
        )
        ViewInvalidation.markDirty()
    }

    func continueDraw(to point: ShotPoint, screen: ShotRect) {
        guard var stroke = drafting else { return }
        if stroke.tool == .pen {
            stroke.points.append(point)
        } else if stroke.points.count < 2 {
            stroke.points.append(point)
        } else {
            stroke.points[1] = point
        }
        drafting = stroke
        if stroke.tool == .select {
            selection = ShotRect.between(stroke.start, point).clamped(to: screen)
        }
        ViewInvalidation.markDirty()
    }

    func endDraw() {
        defer {
            drafting = nil
            ViewInvalidation.markDirty()
        }
        guard let stroke = drafting else { return }
        if stroke.tool == .select {
            // A click with no drag clears the selection rather than leaving a
            // one-pixel one nobody can see and nothing can be drawn in.
            if let current = selection, current.w < 4 || current.h < 4 {
                selection = nil
            }
            // Once a region exists, the tool that made it is not the tool
            // anybody wants next — they want to draw on it.
            if selection != nil, tool == .select { tool = .rectangle }
            return
        }
        document.add(stroke)
    }

    // MARK: - The toolbar

    func perform(_ action: ShotAction) {
        notice = nil
        switch action {
        case .tool(let picked):
            tool = picked
        case .color(let index):
            colorIndex = min(max(index, 0), ShotColor.palette.count - 1)
        case .thinner:
            widthIndex = max(0, widthIndex - 1)
        case .thicker:
            widthIndex = min(ShotOutput.widths.count - 1, widthIndex + 1)
        case .undo:
            document.undo()
        case .redo:
            document.redo()
        case .copy:
            copy()
        case .save:
            save()
        case .cancel:
            quit()
        }
        ViewInvalidation.markDirty()
    }

    // MARK: - Getting it out

    /// Both exports go the same way: hide the interface, let one frame be
    /// drawn, then ask the compositor what this window looks like.
    ///
    /// The alternative is rasterising the annotations in this process, which
    /// means writing a line renderer, an ellipse renderer and a glyph
    /// rasteriser to draw a second time what the engine has already drawn
    /// once — and having them disagree. The window is showing exactly the
    /// wanted result already; the only thing wrong with it is the toolbar on
    /// top, and that is one boolean.
    func copy() {
        guard readyToExport else { return }
        exporting = .copy
        ViewInvalidation.markDirty()
    }

    func save() {
        guard readyToExport else { return }
        exporting = .save(ShotOutput.defaultURL())
        ViewInvalidation.markDirty()
    }

    func saveAs() {
        guard readyToExport else { return }
        guard let url = FileDialog.saveFile(
            title: "Save Screenshot",
            defaultName: ShotOutput.defaultURL().lastPathComponent
        ) else { return }
        exporting = .save(url)
        ViewInvalidation.markDirty()
    }

    /// The two-frame dance the export needs, driven from the top of `paint`.
    ///
    /// A capture reads the window's *current* buffer, so asking for one in the
    /// same frame that hid the toolbar would photograph the frame before it —
    /// toolbar and all. So the first pass paints clean and asks for another
    /// frame; the second pass runs when that clean frame has been presented,
    /// and captures it.
    func beforePaint(screen: ShotRect, scale: Float) {
        ensureReady()
        guard exporting != nil else { return }
        if exportArmed {
            exportArmed = false
            finishExport(scale: scale, screen: screen)
            return
        }
        exportArmed = true
        ViewInvalidation.markNeedsRedraw()
        FrameScheduler.requestWake(in: 0.02)
    }

    private var readyToExport: Bool {
        guard hasShot else { return false }
        guard exporting == nil else { return false }
        return true
    }

    /// Called from the paint closure on the frame *after* the interface came
    /// off, when what is on screen is the finished picture.
    ///
    /// The crop is asked of the compositor rather than taken here, because a
    /// client has no codec: a region of a PNG is not something it can cut out
    /// for itself. `includeSelf` is true this time — this window *is* the
    /// picture now, covering the output and showing the shot with the
    /// annotations on it and nothing else.
    func finishExport(scale: Float, screen: ShotRect) {
        guard let job = exporting else { return }
        exporting = nil

        let region = (selection ?? screen).rounded.scaled(by: scale).rounded
        guard let cropped = ScreenCapture.screen(
            includeSelf: true,
            x: Int32(region.x), y: Int32(region.y),
            w: Int32(region.w), h: Int32(region.h)
        ) else {
            notice = "The picture could not be read back"
            ViewInvalidation.markDirty()
            return
        }

        switch job {
        case .copy:
            let ok = ClipboardBridge.writeImage(file: cropped)
            // The compositor has read the bytes by the time it answers, so the
            // file has done its job and nothing else will ever name it.
            try? FileManager.default.removeItem(atPath: cropped)
            if ok {
                finished("Copied")
            } else {
                notice = "This build cannot copy a picture"
            }
        case .save(let url):
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                // Moved, not copied: the compositor already wrote the bytes we
                // want, in the format we want them in.
                try FileManager.default.moveItem(
                    at: URL(fileURLWithPath: cropped), to: url
                )
                finished("Saved \(url.lastPathComponent)")
            } catch {
                try? FileManager.default.removeItem(atPath: cropped)
                notice = "Could not write \(url.path)"
            }
        }
        ViewInvalidation.markDirty()
    }

    /// Throws away the temporary file the shot was read from.
    ///
    /// The texture outlives it — it was uploaded when the file was registered
    /// — so this can happen at any point after that, and has to happen at
    /// some point: a tool that leaves a screenful of PNG in the temporary
    /// directory every time it runs is a tool that fills a disk.
    func discard() {
        guard let path = shotPath else { return }
        shotPath = nil
        try? FileManager.default.removeItem(atPath: path)
    }

    /// A shot that has been copied or written is finished with.
    ///
    /// It leaves rather than sitting there congratulating itself: this window
    /// is covering the whole screen, and the desktop underneath is what the
    /// user wants back. The notice is set anyway — a save that fails leaves it
    /// on screen, and the two paths should not be written differently.
    private func finished(_ message: String) {
        notice = message
        quit()
    }
}
