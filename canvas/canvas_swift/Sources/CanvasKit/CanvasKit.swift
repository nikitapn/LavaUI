import CCanvas

/// Identifies a shape (rect/rounded rect/circle) previously added with
/// `CanvasEngine.addRect`/`addRoundedRect`/`addCircle`, for later use with
/// `updateRect`/`removeShape`. One id space is shared across shape kinds,
/// same as the C++/C API it wraps.
public struct ShapeID: Hashable {
    fileprivate let value: Int32
}

/// Identifies a rectangle previously added with `CanvasEngine.addRect`, for
/// later use with `updateRect`/`removeShape`. An alias for `ShapeID`— kept
/// as its own name since `addRect` predates the other shape kinds and
/// existing call sites spell it this way.
public typealias RectID = ShapeID

/// Identifies a line (wire) previously added with `CanvasEngine.addLine`,
/// for later use with `removeLine`.
public struct LineID: Hashable {
    fileprivate let value: Int32
}

/// Identifies a text label previously added with `CanvasEngine.addLabel`,
/// for later use with `removeLabel`.
public struct LabelID: Hashable {
    fileprivate let value: Int32
}

/// Drives the canvas engine's retained 2D scene and reads back rendered
/// frames as RGBA8 pixel buffers.
///
/// This is retained mode, not immediate mode: shapes/lines/labels you add
/// stick around across frames until you remove them yourself. Nothing
/// renders until you call `repaint()` — there's no
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

    /// Adds a retained rounded rectangle. Same conventions as `addRect`.
    @discardableResult
    public func addRoundedRect(
        x: Double, y: Double, width: Double, height: Double,
        r: Double, g: Double, b: Double, a: Double = 1.0
    ) -> ShapeID {
        let id = canvas_add_rounded_rect(
            ctx,
            Float(x), Float(y), Float(width), Float(height),
            Float(r), Float(g), Float(b), Float(a)
        )
        return ShapeID(value: id)
    }

    /// Adds a retained circle (e.g. an FBD slot/port). Unlike the
    /// rectangle-shaped kinds, this is centered rather than top-left
    /// addressed, since that's the natural way to place a port.
    @discardableResult
    public func addCircle(
        centerX: Double, centerY: Double, radius: Double,
        r: Double, g: Double, b: Double, a: Double = 1.0
    ) -> ShapeID {
        let id = canvas_add_circle(
            ctx,
            Float(centerX), Float(centerY), Float(radius),
            Float(r), Float(g), Float(b), Float(a)
        )
        return ShapeID(value: id)
    }

    /// Removes a shape (rect/rounded rect/circle) previously returned by
    /// `addRect`/`addRoundedRect`/`addCircle`. Doesn't take effect visually
    /// until the next `repaint()`.
    public func removeShape(_ id: ShapeID) {
        canvas_remove_shape(ctx, id.value)
    }

    /// Removes every retained shape (of any kind).
    public func clearShapes() {
        canvas_clear_shapes(ctx)
    }

    /// Adds a retained line (e.g. an FBD wire), in the same screen-pixel
    /// coordinate system as shapes. Doesn't take effect visually until the
    /// next `repaint()`.
    @discardableResult
    public func addLine(
        x1: Double, y1: Double, x2: Double, y2: Double,
        r: Double, g: Double, b: Double, a: Double = 1.0
    ) -> LineID {
        let id = canvas_add_line(
            ctx,
            Float(x1), Float(y1), Float(x2), Float(y2),
            Float(r), Float(g), Float(b), Float(a)
        )
        return LineID(value: id)
    }

    /// Removes a line previously returned by `addLine`.
    public func removeLine(_ id: LineID) {
        canvas_remove_line(ctx, id.value)
    }

    /// Removes every retained line.
    public func clearLines() {
        canvas_clear_lines(ctx)
    }

    /// Adds a retained text label (e.g. a block/slot name). `r`/`g`/`b` are
    /// 0...1 — there's no alpha channel, matching TextRenderer.
    @discardableResult
    public func addLabel(
        _ text: String, x: Double, y: Double,
        r: Double, g: Double, b: Double
    ) -> LabelID {
        let id = canvas_add_label(ctx, text, Float(x), Float(y), Float(r), Float(g), Float(b))
        return LabelID(value: id)
    }

    /// Removes a label previously returned by `addLabel`.
    public func removeLabel(_ id: LabelID) {
        canvas_remove_label(ctx, id.value)
    }

    /// Removes every retained label.
    public func clearLabels() {
        canvas_clear_labels(ctx)
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
