import Foundation
import LavaHost
import LavaUI
import LavaViewCore
import Observation

/// Everything the window shows: which picture, how big, which way up.
///
/// The split against `LavaViewCore` is the one this repo uses everywhere — the
/// arithmetic that decides where the picture sits is pure and tested, and this
/// type is the part that owns a texture, a thread, and a file handle.
///
/// Threading rule, also the repo's: decodes and encodes run on a worker and
/// every result lands back through `MainQueue.async`, so every property here
/// is written only by the thread that draws.
@Observable
final class ViewerSession: @unchecked Sendable {
    /// Longest edge the *display* texture is decoded at.
    ///
    /// Not a quality decision — a device limit. `maxImageDimension2D` is 16384
    /// on every desktop GPU and 4096 is all Vulkan guarantees; a 20000-pixel
    /// panorama decoded natively fails the upload and shows nothing at all,
    /// which is exactly the failure an image viewer must not have. 8192 is
    /// comfortably inside every real limit and past any display.
    ///
    /// Saving does **not** go through this. A rotate-and-save decodes the file
    /// again at native size, so what gets written is never the capped copy
    /// that was on screen. `Original size` on a picture longer than this is
    /// therefore 100% of what is held rather than of what is on disk — the
    /// status bar says so by reporting both numbers.
    static let displayDecodeSide: UInt32 = 8192

    enum Status: Equatable {
        case ready
        /// A turn is being applied to the pixels — a worker is busy.
        case turning
        case saving
        case failed(String)
    }

    // MARK: - What is open

    private(set) var folder: ImageFolder
    private(set) var status: Status = .ready
    /// Set when the current file will not decode, so Next can step over it.
    private(set) var loadError: String?

    /// The picture the user has moved to but which has not been decoded yet.
    ///
    /// While this is set, `texture` still holds the picture that was on screen
    /// when they stepped, and the canvas goes on drawing it. Cycling through a
    /// folder of large photographs otherwise blanked to the mat and back for
    /// every one of them — a black flash between every pair of pictures, which
    /// is the single worst thing a viewer can do to a folder of photographs.
    ///
    /// Observed, unlike the viewport fields below, because the bar reads it:
    /// rotating the outgoing picture would apply the turn to the incoming one.
    private(set) var awaiting: String?

    /// The turn applied to what is on screen, relative to the file as it was
    /// last read from disk.
    private(set) var rotation: Rotation = .none
    /// Whether that turn is only on screen. Saving clears it without undoing
    /// the turn — the file *is* the turned picture now.
    private(set) var hasUnsavedRotation = false

    /// Asked before an overwrite. Nil when nothing is pending.
    private(set) var pendingSave: SaveTarget?
    /// Briefly shown after a successful write, so a save that worked is not
    /// silent — the only other evidence is a file the user cannot see.
    private(set) var notice: String?

    // MARK: - Viewport
    //
    // Deliberately not observed. A pan writes one of these per pointer move,
    // and a body rebuild per move — to move a picture the paint closure reads
    // directly — would be pure waste. The handlers raise the exact
    // invalidation level they need instead: `.redraw` for a pan, a full body
    // pass for anything the control bar's labels are computed from.

    @ObservationIgnored private(set) var mode: ZoomMode = .fit
    @ObservationIgnored private var viewport = Viewport()
    @ObservationIgnored private var box = PixelSize(width: 0, height: 0)
    /// Size of the picture as drawn — the decoded size with the turn applied.
    @ObservationIgnored private(set) var displaySize = PixelSize(width: 0, height: 0)
    /// The texture on screen, whether that is the file itself or a turned copy.
    @ObservationIgnored private(set) var texture: UIImage?

    /// Turned textures this session has built, by turn and path. Ours rather
    /// than `ImageStore`'s: its keys are paths it will try to decode, and a
    /// synthetic one would put it in a retry loop against a file that does not
    /// exist.
    @ObservationIgnored private var turned: [String: UIImage] = [:]
    /// Pictures this session has written. `ImageStore` and the engine's own
    /// texture cache are both keyed by path and neither notices a file
    /// changing underneath them, so after a save the only thing that knows
    /// what is really on disk is us — and it is the texture we saved from.
    @ObservationIgnored private var writtenBack: [String: UIImage] = [:]
    /// Bumped on every load, turn and save: a worker that finishes after the
    /// user has moved on must not install its result.
    @ObservationIgnored private var generation = 0

