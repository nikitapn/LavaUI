#if canImport(CxxCanvas)
import CxxCanvas
import Foundation

// LavaUI — declarative UI + canvas engine bridge.
//
// Swift wrapper over `canvas::Engine` — direct C++ interop, no C shim.
///
/// This used to wrap a flat `canvas::swiftEditor*` free-function API (a
/// `SwiftEditor*` opaque handle passed to every call) because Swift's C++
/// interop wouldn't import `Engine` as a class at the time. That's no longer
/// true: `Engine` has a proper move constructor (pimpl'd, non-copyable) and
/// imports cleanly, so this now just holds one and calls its methods
/// directly — no `OpaquePointer`, no `strdup`/`free`, no manually building
/// `char**` arrays for tree/property lists.
///
/// C++ containers: use the named specializations in `canvas` (`U8Vector`,
/// `StringVector`, …). Bare `std.vector<T>` is still unavailable to Swift
/// (ClangImporter + libstdc++ `vector<bool>`); the `using` aliases import.
///
/// `VoidResult` (std::expected) `.error()` returns a reference that Swift
/// interop won't call, so open failures surface as `nil`/`false` — check
/// stderr if you need the message (Engine logs it).
public final class Editor: @unchecked Sendable {
    private var engine = canvas.Engine()

    private init() {}

    public static func open(
        assetsRoot: String,
        width: Int32 = 1280,
        height: Int32 = 800,
        title: String = "FBD Editor"
    ) -> Editor? {
        let editor = Editor()
        let opened = editor.engine.openWindow(
            std.string(assetsRoot), UInt32(width), UInt32(height), std.string(title)
        ).has_value()
        guard opened else { return nil }
        editor.engine.setWindowVisible(true)
        return editor
    }

    public var isOpen: Bool { engine.isOpen() }

    /// Ask the frame loop to exit (GLFW should-close). Safe from menu actions.
    public func requestClose() { engine.requestClose() }

    /// Drive the window from this thread. `timeout` < 0 blocks until an event
    /// arrives, 0 polls, > 0 waits at most that long. Blocking is what keeps
    /// an idle UI at zero CPU while still waking immediately on input.
    public func pumpEvents(timeout: Double) { engine.pumpEvents(timeout) }

    /// Unblock a waiting `pumpEvents` from any thread (agent socket watcher).
    public func wakeEventLoop() { engine.wakeEventLoop() }

    // ─── Windows ─────────────────────────────────────────────────────────
    //
    // Every per-window call takes a `window:` that defaults to `.main`, so
    // single-window code never mentions it. All windows share one GPU, one
    // font atlas and one texture cache — that sharing is the reason a second
    // window is cheap.

    /// Opens an additional window. Returns its id, or `nil` on failure.
    ///
    /// It starts hidden. Draw a frame into it, then `setVisible(true, window:)`
    /// — showing a window before its first frame presents an undefined
    /// swapchain image, which looks like a flash of garbage.
    public func openWindow(
        width: Float = 800, height: Float = 600, title: String
    ) -> WindowID? {
        let id = engine.openWindow(UInt32(width), UInt32(height), std.string(title))
        return id == 0 ? nil : WindowID(raw: id)
    }

    /// Closes one window. Every other window, and the device, survive it.
    public func closeWindow(_ window: WindowID) {
        engine.closeWindow(window.raw)
    }

    /// Number of open windows. Zero is how an app knows to exit.
    public var windowCount: Int { Int(engine.windowCount()) }

    /// Ids of the open windows, in creation order.
    public var windowIDs: [WindowID] {
        (0..<engine.windowCount()).compactMap {
            let id = engine.windowIdAt($0)
            return id == 0 ? nil : WindowID(raw: id)
        }
    }

    /// Whether this window has been asked to close (its titlebar X, a WM
    /// request). The caller decides what that means — closing the last window
    /// usually ends the app, closing any other is just `closeWindow`.
    ///
    /// False for a window that is already closed: "asked to close" and "does
    /// not exist" are different questions, and `windowCount` answers the
    /// second.
    public func windowShouldClose(_ window: WindowID = .main) -> Bool {
        engine.windowShouldClose(window.raw)
    }

    /// Consumes "this window needs redrawing for a reason of its own".
    ///
    /// The third repaint signal, alongside "a producer published" and "input
    /// arrived": the renderer moves scene nodes itself — a scroll today — and
    /// when it does, nothing is published and nothing is queued, because the
    /// point of a retained tree is that the producer is not involved.
    public func takeInternalRepaint(window: WindowID = .main) -> Bool {
        engine.takeInternalRepaint(window.raw)
    }

