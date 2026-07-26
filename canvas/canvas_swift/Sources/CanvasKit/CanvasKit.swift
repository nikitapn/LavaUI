import CCanvas

/// Identifies a rectangle previously added with `CanvasEngine.addRect`, for
/// later use with `updateRect`/`removeRect`.
public struct RectID: Hashable {
    fileprivate let value: Int32
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
public final class CanvasEngine {
    private let ctx: OpaquePointer
    public let width: Int
    public let height: Int

    /// - Parameters:
    ///   - assetsRoot: Directory the engine loads assets/shaders from.
    ///   - width: Render target width, in pixels.
    ///   - height: Render target height, in pixels.
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
        canvas_remove_rect(ctx, id.value)
    }

    /// Removes every retained rectangle.
    public func clearRects() {
        canvas_clear_rects(ctx)
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
