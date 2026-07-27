import CCanvas
import Foundation

/// Identifies a rectangle previously added with `CanvasEngine.addRect`, for
/// later use with `updateRect`/`removeRect`.
public struct RectID: Hashable, Sendable {
    fileprivate let value: Int32
}

/// Identifies a text widget previously added with `CanvasEngine.addTextWidget`.
public struct TextWidgetID: Hashable, Sendable {
    fileprivate let value: Int32
}

/// One syntax-highlight rule for a text widget. Patterns use ECMAScript
/// regular expressions (as compiled by `std::regex` on the C++ side).
public struct HighlightRule: Sendable {
    public var pattern: String
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double
    /// Higher priority wins when matches overlap.
    public var priority: Int
    /// `0` colors the whole match; `>0` colors only that capture group.
    public var captureGroup: Int

    public init(
        pattern: String,
        r: Double, g: Double, b: Double, a: Double = 1.0,
        priority: Int = 0,
        captureGroup: Int = 0
    ) {
        self.pattern = pattern
        self.r = r
        self.g = g
        self.b = b
        self.a = a
        self.priority = priority
        self.captureGroup = captureGroup
    }
}

/// Sample IEC 61131-3 Structured Text-ish rules — optional convenience, not
/// baked into the engine.
public enum HighlightPresets {
    public static let structuredText: [HighlightRule] = [
        HighlightRule(pattern: #"//[^\n]*"#, r: 0.40, g: 0.70, b: 0.40, priority: 10),
        HighlightRule(
            pattern: #"\b(IF|THEN|ELSE|END_IF|AND|OR|NOT|TRUE|FALSE|VAR|END_VAR)\b"#,
            r: 0.75, g: 0.55, b: 1.0, priority: 5
        ),
        HighlightRule(pattern: #"\b\d+(\.\d+)?\b"#, r: 0.90, g: 0.70, b: 0.30, priority: 3),
        HighlightRule(pattern: #"'([^']|'')*'"#, r: 0.50, g: 0.80, b: 0.50, priority: 4),
    ]
}

/// GLFW-style key codes matching `canvas/src/util/key_codes.hpp` (and common
/// extras used by the text widget).
public enum CanvasKey {
    public static let space = 32
    public static let a = 65
    public static let z = 90
    public static let escape = 256
    public static let enter = 257
    public static let tab = 258
    public static let backspace = 259
    public static let insert = 260
    public static let delete = 261
    public static let right = 262
    public static let left = 263
    public static let down = 264
    public static let up = 265
    public static let pageUp = 266
    public static let pageDown = 267
    public static let home = 268
    public static let end = 269
    public static let leftShift = 340
    public static let leftControl = 341
    public static let leftAlt = 342

    public static let actionRelease = 0
    public static let actionPress = 1
    public static let actionRepeat = 2

    public static let modShift = 1
    public static let modControl = 2
    public static let modAlt = 4
}

/// Drives the canvas engine's retained 2D scene and reads back rendered
/// frames as RGBA8 pixel buffers.
///
/// This is retained mode, not immediate mode: shapes you add with
/// `addRect` stick around across frames until you `updateRect`/`removeRect`
/// them yourself. Nothing renders until you call `repaint()` — there's no
/// background loop driving frames, so call it whenever you've changed the
/// scene and want a new frame to read back.
///
/// Wraps the plain C API in `canvas_c_api.h` (an opaque `CanvasContext*` +
/// free functions) rather than importing the underlying C++ engine directly
/// — see the note in canvas_swift's Package.swift for why: Swift's C++
/// interop mode is viral (any importer of an interop-built module must
/// enable it too), which conflicts with also needing swift-cross-ui's
/// GtkCHelpers (a plain C module that isn't C++-clean) in the same target.
public final class CanvasEngine: @unchecked Sendable {
    private let ctx: OpaquePointer
    public let width: Int
    public let height: Int

    /// - Parameters:
    ///   - assetsRoot: Directory the engine loads assets/shaders from.
    ///   - width: Render target width, in pixels.
    ///   - height: Render target height, in pixels.
    /// Offscreen mode: frames via `readPixels()` (legacy Image embed / tests).
    public init?(assetsRoot: String, width: Int, height: Int) {
        guard
            let created = canvas_create(assetsRoot, UInt32(width), UInt32(height))
        else {
            return nil
        }
        ctx = created
        self.width = width
        self.height = height
    }

    /// Opens a **GLFW + Vulkan present window** on a background thread in the
    /// same process (no IPC). Input is handled by GLFW; call scene APIs on
    /// this engine as usual. Use this for the interactive canvas next to
    /// SwiftCrossUI chrome.
    public static func openWindow(
        assetsRoot: String,
        width: Int,
        height: Int,
        title: String = "Canvas"
    ) -> CanvasEngine? {
        let created = title.withCString { cTitle in
            canvas_create_window(assetsRoot, UInt32(width), UInt32(height), cTitle)
        }
        guard let created else { return nil }
        return CanvasEngine(existing: created, width: width, height: height)
    }

    private init(existing: OpaquePointer, width: Int, height: Int) {
        ctx = existing
        self.width = width
        self.height = height
    }

    /// Whether the GLFW canvas window is still open (windowed mode only).
    public var isWindowOpen: Bool {
        canvas_window_is_open(ctx)
    }

    /// Move/resize the GLFW window to a screen-space rectangle (pixels).
    /// Call from the UI when a layout slot's global frame changes so the
    /// canvas tracks the SwiftCrossUI placeholder.
    public func setWindowFrame(x: Int, y: Int, width: Int, height: Int) {
        canvas_window_set_frame(ctx, Int32(x), Int32(y), Int32(width), Int32(height))
    }

    /// Hide while the host window is moved/resized/minimized; show when settled.
    public func setWindowVisible(_ visible: Bool) {
        canvas_window_set_visible(ctx, visible)
    }

    public var isWindowVisible: Bool {
        canvas_window_is_visible(ctx)
    }

    deinit {
        canvas_destroy(ctx)
    }

    /// Renders the current retained scene. Returns `false` if the engine
    /// hit an unrecoverable error.
    @discardableResult
    public func repaint() -> Bool {
        canvas_repaint(ctx)
    }

    /// Adds a retained rectangle. `x`/`y` is the top-left corner, in
    /// pixels; `r`/`g`/`b`/`a` are 0...1. Returns an id you can later pass
    /// to `updateRect`/`removeRect`. Doesn't take effect visually until the
    /// next `repaint()`.
    @discardableResult
    public func addRect(
        x: Double, y: Double, width: Double, height: Double,
        r: Double, g: Double, b: Double, a: Double = 1.0
    ) -> RectID {
        let id = canvas_add_rect(
            ctx,
            Float(x), Float(y), Float(width), Float(height),
            Float(r), Float(g), Float(b), Float(a)
        )
        return RectID(value: id)
    }

    /// Replaces a rectangle previously returned by `addRect`. Doesn't take
    /// effect visually until the next `repaint()`.
    public func updateRect(
        _ id: RectID,
        x: Double, y: Double, width: Double, height: Double,
        r: Double, g: Double, b: Double, a: Double = 1.0
    ) {
        canvas_update_rect(
            ctx, id.value,
            Float(x), Float(y), Float(width), Float(height),
            Float(r), Float(g), Float(b), Float(a)
        )
    }

    /// Removes a rectangle previously returned by `addRect`. Doesn't take
    /// effect visually until the next `repaint()`.
    public func removeRect(_ id: RectID) {
        canvas_remove_shape(ctx, id.value)
    }

    /// Removes every retained rectangle/shape.
    public func clearRects() {
        canvas_clear_shapes(ctx)
    }

    /// Alias used by diagram rendering (`FBDRenderer`).
    public func clearShapes() {
        canvas_clear_shapes(ctx)
    }

    @discardableResult
    public func addRoundedRect(
        x: Double, y: Double, width: Double, height: Double,
        r: Double, g: Double, b: Double, a: Double = 1.0
    ) -> RectID {
        let id = canvas_add_rounded_rect(
            ctx,
            Float(x), Float(y), Float(width), Float(height),
            Float(r), Float(g), Float(b), Float(a)
        )
        return RectID(value: id)
    }

    @discardableResult
    public func addCircle(
        centerX: Double, centerY: Double, radius: Double,
        r: Double, g: Double, b: Double, a: Double = 1.0
    ) -> RectID {
        let id = canvas_add_circle(
            ctx,
            Float(centerX), Float(centerY), Float(radius),
            Float(r), Float(g), Float(b), Float(a)
        )
        return RectID(value: id)
    }

    @discardableResult
    public func addLine(
        x1: Double, y1: Double, x2: Double, y2: Double,
        r: Double, g: Double, b: Double, a: Double = 1.0
    ) -> RectID {
        let id = canvas_add_line(
            ctx,
            Float(x1), Float(y1), Float(x2), Float(y2),
            Float(r), Float(g), Float(b), Float(a)
        )
        return RectID(value: id)
    }

    public func clearLines() {
        canvas_clear_lines(ctx)
    }

    @discardableResult
    public func addLabel(
        _ text: String,
        x: Double, y: Double,
        r: Double, g: Double, b: Double
    ) -> RectID {
        let id = text.withCString { cText in
            canvas_add_label(ctx, cText, Float(x), Float(y), Float(r), Float(g), Float(b))
        }
        return RectID(value: id)
    }

    public func clearLabels() {
        canvas_clear_labels(ctx)
    }

    // MARK: - Text widgets

    /// Places an editable text field in canvas space. With `multiline`,
    /// Enter inserts a newline; otherwise it is ignored by the field.
    @discardableResult
    public func addTextWidget(
        x: Double, y: Double, width: Double, height: Double,
        text: String = "",
        multiline: Bool = true
    ) -> TextWidgetID {
        let id = text.withCString { cText in
            canvas_add_text_widget(
                ctx,
                Float(x), Float(y), Float(width), Float(height),
                cText, multiline
            )
        }
        return TextWidgetID(value: id)
    }

    public func setTextWidgetRect(
        _ id: TextWidgetID,
        x: Double, y: Double, width: Double, height: Double
    ) {
        canvas_set_text_widget_rect(
            ctx, id.value,
            Float(x), Float(y), Float(width), Float(height)
        )
    }

    public func setTextWidgetText(_ id: TextWidgetID, _ text: String) {
        text.withCString { canvas_set_text_widget_text(ctx, id.value, $0) }
    }

    public func textWidgetText(_ id: TextWidgetID) -> String {
        let len = canvas_get_text_widget_text(ctx, id.value, nil, 0)
        guard len > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: Int(len) + 1)
        _ = canvas_get_text_widget_text(ctx, id.value, &buffer, buffer.count)
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Installs regex highlight rules. Returns `false` if the id is invalid
    /// or any pattern failed to compile (valid ones are still applied).
    @discardableResult
    public func setTextWidgetHighlightRules(
        _ id: TextWidgetID,
        _ rules: [HighlightRule]
    ) -> Bool {
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }

        var cRules: [CanvasHighlightRule] = []
        cRules.reserveCapacity(rules.count)
        for rule in rules {
            guard let patternPtr = strdup(rule.pattern) else { continue }
            owned.append(patternPtr)
            cRules.append(
                CanvasHighlightRule(
                    pattern: patternPtr,
                    r: Float(rule.r),
                    g: Float(rule.g),
                    b: Float(rule.b),
                    a: Float(rule.a),
                    priority: Int32(rule.priority),
                    capture_group: Int32(rule.captureGroup)
                )
            )
        }
        return cRules.withUnsafeBufferPointer { buf in
            canvas_set_text_widget_highlight_rules(
                ctx, id.value, buf.baseAddress, Int32(buf.count)
            )
        }
    }

    public func setTextWidgetFocused(_ id: TextWidgetID, _ focused: Bool) {
        canvas_set_text_widget_focused(ctx, id.value, focused)
    }

    public func isTextWidgetFocused(_ id: TextWidgetID) -> Bool {
        canvas_is_text_widget_focused(ctx, id.value)
    }

    /// `true` if the buffer changed since the previous call for this id.
    public func textWidgetChanged(_ id: TextWidgetID) -> Bool {
        canvas_text_widget_changed(ctx, id.value)
    }

    public func removeTextWidget(_ id: TextWidgetID) {
        canvas_remove_text_widget(ctx, id.value)
    }

    /// `true` when the host should run a continuous ~60 Hz repaint/readback
    /// loop (e.g. a text widget is focused and needs caret blink). When
    /// `false`, repaint only after scene or input changes.
    public func wantsAnimation() -> Bool {
        canvas_wants_animation(ctx)
    }

    // MARK: - Input

    public func pointerMove(x: Double, y: Double) {
        canvas_pointer_move(ctx, Float(x), Float(y))
    }

    public func pointerButton(button: Int, pressed: Bool, x: Double, y: Double) {
        canvas_pointer_button(ctx, Int32(button), pressed, Float(x), Float(y))
    }

    public func keyEvent(key: Int, action: Int, mods: Int = 0) {
        canvas_key_event(ctx, Int32(key), Int32(action), Int32(mods))
    }

    public func textInput(_ utf8: String) {
        utf8.withCString { canvas_text_input(ctx, $0) }
    }

    /// Returns the frame `repaint()` just rendered, as tightly packed
    /// RGBA8 bytes (`width * height * 4` bytes).
    public func readPixels() -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBufferPointer { ptr in
            canvas_read_pixels(ctx, ptr.baseAddress, ptr.count)
        }
        return buffer
    }
}