    /// When the wait for `awaiting` began. The overlay that says a picture is
    /// coming is held back for a moment on this, so a cached step — which is
    /// most of them — shows nothing at all rather than a one-frame flicker.
    @ObservationIgnored private var awaitingSince: Double = 0
    /// Decodes started for the current picture that came back with nothing.
    /// With `ImageStore.isLoading` this is what distinguishes "still coming"
    /// from "came back empty": `imageIfLoaded` answers nil to both, and
    /// silently starts the work over.
    @ObservationIgnored private var emptyReturns = 0
    /// How many of those before the file is called unreadable.
    ///
    /// More than one because an empty return is not proof: `ImageStore` also
    /// evicts, and an image that decoded and was then evicted under budget
    /// pressure looks from here exactly like one that never decoded. A file
    /// that genuinely will not open fails again immediately, so three costs a
    /// fraction of a second; a cache miss succeeds on the retry and resets
    /// this to nothing.
    private static let emptyReturnsBeforeGivingUp = 3

    @ObservationIgnored private unowned let editor: Editor

    init(editor: Editor, folder: ImageFolder) {
        self.editor = editor
        self.folder = folder
        // The first picture is a wait like any other: arriving through the
        // constructor rather than through `show` does not make it decoded, and
        // the frame that notices a file which will not decode is scheduled off
        // this.
        self.awaiting = folder.current
        self.awaitingSince = FrameScheduler.now()
    }

    // MARK: - Reading state

    var currentPath: String? { folder.current }
    var currentName: String {
        (folder.current as NSString?)?.lastPathComponent ?? "No image"
    }

    /// Scale actually in use, resolved from the mode against the current box.
    var scale: Float {
        ViewportMath.scale(
            for: mode, image: displaySize, box: box, free: viewport.scale
        )
    }

    var zoomPercent: Int { Int((scale * 100).rounded()) }

    /// Where the picture is drawn, in canvas-local coordinates.
    var placement: Viewport {
        ViewportMath.clamped(
            Viewport(
                scale: scale, offsetX: viewport.offsetX, offsetY: viewport.offsetY
            ),
            image: displaySize, box: box
        )
    }

    var canPan: Bool {
        ViewportMath.isPannable(placement, image: displaySize, box: box)
    }

    var hasImage: Bool { texture != nil }
    var isBusy: Bool { status == .turning || status == .saving }
    /// True while the picture on screen is the previous one.
    var isAwaiting: Bool { awaiting != nil }
    /// Name of the picture being waited for, for the overlay that says so.
    var awaitingName: String {
        (awaiting as NSString?)?.lastPathComponent ?? ""
    }
    /// How long that wait has lasted, or nil when nothing is pending.
    var awaitingFor: Double? {
        awaiting == nil ? nil : FrameScheduler.now() - awaitingSince
    }

    /// "4032 × 3024", as drawn. Empty until something is on screen.
    ///
    /// Marked with a `~` when the decode was capped, because then it is not
    /// the number in the file and "1:1" is not really 1:1 — see
    /// `displayDecodeSide`. Saying nothing would be the easy option and would
    /// make the viewer quietly wrong about the one fact it exists to report.
    var dimensions: String {
        guard displaySize.width >= 1, displaySize.height >= 1 else { return "" }
        let w = Int(displaySize.width)
        let h = Int(displaySize.height)
        let capped = max(w, h) >= Int(Self.displayDecodeSide)
        return "\(capped ? "~" : "")\(w) × \(h)"
    }

    // MARK: - Frame hookup

    /// Called from the paint closure with the canvas box.
    ///
    /// Returns true only when the box actually changed, which is what keeps
    /// this from re-dirtying the frame it is painting — the trap documented on
    /// `@DrawState`, which cost the tab strip a thousand paints a second.
    @discardableResult
    func setBox(width: Float, height: Float) -> Bool {
        let next = PixelSize(width: width, height: height)
        guard next != box else { return false }
        box = next
        // Fit is defined against the box, so a resize moves it; a free zoom is
        // the user's number and survives, but its offset may now be illegal.
        viewport = ViewportMath.clamped(
            Viewport(scale: scale, offsetX: viewport.offsetX, offsetY: viewport.offsetY),
            image: displaySize, box: box
        )
        return true
    }