    /// Offers a wheel notch to the retained scroll containers under the
    /// pointer, after nothing in this process wanted it.
    ///
    /// The renderer normally keeps the wheel — that is what lets a list scroll
    /// while this process is busy — and only forwards the event where a node
    /// declared a handler of its own. Whether that handler takes a given notch
    /// is a question only this process can answer, so when the answer is no,
    /// the event goes back. Returns whether anything moved.
    @discardableResult
    public func scrollSceneUnclaimed(
        dx: Float, dy: Float, window: WindowID = .main
    ) -> Bool {
        engine.scrollSceneUnclaimed(dx, dy, window.raw)
    }

    public func setVisible(_ visible: Bool, window: WindowID = .main) {
        engine.setWindowVisible(visible, window.raw)
    }

    /// Render and present one frame.
    @discardableResult
    public func renderFrame(window: WindowID = .main) -> Bool {
        engine.renderFrame(window.raw)
    }

    // ─── Shared-memory arena ─────────────────────────────────────────────

    /// Drives this window from a draw arena another process writes, instead
    /// of from a `DrawList` submitted in this one.
    ///
    /// The producer creates the arena and this attaches to it, so the order
    /// is producer-then-renderer. Returns false if it is missing or its
    /// header does not check out.
    @discardableResult
    public func attachDrawArena(id: String, window: WindowID = .main) -> Bool {
        engine.attachDrawArena(std.string(id), window.raw)
    }

    public func detachDrawArena(window: WindowID = .main) {
        engine.detachDrawArena(window.raw)
    }

    // ─── Declarative UI ──────────────────────────────────────────────────

    // ─── Phase 3 draw list ───────────────────────────────────────────────

    func ensureDrawListCapacity(
        commands: Int, glyphs: Int, meshVertices: Int, spatialVertices: Int,
        window: WindowID = .main
    ) {
        engine.ensureDrawListCapacity(
            commands, glyphs, meshVertices, spatialVertices, window.raw
        )
    }

    func drawListStorage(window: WindowID = .main) -> (
        commands: UnsafeMutablePointer<canvas.DrawCommand>, commandCapacity: Int,
        glyphs: UnsafeMutablePointer<canvas.GlyphInstance>, glyphCapacity: Int,
        meshVertices: UnsafeMutablePointer<canvas.MeshVertex>, meshVertexCapacity: Int,
        spatialVertices: UnsafeMutablePointer<canvas.SpatialVertex>, spatialVertexCapacity: Int
    ) {
        (
            engine.drawCommandData(window.raw), engine.drawCommandCapacity(window.raw),
            engine.drawGlyphData(window.raw), engine.drawGlyphCapacity(window.raw),
            engine.drawMeshVertexData(window.raw), engine.drawMeshVertexCapacity(window.raw),
            engine.drawSpatialVertexData(window.raw),
            engine.drawSpatialVertexCapacity(window.raw)
        )
    }

    public func submitDrawList(_ list: DrawList) {
        precondition(list.editor === self, "a DrawList belongs to its creating Editor")
        engine.commitDrawList(
            list.commandCount, list.glyphCount, list.meshVertexCount,
            list.spatialVertexCount, list.window.raw
        )
    }

    /// Install face for draw-list text (must match UIFont used for measure).
    @discardableResult
    public func loadFont(path: String, pixelSize: Float) -> Bool {
        engine.loadFont(std.string(path), pixelSize).has_value()
    }

    /// Registers a face for glyph lookup; returns its id, or nil on failure.
    /// Idempotent per (path, pixelSize).
    /// System clipboard. Empty when headless.
    public var clipboardText: String {
        get { String(engine.clipboardText()) }
        set { engine.setClipboardText(std.string(newValue)) }
    }

    public func registerFont(path: String, pixelSize: Float) -> UInt32? {
        let id = engine.registerFont(std.string(path), pixelSize)
        return id >= 0 ? UInt32(id) : nil
    }

