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

    /// Render and present one frame.
    @discardableResult
    public func renderFrame() -> Bool { engine.renderFrame() }

    // ─── Declarative UI ──────────────────────────────────────────────────

    // ─── Phase 3 draw list ───────────────────────────────────────────────

    func ensureDrawListCapacity(commands: Int, glyphs: Int, meshVertices: Int) {
        engine.ensureDrawListCapacity(commands, glyphs, meshVertices)
    }

    func drawListStorage() -> (
        commands: UnsafeMutablePointer<canvas.DrawCommand>, commandCapacity: Int,
        glyphs: UnsafeMutablePointer<canvas.GlyphInstance>, glyphCapacity: Int,
        meshVertices: UnsafeMutablePointer<canvas.MeshVertex>, meshVertexCapacity: Int
    ) {
        (
            engine.drawCommandData(), engine.drawCommandCapacity(),
            engine.drawGlyphData(), engine.drawGlyphCapacity(),
            engine.drawMeshVertexData(), engine.drawMeshVertexCapacity()
        )
    }

    public func submitDrawList(_ list: DrawList) {
        precondition(list.editor === self, "a DrawList belongs to its creating Editor")
        engine.commitDrawList(list.commandCount, list.glyphCount, list.meshVertexCount)
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
    public func pollInputEvent() -> InputEvent? {
        var ev = canvas.InputEvent()
        guard engine.pollInputEvent(&ev) else { return nil }
        let kind = InputEventKind(rawValue: ev.kind) ?? .none
        return InputEvent(kind: kind, x: ev.x, y: ev.y, button: ev.button, mods: ev.mods)
    }

    /// Paths from the most recent `.fileDrop` event. Valid only while
    /// handling that event — the next drop overwrites them.
    public func droppedFiles() -> [String] {
        let paths = engine.pendingDroppedFiles()
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
    public var isWindowVisible: Bool { engine.isWindowVisible() }

    /// Current swapchain / framebuffer size in pixels.
    public func framebufferSize() -> (w: Float, h: Float) {
        var w: Float = 0
        var h: Float = 0
        engine.framebufferSize(&w, &h)
        return (w, h)
    }

    /// Whole-window camera. Layout and Yoga stay at zoom=1; the quad shader
    /// applies center-zoom then pan. Hit-tests must unproject first.
    public func setViewTransform(zoom: Float, panX: Float = 0, panY: Float = 0) {
        engine.setViewTransform(zoom, panX, panY)
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