    /// Resolves the texture for this frame. Called from paint; nil only when
    /// there is genuinely nothing to draw, which is the caller's cue to draw
    /// the "opening" state rather than a hole.
    @discardableResult
    func resolveTexture() -> UIImage? {
        // A turned picture is its own upload, installed by the worker.
        if rotation != .none { return texture }
        guard let path = folder.current, loadError == nil else { return nil }
        // A file we wrote ourselves: the caches below still hold what it
        // looked like before, so answer from what we know.
        if let ours = writtenBack[path] {
            adopt(ours)
            return ours
        }

        // Asked *before* `imageIfLoaded`, which starts a decode and would make
        // the answer yes whatever the truth was a moment ago.
        let wasDecoding = ImageStore.isLoading(
            path: path, maxPixelSize: Self.displayDecodeSide
        )
        if let image = ImageStore.imageIfLoaded(
            path: path, maxPixelSize: Self.displayDecodeSide, into: editor
        ) {
            adopt(image)
            return image
        }
        // Not in the cache, and nothing was decoding it when we asked — so
        // whatever we started last time came back with nothing. Counted rather
        // than believed at once, for the reason on `emptyReturnsBeforeGivingUp`.
        // Something has to count them: otherwise the picture being held stays
        // up for ever in front of a file that will never arrive, and
        // `skipUnreadable` — the way out — is never offered.
        if !wasDecoding {
            emptyReturns += 1
            if emptyReturns > Self.emptyReturnsBeforeGivingUp {
                reportUnreadable()
                return nil
            }
        }

        // Still coming. `texture` is the picture that was on screen when the
        // user stepped, `displaySize` and the viewport still describe it, so
        // everything drawn and reported this frame is about the same picture.
        return texture
    }

    /// Installs a texture and, on a genuinely new picture, re-fits it.
    ///
    /// Reached from `resolveTexture`, which runs during paint — so the body
    /// pass that built the control bar happened *before* this frame knew how
    /// big the picture was, and its "100%" was computed against a size of
    /// zero. Asking for another body pass is what corrects the label, and the
    /// guard above is what stops it being a loop: this only fires on the frame
    /// a decode actually lands.
    private func adopt(_ image: UIImage) {
        let size = PixelSize(width: image.pixelWidth, height: image.pixelHeight)
        let same = texture?.cacheKey == image.cacheKey && size == displaySize
        texture = image
        // The one being waited for has arrived. It lands fitted: a zoom set on
        // the picture before it is not a statement about this one. Cleared
        // only when it was set, because this runs during paint and an
        // unconditional write to an observed field re-dirties the frame that
        // is painting it.
        let arrived = awaiting != nil
        emptyReturns = 0
        if arrived {
            awaiting = nil
            mode = .fit
        }
        guard !same || arrived else { return }
        displaySize = size
        recentre()
        // Only now is it worth reading ahead — see `prefetchNeighbours`.
        prefetchNeighbours()
        ViewInvalidation.markDirty()
    }

    private func recentre() {
        viewport = ViewportMath.centered(
            scale: ViewportMath.scale(
                for: mode, image: displaySize, box: box, free: viewport.scale
            ),
            image: displaySize, box: box
        )
    }

    // MARK: - Moving through the folder

    func step(_ delta: Int) {
        let next = folder.advanced(by: delta)
        guard next != folder else { return }
        show(next)
    }

    func jump(to index: Int) {
        let next = folder.jumped(to: index)
        guard next != folder else { return }
        show(next)
    }

    func open(paths: [String]) {
        guard let first = paths.first else { return }
        let next = paths.count > 1
            ? ImageFolder.explicit(paths: paths)
            : ImageFolder.around(path: first)
        guard !next.isEmpty else {
            status = .failed(
                "No images in \((first as NSString).deletingLastPathComponent)"
            )
            ViewInvalidation.markDirty()
            return
        }
        show(next)
    }

    func openDialog() {
        guard let url = FileDialog.openFile(
            title: "Open Image",
            filters: [.init(name: "Images", extensions: ImageFormats.dialogExtensions)]
        ) else { return }
        open(paths: [url.path])
    }

    func reloadFolder() { show(folder.rescanned()) }

    private func show(_ next: ImageFolder) {
        folder = next
        generation += 1
        loadError = nil
        notice = nil
        pendingSave = nil
        status = .ready
        // A turn belongs to the picture that was turned. Carrying it to the
        // next one would silently rotate a folder of photographs one by one.
        rotation = .none
        hasUnsavedRotation = false
        // `texture`, `displaySize`, `mode` and the viewport are deliberately
        // left alone: they describe the picture still on screen, and it stays
        // on screen until the new one is decoded. `adopt` replaces the lot in
        // one go when that happens, so no frame is ever drawn from half of one
        // picture and half of another.
        awaiting = folder.current
        awaitingSince = FrameScheduler.now()
        emptyReturns = 0
        ViewInvalidation.markDirty()
    }

