import CCanvas

/// Drives the canvas engine headlessly and reads back rendered frames as
/// RGBA8 pixel buffers.
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

    /// Advances and renders one frame. Returns `false` if the engine hit an
    /// unrecoverable error.
    @discardableResult
    public func tick(deltaTime: Double) -> Bool {
        canvas_tick(ctx, deltaTime)
    }

    /// Returns the frame `tick(deltaTime:)` just rendered, as tightly
    /// packed RGBA8 bytes (`width * height * 4` bytes).
    public func readPixels() -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBufferPointer { ptr in
            canvas_read_pixels(ctx, ptr.baseAddress, ptr.count)
        }
        return buffer
    }
}
