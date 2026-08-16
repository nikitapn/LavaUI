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

    /// Backing store for `resources` (see `ResourceHost.swift`). Nil means
    /// "this editor names its own resources", which is every app with a
    /// window; a client under a shared renderer points it at the compositor.
    var remoteResources: (any GPUResourceHost)?

    /// Per-window frame destinations. See `frames(for:)`.
    private var frameSinks: [WindowID: any FrameSink] = [:]

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

    /// Opens an engine that lays out and emits frames for another process to
    /// draw: no Vulkan, no window, no GPU.
    ///
    /// Everything above this — `LavaWindow`, the view tree, layout, emit —
    /// is unchanged and unaware. That is the point: a client is not a second
    /// frame loop, it is the same one with the parts that need a screen
    /// answering honestly that they have none. `renderFrame` succeeds and
    /// draws nowhere, `capturePngBase64` returns nil, `loadImage` returns nil
    /// (see below), and the rest behaves exactly as it does in a window.
    ///
    /// Two things a client cannot answer for itself and must be told:
    ///
    /// - **Size.** There is no surface to measure, so `setClientSize` is the
    ///   only way it learns one, and the initial `width`/`height` here are a
    ///   guess until something says otherwise.
    /// - **Input.** The `inject*` entry points are the whole input path, not
    ///   a test affordance layered over a real one — which is what lets the
    ///   agent server drive a client with no compositor on the other end.
    ///
    /// Known gaps, both by design and both scoped as later work: images fail
    /// to load (a texture id is per-process and there is no `RegisterFont`
    /// equivalent for images yet), and `registerFont` hands out ids from a
    /// local table that means nothing to a renderer elsewhere.
    public static func openClient(width: Float = 1280, height: Float = 800) -> Editor? {
        let editor = Editor()
        guard editor.engine.openClient(UInt32(width), UInt32(height)).has_value()
        else { return nil }
        return editor
    }

    /// Tells a client window how big it is, queueing the `.resize` its tree
    /// needs to re-lay-out. No-op on a window that has a renderer, which
    /// measures its own surface instead.
    public func setClientSize(width: Float, height: Float, window: WindowID = .main) {
        engine.setClientSize(width, height, window.raw)
    }

    /// Constrains interactive resizing of a local window. Zero means no
    /// minimum on that axis. Client surfaces use their compositor host.
    public func setMinimumSize(
        width: Float, height: Float, window: WindowID = .main
    ) {
        engine.setMinimumSize(max(0, width), max(0, height), window.raw)
    }

    /// The pointer image over this window.
    ///
    /// Windowed only: a client has no pointer to set, and asks the compositor
    /// instead (`CursorBridge`). No-op there rather than an error, so the same
    /// call site works in both modes.
    public func setCursor(_ shape: CursorShape, window: WindowID = .main) {
        engine.setCursorShape(shape.rawValue, window.raw)
    }

    /// Queues an event that arrived already formed — from a renderer in
    /// another process — rather than one derived from a device here.
    ///
    /// The only way some events can reach a client at all: `.resize`,
    /// `.nodeHover`, `.nodeScroll` and `.nodeAnimationDone` are answers a
    /// renderer produces by looking at its own retained scene, and a client
    /// has no scene and no device to synthesize them from. A `.resize` is
    /// also state, not just an event, and updates what `framebufferSize`
    /// reports from here on.
    ///
    /// Thread-safe, like every input entry point — the queue is the one thing
    /// in a window that has always been touched from more than one thread.
    /// Callers still have to `wakeEventLoop()` if the loop may be parked.
    public func postInputEvent(_ event: InputEvent, window: WindowID = .main) {
        engine.postInputEvent(
            event.kind.rawValue, event.x, event.y, event.button, event.mods,
            window.raw
        )
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

    /// Renders several windows at once, one thread per window.
    ///
    /// A frame is mostly the window's own — its command pool, its fences, its
    /// buffers — but not entirely: picking up a resize, growing the shared
    /// glyph atlas and freeing images no window references any more all reach
    /// across every window at once. Those run here, before and after the
    /// group, because none of them is safe while a window is recording.
    ///
    /// Rendering one window at a time needs none of this — `renderFrame`
    /// brackets itself.
    public func renderFrames(_ windows: [WindowID]) {
        guard !windows.isEmpty else { return }
        engine.beginFrameGroup()
        // Runs work on this thread too, so a single dirty window costs no hop.
        DispatchQueue.concurrentPerform(iterations: windows.count) { index in
            engine.renderFrame(windows[index].raw)
        }
        engine.endFrameGroup()
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
        gradients: Int, window: WindowID = .main
    ) {
        engine.ensureDrawListCapacity(
            commands, glyphs, meshVertices, spatialVertices, gradients, window.raw
        )
    }

    func drawListStorage(window: WindowID = .main) -> (
        commands: UnsafeMutablePointer<canvas.DrawCommand>, commandCapacity: Int,
        glyphs: UnsafeMutablePointer<canvas.GlyphInstance>, glyphCapacity: Int,
        meshVertices: UnsafeMutablePointer<canvas.MeshVertex>, meshVertexCapacity: Int,
        spatialVertices: UnsafeMutablePointer<canvas.SpatialVertex>, spatialVertexCapacity: Int,
        gradients: UnsafeMutablePointer<canvas.GradientDesc>, gradientCapacity: Int
    ) {
        (
            engine.drawCommandData(window.raw), engine.drawCommandCapacity(window.raw),
            engine.drawGlyphData(window.raw), engine.drawGlyphCapacity(window.raw),
            engine.drawMeshVertexData(window.raw), engine.drawMeshVertexCapacity(window.raw),
            engine.drawSpatialVertexData(window.raw),
            engine.drawSpatialVertexCapacity(window.raw),
            engine.drawGradientData(window.raw), engine.drawGradientCapacity(window.raw)
        )
    }

    public func submitDrawList(_ list: DrawList) {
        precondition(list.editor === self, "a DrawList belongs to its creating Editor")
        list.publish()
    }

    /// Hands a finished frame to the engine's own renderer. The in-process
    /// half of `FrameSink`; a client's frames go to an arena instead.
    func commitFrame(_ written: FrameCapacity, window: WindowID = .main) {
        engine.commitDrawList(
            written.commands, written.glyphs, written.meshVertices,
            written.spatialVertices, written.gradients, window.raw
        )
    }

    /// Where this window's frames are written and who receives them.
    ///
    /// The engine's own buffers unless `publishFrames(to:window:)` said
    /// otherwise, which is what keeps a windowed app unaware that a `DrawList`
    /// has a destination at all. Created lazily and kept, because a sink holds
    /// the buffers between frames.
    func frames(for window: WindowID) -> any FrameSink {
        if let existing = frameSinks[window] { return existing }
        let sink = EngineFrameSink(editor: self, window: window)
        frameSinks[window] = sink
        return sink
    }

    /// Sends this window's frames somewhere other than the engine — a shared
    /// arena another process renders from.
    ///
    /// Takes effect for `DrawList`s built after it, so a client installs the
    /// sink before `LavaApp.run` rather than during. A list already holding
    /// the old sink keeps writing to it, which is the safe way round: the
    /// alternative is swapping the storage out from under a frame that is
    /// halfway emitted.
    public func publishFrames(to sink: any FrameSink, window: WindowID = .main) {
        frameSinks[window] = sink
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

    public func registerFont(
        path: String, pixelSize26_6: UInt32, faceIndex: UInt32,
        rasterFlags: UInt32
    ) -> UInt32? {
        let id = engine.registerFace(
            std.string(path), pixelSize26_6, faceIndex, rasterFlags
        )
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
        return (Self.copyOut(decoded), decoded.width, decoded.height)
    }

    /// The same decode from encoded bytes already in memory, for an image that
    /// never had a path — downloaded, generated, unpacked from an archive.
    ///
    /// `bytes` are the *encoded* file (PNG, JPEG, …), not raw pixels: the
    /// format is sniffed the way it is for a file.
    public nonisolated static func decodeImageData(
        bytes: [UInt8],
        maxPixelSize: UInt32 = 0
    ) -> (pixels: [UInt8], width: UInt32, height: UInt32)? {
        let decoded = bytes.withUnsafeBufferPointer { buf -> canvas.DecodedImage in
            guard let base = buf.baseAddress else { return canvas.DecodedImage() }
            return canvas.Engine.decodeImageData(base, buf.count, maxPixelSize)
        }
        guard decoded.valid() else { return nil }
        return (Self.copyOut(decoded), decoded.width, decoded.height)
    }

    /// Lifts a decoded buffer into a Swift array in one copy.
    ///
    /// Subscripting the C++ vector per element is the obvious spelling and the
    /// wrong one: each `pixels[i]` is its own unspecialized call across the
    /// interop boundary, so cost scales with *bytes*, not images. A 300×297
    /// RGBA image is 356,400 of them, which measured at 2.7 s against a 2 ms
    /// decode — enough to put the compositor's `RegisterImage` past its RPC
    /// timeout and make every client fail to start.
    private nonisolated static func copyOut(
        _ decoded: canvas.DecodedImage
    ) -> [UInt8] {
        let n = Int(decoded.pixels.size())
        guard n > 0 else { return [] }
        return [UInt8](unsafeUninitializedCapacity: n) { buf, written in
            written = decoded.copyTo(buf.baseAddress, n)
        }
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
        // A client has no device. Encode and register with the compositor
        // — Flameshot's tray icon is only an IconPixmap, and the local
        // upload used to return nil, so the panel drew the letter F.
        if let remote = remoteResources {
            guard let png = Self.encodePng(
                pixels: pixels, width: width, height: height, maxSide: 64
            ), !png.isEmpty else { return nil }
            return remote.registerImage(data: png, maxPixelSize: 64)
        }
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

    /// RGBA8 → PNG. `maxSide` 0 is native.
    public nonisolated static func encodePng(
        pixels: [UInt8], width: UInt32, height: UInt32, maxSide: UInt32 = 0
    ) -> [UInt8]? {
        let encoded = pixels.withUnsafeBufferPointer { buf -> canvas.DecodedImage in
            guard let base = buf.baseAddress else { return canvas.DecodedImage() }
            return canvas.Engine.encodeRgbaPng(base, width, height, maxSide)
        }
        let n = encoded.pixels.size()
        guard n > 0 else { return nil }
        return [UInt8](unsafeUninitializedCapacity: Int(n)) { buf, written in
            written = encoded.copyTo(buf.baseAddress, n)
        }
    }

    /// Whether the engine already has this key resident.
    public func hasImage(key: String) -> Bool {
        engine.hasTexture(std.string(key))
    }

    /// Drops one reference to a loaded image.
    ///
    /// The GPU memory is not normally freed here. At zero references the image
    /// goes dormant, keeping its pixels and its id so reloading the same key
    /// costs nothing. Eviction from there is LRU, and never touches an image a
    /// window's current frame still names. Standalone images are evicted
    /// against a byte budget (`LAVA_IMAGE_CACHE_MB`, 256 by default); atlased
    /// ones against atlas occupancy, since a cell is far too small to move a
    /// byte budget but the cells themselves run out. Allocated atlas pages
    /// stay resident either way.
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
    /// `maxSide` > 0 downsamples so the longer encoded side ≤ maxSide.
    /// Returns `(base64, encodedWidth, encodedHeight)` or nil on failure.
    public func capturePngBase64(
        x: Int32 = 0, y: Int32 = 0, w: Int32 = 0, h: Int32 = 0,
        maxSide: Int32 = 0, window: WindowID = .main
    ) -> (b64: String, w: Int32, h: Int32)? {
        var outW: Int32 = 0
        var outH: Int32 = 0
        let s = String(
            engine.capturePngBase64(x, y, w, h, maxSide, &outW, &outH, window.raw)
        )
        guard !s.isEmpty else { return nil }
        // If out params were not filled (old path), fall back to request size.
        if outW < 1 { outW = w > 0 ? w : 0 }
        if outH < 1 { outH = h > 0 ? h : 0 }
        return (s, outW, outH)
    }

    /// The same capture as PNG bytes.
    ///
    /// For a caller that is not about to put it in JSON — the compositor
    /// answering `CaptureSurface` for a client, where base64 would be a third
    /// more bytes on the wire and a decode at the other end, to satisfy a
    /// protocol the renderer is not speaking.
    public func capturePng(
        x: Int32 = 0, y: Int32 = 0, w: Int32 = 0, h: Int32 = 0,
        maxSide: Int32 = 0, window: WindowID = .main
    ) -> (png: [UInt8], w: Int32, h: Int32)? {
        var outW: Int32 = 0
        var outH: Int32 = 0
        let bytes = engine.capturePng(x, y, w, h, maxSide, &outW, &outH, window.raw)
        let n = Int(bytes.size())
        guard n > 0 else { return nil }
        var png = [UInt8]()
        png.reserveCapacity(n)
        for i in 0..<n { png.append(bytes[i]) }
        if outW < 1 { outW = w > 0 ? w : 0 }
        if outH < 1 { outH = h > 0 ? h : 0 }
        return (png, outW, outH)
    }

    // ─── App menu (Linux DBusMenu / global panel) ────────────────────────

    /// True if a menu registrar — `org.lavaui.AppMenu.Registrar` or the
    /// canonical `com.canonical.AppMenu.Registrar` — is on the session bus and
    /// canvas was built with libdbusmenu-glib.
    public static func appMenuRegistrarAvailable() -> Bool {
        canvas.Engine.appMenuRegistrarAvailable()
    }

    /// Register this window's menu with the session AppMenu registrar.
    @discardableResult
    public func appMenuAttach() -> Bool { engine.appMenuAttach() }

    /// The same, under an id this process supplies rather than an X11 window
    /// id — which is what a compositor client has instead: its surface id, the
    /// number the panel hears about when the window takes focus.
    @discardableResult
    public func appMenuAttach(windowId: UInt32) -> Bool {
        engine.appMenuAttachWindow(windowId)
    }

    // ─── Menu import (panel side) ────────────────────────────────────────

    /// Own a registrar name and start importing menus. False without a bus.
    @discardableResult
    public func menuImportStart() -> Bool { engine.menuImportStart() }

    /// Which registrar name this panel owns, or empty.
    public var menuImportBusName: String { String(engine.menuImportBusName()) }

    /// Whose menu to import. 0 shows none.
    ///
    /// `menuService` / `menuObjectPath` come from the focused window's KDE
    /// Wayland AppMenu address when the compositor has one; empty falls back
    /// to the AppMenu registrar under `windowId` (Lava clients).
    public func menuImportSetActiveWindow(
        _ windowId: UInt32,
        menuService: String = "",
        menuObjectPath: String = ""
    ) {
        engine.menuImportSetActiveWindow(
            windowId, std.string(menuService), std.string(menuObjectPath)
        )
    }

    public func menuImportPoll() { engine.menuImportPoll() }

    /// Changes whenever the imported menu does.
    public var menuImportRevision: UInt64 { engine.menuImportRevision() }

    public var menuImportItemCount: Int { Int(engine.menuImportItemCount()) }

    public func menuImportItem(_ index: Int) -> ImportedMenuItem {
        ImportedMenuItem(
            id: engine.menuImportItemId(index),
            parent: engine.menuImportItemParent(index),
            label: String(engine.menuImportItemLabel(index)),
            isEnabled: engine.menuImportItemEnabled(index),
            isSeparator: engine.menuImportItemSeparator(index),
            hasSubmenu: engine.menuImportItemHasSubmenu(index),
            checked: Int(engine.menuImportItemChecked(index))
        )
    }

    public func menuImportActivate(_ itemId: Int32) {
        engine.menuImportActivate(itemId)
    }

    public func menuImportAboutToShow(_ itemId: Int32) {
        engine.menuImportAboutToShow(itemId)
    }

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

    // ─── Status Notifier (system tray) ───────────────────────────────────

    /// Own `org.kde.StatusNotifierWatcher`. False if the name is taken or
    /// there is no session bus.
    @discardableResult
    public func statusNotifierStart() -> Bool { engine.statusNotifierStart() }

    public var statusNotifierIsServing: Bool { engine.statusNotifierIsServing() }

    public func statusNotifierPoll() { engine.statusNotifierPoll() }

    public var statusNotifierRevision: UInt64 { engine.statusNotifierRevision() }

    public var statusNotifierItemCount: Int { Int(engine.statusNotifierItemCount()) }

    public func statusNotifierItem(_ index: Int) -> StatusNotifierItemInfo {
        let i = index
        return StatusNotifierItemInfo(
            key: String(engine.statusNotifierItemKey(i)),
            id: String(engine.statusNotifierItemId(i)),
            title: String(engine.statusNotifierItemTitle(i)),
            status: String(engine.statusNotifierItemStatus(i)),
            iconName: String(engine.statusNotifierItemIconName(i)),
            iconPath: String(engine.statusNotifierItemIconPath(i)),
            isMenu: engine.statusNotifierItemIsMenu(i),
            hasMenu: engine.statusNotifierItemHasMenu(i),
            prefersMenu: engine.statusNotifierItemPrefersMenu(i),
            iconWidth: Int(engine.statusNotifierItemIconWidth(i)),
            iconHeight: Int(engine.statusNotifierItemIconHeight(i)),
            iconRgba: copyStatusNotifierIconRgba(index: i)
        )
    }

    public func statusNotifierActivate(_ key: String, x: Int32 = 0, y: Int32 = 0) {
        engine.statusNotifierActivate(std.string(key), x, y)
    }

    public func statusNotifierContextMenu(_ key: String, x: Int32 = 0, y: Int32 = 0) {
        engine.statusNotifierContextMenu(std.string(key), x, y)
    }

    public func statusNotifierSecondaryActivate(
        _ key: String, x: Int32 = 0, y: Int32 = 0
    ) {
        engine.statusNotifierSecondaryActivate(std.string(key), x, y)
    }

    public func statusNotifierScroll(
        _ key: String, delta: Int32, orientation: String = "vertical"
    ) {
        engine.statusNotifierScroll(std.string(key), delta, std.string(orientation))
    }

    // ─── Notifications ───────────────────────────────────────────────────

    public func notificationsStart() -> Bool { engine.notificationsStart() }

    public var notificationsIsServing: Bool { engine.notificationsIsServing() }

    public func notificationsPoll() { engine.notificationsPoll() }

    public var notificationsRevision: UInt64 { engine.notificationsRevision() }

    public var notificationsCount: Int { Int(engine.notificationsCount()) }

    public func notification(_ index: Int) -> NotificationInfo {
        NotificationInfo(
            id: engine.notificationId(index),
            appName: String(engine.notificationAppName(index)),
            summary: String(engine.notificationSummary(index)),
            body: String(engine.notificationBody(index)),
            iconPath: String(engine.notificationIconPath(index)),
            iconWidth: Int(engine.notificationIconWidth(index)),
            iconHeight: Int(engine.notificationIconHeight(index)),
            iconRgba: copyNotificationIconRgba(index: index),
            urgency: engine.notificationUrgency(index),
            remainingMs: engine.notificationRemainingMs(index),
            actionCount: Int(engine.notificationActionCount(index))
        )
    }

    public func notificationActionKey(_ index: Int, action: Int) -> String {
        String(engine.notificationActionKey(index, action))
    }

    public func notificationActionLabel(_ index: Int, action: Int) -> String {
        String(engine.notificationActionLabel(index, action))
    }

    public func notificationInvokeAction(_ id: UInt32, key: String) {
        engine.notificationInvokeAction(id, std.string(key))
    }

    public func notificationDismiss(_ id: UInt32) {
        engine.notificationDismiss(id)
    }

    public func notificationDismissAll() { engine.notificationDismissAll() }

    public func notificationsSetPaused(_ paused: Bool) {
        engine.notificationsSetPaused(paused)
    }

    private func copyNotificationIconRgba(index: Int) -> [UInt8] {
        let n = engine.notificationIconRgbaSize(index)
        guard n > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: Int(n))
        let written = out.withUnsafeMutableBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return Int(engine.notificationIconRgbaCopy(index, base, n))
        }
        if written < out.count { out.removeLast(out.count - written) }
        return out
    }

    /// Opens `key`'s DBusMenu. False when the item exports none — activate it
    /// instead.
    public func statusNotifierOpenMenu(_ key: String) -> Bool {
        engine.statusNotifierOpenMenu(std.string(key))
    }

    public func statusNotifierCloseMenu() { engine.statusNotifierCloseMenu() }

    public var statusNotifierMenuRevision: UInt64 {
        engine.statusNotifierMenuRevision()
    }

    public var statusNotifierMenuItemCount: Int {
        Int(engine.statusNotifierMenuItemCount())
    }

    public func statusNotifierMenuItem(_ index: Int) -> ImportedMenuItem {
        ImportedMenuItem(
            id: engine.statusNotifierMenuItemId(index),
            parent: engine.statusNotifierMenuItemParent(index),
            label: String(engine.statusNotifierMenuItemLabel(index)),
            isEnabled: engine.statusNotifierMenuItemEnabled(index),
            isSeparator: engine.statusNotifierMenuItemSeparator(index),
            hasSubmenu: engine.statusNotifierMenuItemHasSubmenu(index),
            checked: Int(engine.statusNotifierMenuItemChecked(index))
        )
    }

    public func statusNotifierMenuActivate(_ itemId: Int32) {
        engine.statusNotifierMenuActivate(itemId)
    }

    public func statusNotifierMenuAboutToShow(_ itemId: Int32) {
        engine.statusNotifierMenuAboutToShow(itemId)
    }

    private func copyStatusNotifierIconRgba(index: Int) -> [UInt8] {
        let n = engine.statusNotifierItemIconRgbaSize(index)
        guard n > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: n)
        bytes.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            _ = engine.statusNotifierItemIconRgbaCopy(index, base, n)
        }
        return bytes
    }
}