    /// Decodes the pictures on either side once the current one has landed.
    ///
    /// The whole reason Next feels instant. `ImageStore`'s budget is what stops
    /// this growing without bound — an entry only goes when the cache is over
    /// it, and never on a frame it was drawn.
    ///
    /// Called from `adopt`, and that placement is the fix rather than a detail.
    /// It used to be called from `show`, one frame *before* the picture it had
    /// just asked for existed, and its "has the current one landed?" guard was
    /// therefore false every time — the read-ahead ran only when the picture
    /// was already cached, which is exactly when nobody needed it. Every step
    /// through a folder decoded cold.
    private func prefetchNeighbours() {
        guard folder.count > 1 else { return }
        // Only when this picture and both its neighbours fit in the cache at
        // once. Past that the read-ahead is self-defeating and then some: the
        // cache evicts to make room for what is being read ahead, and the
        // first thing it lets go of is the picture on screen — which is then
        // decoded again to draw the next frame, in front of a user who has not
        // touched anything. A picture that large is one nobody steps through
        // quickly anyway.
        let bytes = Int(displaySize.width) * Int(displaySize.height) * 4
        guard bytes * 3 <= ImageStore.budgetBytes else { return }
        let token = generation
        FrameTasks.after { [weak self] in
            // The user may have stepped on while this waited for the frame to
            // be presented; their neighbours are the ones worth having.
            guard let self, token == self.generation else { return }
            for step in [1, -1] {
                guard let path = self.folder.advanced(by: step).current,
                      self.writtenBack[path] == nil
                else { continue }
                _ = ImageStore.imageIfLoaded(
                    path: path, maxPixelSize: Self.displayDecodeSide, into: self.editor
                )
            }
        }
    }

    /// The current file will not decode. Reported once, then stepped over on
    /// the next Next — a folder with one bad file in it must not become a dead
    /// end.
    func reportUnreadable() {
        guard folder.current != nil, loadError == nil else { return }
        loadError = "\(currentName) could not be opened"
        awaiting = nil
        texture = nil
        displaySize = PixelSize(width: 0, height: 0)
        ViewInvalidation.markDirty()
    }

    func skipUnreadable() {
        guard let path = folder.current, loadError != nil else { return }
        let next = folder.removing(path)
        guard !next.isEmpty else {
            folder = next
            loadError = nil
            texture = nil
            ViewInvalidation.markDirty()
            return
        }
        show(next)
    }

    // MARK: - Zoom

    func setMode(_ next: ZoomMode) {
        guard mode != next else { return }
        mode = next
        recentre()
        ViewInvalidation.markDirty()
    }

    /// One wheel gesture, anchored where the pointer is.
    func wheelZoom(notches: Float, atX x: Float, atY y: Float) {
        guard hasImage, notches != 0 else { return }
        apply(
            ViewportMath.zoomed(
                placement, to: ZoomLadder.wheeled(scale, notches: notches),
                anchorX: x, anchorY: y, image: displaySize, box: box
            )
        )
    }

    /// The `+` / `-` controls: a step on the ladder, about the middle.
    func stepZoom(_ direction: Int) {
        guard hasImage, direction != 0 else { return }
        let target = direction > 0
            ? ZoomLadder.next(above: scale)
            : ZoomLadder.next(below: scale)
        apply(
            ViewportMath.zoomedCentre(
                placement, to: target, image: displaySize, box: box
            )
        )
    }

    private func apply(_ next: Viewport) {
        // Any explicit zoom leaves the modes: the number is now the user's,
        // and a window resize must not take it away from them.
        mode = .free
        viewport = next
        ViewInvalidation.markDirty()
    }

    func pan(dx: Float, dy: Float) {
        guard canPan else { return }
        viewport = ViewportMath.panned(
            placement, dx: dx, dy: dy, image: displaySize, box: box
        )
        // Nothing in the control bar is computed from the offset, so no body
        // depends on it — pixels are all that need to move.
        ViewInvalidation.markNeedsRedraw()
    }

    /// Double-click, and the middle button on the bar: the toggle people
    /// actually use, between seeing all of it and seeing it properly.
    func toggleFitActual() {
        setMode(mode == .actual ? .fit : .actual)
    }