    /// Load a PNG/JPEG for `Image` views. Returns a handle or nil on failure.
    /// Idempotent per absolute path.
    public func loadImage(path: String) -> UIImage? {
        let id = engine.loadTexture(std.string(path))
        guard id > 0 else { return nil }
        var w: Float = 0
        var h: Float = 0
        guard engine.textureSize(UInt32(id), &w, &h), w >= 1, h >= 1 else {
            return nil
        }
        return UIImage(path: path, textureId: UInt32(id), pixelWidth: w, pixelHeight: h)
    }
    /// Decodes an image file to RGBA8 without touching the GPU.
    ///
    /// Safe to call from a worker thread — that is the whole point. Decoding a
    /// JPEG is tens of milliseconds and does not need the device; only the
    /// upload does. Returns nil if the file will not decode.
    ///
    /// `maxPixelSize` (0 = native) caps the longer edge. Returned `width` and
    /// `height` are the size after any downscale, so the caller sizes its
    /// texture from these rather than from what the file claimed.
    public nonisolated static func decodeImage(
        path: String,
        maxPixelSize: UInt32 = 0
    ) -> (pixels: [UInt8], width: UInt32, height: UInt32)? {
        let decoded = canvas.Engine.decodeImage(std.string(path), maxPixelSize)
        guard decoded.valid() else { return nil }
        let n = Int(decoded.pixels.size())
        var pixels = [UInt8]()
        pixels.reserveCapacity(n)
        for i in 0..<n {
            pixels.append(decoded.pixels[i])
        }
        return (pixels, decoded.width, decoded.height)
    }