/// One StatusNotifierItem as the panel sees it after a poll.
public struct StatusNotifierItemInfo: Equatable, Sendable {
    /// `uniqueName/objectPath` — stable activate key.
    public var key: String
    public var id: String
    public var title: String
    public var status: String
    public var iconName: String
    /// Resolved filesystem path for `iconName`, when found.
    public var iconPath: String
    public var isMenu: Bool
    /// The item exports a DBusMenu.
    public var hasMenu: Bool
    /// A left click has nowhere to go but that menu — the item said
    /// `ItemIsMenu`, or never implemented `Activate`.
    public var prefersMenu: Bool
    public var iconWidth: Int
    public var iconHeight: Int
    /// RGBA8 pixels when the item published `IconPixmap`.
    public var iconRgba: [UInt8]
}

/// One live desktop notification, as the server holds it.
public struct NotificationInfo: Equatable, Sendable {
    /// The protocol's id, which is what actions and closing speak in.
    public var id: UInt32
    public var appName: String
    public var summary: String
    public var body: String
    /// Resolved file for `app_icon` or the `image-path` hint.
    public var iconPath: String
    /// Pixels from the `image-data` hint, RGBA8, when the sender sent its own.
    public var iconWidth: Int
    public var iconHeight: Int
    public var iconRgba: [UInt8]
    /// 0 low, 1 normal, 2 critical.
    public var urgency: UInt8
    /// Milliseconds left, or 0 when it waits for the user instead.
    public var remainingMs: Int64
    public var actionCount: Int
}

/// One row of a menu imported from another application.
///
/// Flat, and named by DBusMenu's own ids, because that is the shape it crosses
/// the interop boundary in — `parent` is another row's `id`, or -1 at the top
/// level. `PanelMenu` is what turns a run of these into a tree.
public struct ImportedMenuItem: Equatable, Sendable {
    public var id: Int32
    public var parent: Int32
    public var label: String
    public var isEnabled: Bool
    public var isSeparator: Bool
    /// Opens a submenu. Its children may not have been fetched yet — the
    /// application is entitled to fill them only when asked.
    public var hasSubmenu: Bool
    /// -1 not checkable, 0 unchecked, 1 checked.
    public var checked: Int
}

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