    // MARK: - Rotation

    func rotateRight() { turn(to: rotation.turnedRight()) }
    func rotateLeft() { turn(to: rotation.turnedLeft()) }

    private func turn(to next: Rotation) {
        guard let path = folder.current, hasImage, !isBusy, !isAwaiting else { return }
        rotation = next
        hasUnsavedRotation = next != .none
        notice = nil
        pendingSave = nil

        // Back to upright: whatever `resolveTexture` would have given us is
        // still the right answer, so drop ours and let it.
        guard next != .none else {
            status = .ready
            texture = nil
            displaySize = PixelSize(width: 0, height: 0)
            ViewInvalidation.markDirty()
            return
        }

        let key = Self.turnedKey(path: path, rotation: next)
        if let cached = turned[key] {
            status = .ready
            install(cached)
            return
        }

        generation += 1
        let token = generation
        status = .turning
        ViewInvalidation.markDirty()

        Thread.detachNewThread { [weak self] in
            let decoded = Editor.decodeImage(
                path: path, maxPixelSize: Self.displayDecodeSide
            )
            let result = decoded.flatMap {
                PixelRotate.rotate(
                    pixels: $0.pixels, width: Int($0.width), height: Int($0.height),
                    by: next
                )
            }
            MainQueue.async { [weak self] in
                self?.finishTurn(token, key: key, result: result)
            }
        }
    }

    private func finishTurn(
        _ token: Int, key: String,
        result: (pixels: [UInt8], width: Int, height: Int)?
    ) {
        guard token == generation else { return }
        guard let result,
              let image = upload(
                  key: key, pixels: result.pixels,
                  width: UInt32(result.width), height: UInt32(result.height)
              )
        else {
            status = .failed("Could not turn \(currentName)")
            rotation = .none
            hasUnsavedRotation = false
            ViewInvalidation.markDirty()
            return
        }
        status = .ready
        turned[key] = image
        install(image)
    }

    private func install(_ image: UIImage) {
        texture = image
        displaySize = PixelSize(width: image.pixelWidth, height: image.pixelHeight)
        // A turn changes which way the picture is long, so a fit computed for
        // the old shape is wrong; re-place it whatever the mode.
        recentre()
        ViewInvalidation.markDirty()
    }

    /// Gets pixels onto the GPU in whichever mode this process is running in.
    ///
    /// Windowed, that is a direct upload. As a compositor client there is no
    /// device here at all: the pixels have to be encoded and handed over, and
    /// `Editor.uploadImage` is not the call for it — its remote branch caps at
    /// 64 pixels, which is right for the tray icon it was written for and
    /// would turn a photograph into a thumbnail.
    private func upload(
        key: String, pixels: [UInt8], width: UInt32, height: UInt32
    ) -> UIImage? {
        guard !LavaHost.isClient else {
            guard let png = Editor.encodePng(
                pixels: pixels, width: width, height: height
            ) else { return nil }
            return editor.resources.registerImage(data: png, maxPixelSize: 0)
        }
        return editor.uploadImage(
            key: key, path: key, pixels: pixels, width: width, height: height
        )
    }

    private static func turnedKey(path: String, rotation: Rotation) -> String {
        "lavaview-rot:\(rotation.rawValue):\(path)"
    }

    // MARK: - Saving

    /// Asks first. Writing over a photograph is not something to do on one
    /// click, and the answer depends on facts the user cannot see — whether
    /// the format survives the round trip, and whether it is lossy.
    func requestSave() {
        guard hasUnsavedRotation, let path = folder.current, !isBusy else { return }
        // Alpha is not known until the native decode, so this is the optimistic
        // answer; `encodeRotated` asks again with the real pixels and re-routes
        // to PNG if it finds transparency.
        pendingSave = SaveTarget.inPlace(path: path, hasAlpha: false)
        ViewInvalidation.markDirty()
    }

    func cancelSave() {
        guard pendingSave != nil else { return }
        pendingSave = nil
        ViewInvalidation.markDirty()
    }

    func confirmSave() {
        guard let target = pendingSave, let source = folder.current else { return }
        pendingSave = nil
        write(rotation, from: source, to: target)
    }

