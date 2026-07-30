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
/// Two things `Engine`'s C++ API asks of callers that don't fit Swift
/// directly, both worked around here rather than in `Engine` itself:
///  - `std::vector<T>` can't be constructed from Swift source in this
///    toolchain (a ClangImporter limitation around `<vector>`'s `bool`
///    specialization — see canvas_engine.hpp's clear/add/commit builders).
///    `setProjectTree`/`setProperties` use those incremental builders here.
///  - `std::expected<void, Error>` (`VoidResult`)'s `.error()` accessor
///    returns a reference, which Swift's interop won't call (possible
///    dangling pointer) — so failures are surfaced as `nil`/`false` here,
///    not with the underlying message. Check stderr (Engine logs failures
///    internally) if you need to know why something failed to open.
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

    public func submitDrawList(_ list: DrawList) {
        list.commands.withUnsafeBufferPointer { cmdBuf in
            list.glyphs.withUnsafeBufferPointer { glyphBuf in
                engine.submitDrawList(
                    cmdBuf.baseAddress,
                    cmdBuf.count,
                    glyphBuf.baseAddress,
                    glyphBuf.count
                )
            }
        }
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

    /// Raw input: mouse, resize, key (see `InputEventKind`).
    public func pollInputEvent() -> InputEvent? {
        var ev = canvas.InputEvent()
        guard engine.pollInputEvent(&ev) else { return nil }
        let kind = InputEventKind(rawValue: ev.kind) ?? .none
        return InputEvent(kind: kind, x: ev.x, y: ev.y, button: ev.button)
    }

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
    public func capturePngBase64(x: Int32 = 0, y: Int32 = 0, w: Int32 = 0, h: Int32 = 0) -> String? {
        let s = String(engine.capturePngBase64(x, y, w, h))
        return s.isEmpty ? nil : s
    }
}
#endif