    /// Uploads pre-decoded pixels. Main thread only — it touches the device.
    ///
    /// `key` is the texture identity (see `UIImage.cacheKey`); `path` is the
    /// file it came from, and defaults to `key` for callers that decode at
    /// native size and need no distinction.
    public func uploadImage(
        key: String, path: String? = nil,
        pixels: [UInt8], width: UInt32, height: UInt32
    ) -> UIImage? {
        // Pointer overload: avoids copying [UInt8] into a U8Vector just to
        // hand bytes to Vulkan. (U8Vector overload exists for C++ callers.)
        let id: Int32 = pixels.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return -1 }
            return engine.uploadTexture(std.string(key), base, width, height)
        }
        guard id > 0 else { return nil }
        return UIImage(
            path: path ?? key, cacheKey: key, textureId: UInt32(id),
            pixelWidth: Float(width), pixelHeight: Float(height)
        )
    }

    /// Whether the engine already has this key resident.
    public func hasImage(key: String) -> Bool {
        engine.hasTexture(std.string(key))
    }

    /// Drops one reference to a loaded image.
    ///
    /// The GPU memory is not freed here. Vulkan releases it only once every
    /// frame that could still sample it has retired, so calling this on an
    /// image that is on screen right now is safe — see
    /// `Vulkan::destroyImageDeferred`. An atlased image returns its cell to
    /// the page instead, and the page stays.
    public func unloadImage(path: String) {
        engine.unloadTexture(std.string(path))
    }


    /// Raw input: mouse, resize, key (see `InputEventKind`).
    public func pollInputEvent(window: WindowID = .main) -> InputEvent? {
        var ev = canvas.InputEvent()
        guard engine.pollInputEvent(&ev, window.raw) else { return nil }
        let kind = InputEventKind(rawValue: ev.kind) ?? .none
        return InputEvent(kind: kind, x: ev.x, y: ev.y, button: ev.button, mods: ev.mods)
    }

    /// Paths from the most recent `.fileDrop` event. Valid only while
    /// handling that event — the next drop overwrites them.
    public func droppedFiles(window: WindowID = .main) -> [String] {
        let paths = engine.pendingDroppedFiles(window.raw)
        var out: [String] = []
        out.reserveCapacity(Int(paths.size()))
        for i in 0..<paths.size() {
            out.append(String(paths[i]))
        }
        return out
    }

    /// False while minimized/occluded. The frame loop gates continuous
    /// (animation-driven) redraw work on this, since Yoga/cull-rect
    /// visibility has no idea the whole window is off-screen.
    public var isWindowVisible: Bool { engine.isWindowVisible(0) }

    /// False while this window is minimized/occluded.
    public func isVisible(window: WindowID) -> Bool {
        engine.isWindowVisible(window.raw)
    }

    /// Current swapchain / framebuffer size in pixels.
    public func framebufferSize(window: WindowID = .main) -> (w: Float, h: Float) {
        var w: Float = 0
        var h: Float = 0
        engine.framebufferSize(&w, &h, window.raw)
        return (w, h)
    }

    /// Whole-window camera. Layout and Yoga stay at zoom=1; the quad shader
    /// applies center-zoom then pan. Hit-tests must unproject first.
    public func setViewTransform(
        zoom: Float, panX: Float = 0, panY: Float = 0, window: WindowID = .main
    ) {
        engine.setViewTransform(zoom, panX, panY, window.raw)
    }

    // ─── Agent / automation ──────────────────────────────────────────────

    /// Inject pointer motion into the same queue as GLFW (layout pixels).
    public func injectPointerMove(x: Float, y: Float) {
        engine.pointerMove(x, y)
    }

    /// Inject mouse button. `button` is GLFW-style (0 = left).
    public func injectPointerButton(button: Int32, pressed: Bool, x: Float, y: Float) {
        engine.pointerButton(button, pressed, x, y)
    }

    /// Inject wheel/trackpad delta (notches), same coalescing queue as real scroll.
    public func injectScroll(dx: Float, dy: Float) {
        engine.pointerScroll(dx, dy)
    }

    /// Inject a key event. `action`: 0 release, 1 press, 2 repeat (GLFW).
    public func injectKey(key: Int32, action: Int32 = 1, mods: Int32 = 0) {
        engine.keyEvent(key, action, mods)
    }

    /// Inject UTF-8 text as character events (focused text field path).
    public func injectText(_ utf8: String) {
        engine.textInput(std.string(utf8))
    }

    /// Capture the resolve target as PNG (base64). Region in framebuffer
    /// pixels; omit or pass w/h ≤ 0 for the full frame.
    /// `maxSide` > 0 box-downsamples so the longer encoded side ≤ maxSide.
    /// Returns `(base64, encodedWidth, encodedHeight)` or nil on failure.
    public func capturePngBase64(
        x: Int32 = 0, y: Int32 = 0, w: Int32 = 0, h: Int32 = 0,
        maxSide: Int32 = 0
    ) -> (b64: String, w: Int32, h: Int32)? {
        var outW: Int32 = 0
        var outH: Int32 = 0
        let s = String(engine.capturePngBase64(x, y, w, h, maxSide, &outW, &outH))
        guard !s.isEmpty else { return nil }
        // If out params were not filled (old path), fall back to request size.
        if outW < 1 { outW = w > 0 ? w : 0 }
        if outH < 1 { outH = h > 0 ? h : 0 }
        return (s, outW, outH)
    }

    // ─── App menu (Linux DBusMenu / global panel) ────────────────────────

    /// True if `com.canonical.AppMenu.Registrar` is on the session bus and
    /// canvas was built with libdbusmenu-glib.
    public static func appMenuRegistrarAvailable() -> Bool {
        canvas.Engine.appMenuRegistrarAvailable()
    }

    /// Register this window's menu with the session AppMenu registrar.
    @discardableResult
    public func appMenuAttach() -> Bool { engine.appMenuAttach() }

    public func appMenuDetach() { engine.appMenuDetach() }

    public var appMenuIsAttached: Bool { engine.appMenuIsAttached() }

    public func appMenuPoll() { engine.appMenuPoll() }

    public func appMenuBeginUpdate() { engine.appMenuBeginUpdate() }

    public func appMenuBeginMenu(id: String, title: String) {
        engine.appMenuBeginMenu(std.string(id), std.string(title))
    }

    public func appMenuEndMenu() { engine.appMenuEndMenu() }

    public func appMenuAddItem(id: String, title: String, enabled: Bool, checked: Int32) {
        engine.appMenuAddItem(std.string(id), std.string(title), enabled, Int32(checked))
    }

    public func appMenuAddSeparator() { engine.appMenuAddSeparator() }

    public func appMenuCommitUpdate() { engine.appMenuCommitUpdate() }

    /// Panel-activated MenuID raw string, or empty if the queue is empty.
    public func appMenuPopActivation() -> String {
        String(engine.appMenuPopActivation())
    }
}
#endif

/// Identifies one window of an `Editor`.
///
/// A value, not a reference: it stays valid to hold after the window closes,
/// where every call taking it becomes a no-op rather than a crash. Ids are
/// never reused, so a stale handle can never address a window that opened
/// later — which is the failure a raw index would have.
public struct WindowID: Hashable, Sendable {
    let raw: UInt32

    init(raw: UInt32) { self.raw = raw }

    /// The window an app opens with, and what every `window:` parameter
    /// defaults to.
    public static let main = WindowID(raw: 0)
}