    /// Save As: the picker named the file, so there is nothing to confirm.
    func saveCopy() {
        guard hasUnsavedRotation, let source = folder.current, !isBusy else { return }
        guard let url = FileDialog.saveFile(
            title: "Save Rotated Copy",
            filters: [.init(name: "Images", extensions: ["png", "jpg", "jpeg"])],
            defaultName: (source as NSString).lastPathComponent
        ) else { return }
        write(rotation, from: source, to: SaveTarget.explicit(path: url.path, hasAlpha: false))
    }

    /// Decodes the original at **native** size, turns it, encodes, writes.
    ///
    /// The native decode is the point: the picture on screen went through
    /// `displayDecodeSide`, and saving that back would quietly shrink a
    /// photograph that was only ever meant to be turned.
    private func write(_ turn: Rotation, from source: String, to target: SaveTarget) {
        generation += 1
        let token = generation
        let shown = texture
        status = .saving
        ViewInvalidation.markDirty()

        Thread.detachNewThread { [weak self] in
            let result = Self.encodeRotated(from: source, turn: turn, target: target)
            MainQueue.async { [weak self] in
                self?.finishSave(token, result: result, shown: shown)
            }
        }
    }

    private struct SaveResult {
        var path: String
        var error: String?
    }

    private static func encodeRotated(
        from source: String, turn: Rotation, target: SaveTarget
    ) -> SaveResult {
        guard let decoded = Editor.decodeImage(path: source, maxPixelSize: 0) else {
            return SaveResult(path: target.path, error: "could not re-read the original")
        }
        guard let result = PixelRotate.rotate(
            pixels: decoded.pixels, width: Int(decoded.width),
            height: Int(decoded.height), by: turn
        ) else {
            return SaveResult(path: target.path, error: "could not turn the pixels")
        }

        // Alpha is only knowable from the pixels, and only now are the real
        // ones in hand. A file named `.jpg` that decoded with transparency is
        // re-routed to PNG here rather than saved with black holes in it.
        let hasAlpha = PixelRotate.hasTransparency(pixels: result.pixels)
        let final = hasAlpha && target.isLossy
            ? SaveTarget.inPlace(path: target.path, hasAlpha: true)
            : target

        let w = UInt32(result.width)
        let h = UInt32(result.height)
        let bytes: [UInt8]?
        switch final.encoding {
        case .png:
            bytes = Editor.encodePng(pixels: result.pixels, width: w, height: h)
        case .jpeg(let quality):
            bytes = Editor.encodeJpeg(
                pixels: result.pixels, width: w, height: h, quality: quality
            )
        }
        guard let bytes, !bytes.isEmpty else {
            return SaveResult(path: final.path, error: "could not encode it")
        }

        // Written beside the target and renamed over it. A crash halfway
        // through a direct write leaves a truncated photograph and no
        // original; a rename within one directory is atomic.
        let temporary = final.path + ".lavaview-tmp"
        do {
            try Data(bytes).write(to: URL(fileURLWithPath: temporary))
            if FileManager.default.fileExists(atPath: final.path) {
                _ = try? FileManager.default.removeItem(atPath: final.path)
            }
            try FileManager.default.moveItem(atPath: temporary, toPath: final.path)
        } catch {
            try? FileManager.default.removeItem(atPath: temporary)
            return SaveResult(
                path: final.path,
                error: "could not write it (\(error.localizedDescription))"
            )
        }
        return SaveResult(path: final.path, error: nil)
    }

    private func finishSave(_ token: Int, result: SaveResult, shown: UIImage?) {
        guard token == generation else { return }
        let name = (result.path as NSString).lastPathComponent
        status = .ready
        if let error = result.error {
            status = .failed("Could not save \(name): \(error)")
            ViewInvalidation.markDirty()
            return
        }

        notice = "Saved \(name)"
        // The file on disk *is* the turned picture now, so the turn is spent —
        // but what is on screen is still right, and must not flip back. Record
        // the texture as the truth for that path: `ImageStore` and the engine
        // are both keyed by path and neither notices a file changing under
        // them, so a re-read here would hand back the old orientation.
        rotation = .none
        hasUnsavedRotation = false
        if let shown { writtenBack[result.path] = shown }
        if result.path != folder.current {
            // A format change (an SVG that had to become a PNG) wrote a new
            // file. Land on what we just made rather than on what it came from.
            folder = ImageFolder.around(path: result.path)
        }
        ViewInvalidation.markDirty()
    }

    func dismissNotice() {
        var changed = false
        if notice != nil { notice = nil; changed = true }
        if case .failed = status { status = .ready; changed = true }
        guard changed else { return }
        ViewInvalidation.markDirty()
    }
}
