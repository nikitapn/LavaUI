#if canImport(CxxCanvas)
import Foundation

/// Who names the things that live on a GPU.
///
/// A `GlyphInstance` carries a font id and an image command carries a texture
/// id, and both are only meaningful to the process that owns the atlas they
/// index. In a normal app that process is this one, so the ids come from the
/// `Editor` and nobody has to think about it. Under a shared renderer they
/// come from the compositor, and a locally-invented number would draw the
/// wrong face or the wrong picture — silently, because a stale id is still a
/// valid index.
///
/// So this is the seam between the two modes, and it is deliberately the
/// *whole* seam: a client differs from a windowed app in who answers these
/// five questions and in nothing else. Shaping, measurement, layout and emit
/// are unchanged, because none of them ever needed a device — only naming
/// does.
///
/// Note what is *not* here: pixels. A remote host is asked to register a file
/// it can open itself, never handed a decoded bitmap, which is the same rule
/// the control plane follows for draw lists. Whoever owns the GPU does the
/// decode, because they are about to own the result.
public protocol GPUResourceHost: AnyObject, Sendable {
    /// Registers a face and returns the id to stamp into `GlyphInstance`.
    /// Idempotent per `(path, pixelSize)`; nil if the file will not load.
    func registerFont(path: String, pixelSize: Float) -> UInt32?

    /// Registers an image, decoded from `path` and capped to `maxPixelSize`
    /// (0 = native), returning a handle with the id and the decoded size.
    ///
    /// Blocks. For anything an app needs before its first frame — an icon, a
    /// brand mark — where a placeholder would be worse than a stall.
    func registerImage(path: String, maxPixelSize: UInt32) -> UIImage?

    /// The same registration off the calling thread, with `completion` run on
    /// the main queue.
    ///
    /// A protocol requirement rather than a helper because the two hosts split
    /// the work differently and only they know where. Locally, the decode
    /// belongs on a worker and the upload must be back on the main thread —
    /// it touches the device. Remotely the whole thing is one call, and there
    /// is no main-thread half at all.
    func registerImageAsync(
        path: String, maxPixelSize: UInt32,
        completion: @escaping @Sendable (UIImage?) -> Void
    )

    /// Drops one reference to a registered image. `key` is the `cacheKey`
    /// from the handle, not the bare path — the same file at two decode sizes
    /// is two textures.
    func releaseImage(key: String)
}

extension GPUResourceHost {
    /// Off-thread registration for a host that has no main-thread half — a
    /// remote one, where the call is already a round trip and touches nothing
    /// local. `Editor` overrides this, because it does.
    public func registerImageAsync(
        path: String, maxPixelSize: UInt32,
        completion: @escaping @Sendable (UIImage?) -> Void
    ) {
        Thread.detachNewThread {
            let image = self.registerImage(path: path, maxPixelSize: maxPixelSize)
            MainQueue.async { completion(image) }
        }
    }
}

// ─── Built-in renderer ───────────────────────────────────────────────────────

extension Editor: GPUResourceHost {
    public func registerImage(path: String, maxPixelSize: UInt32) -> UIImage? {
        // Native size has a shorter path: the engine opens, decodes and
        // uploads in one call, and the cache key is the bare path.
        if maxPixelSize == 0 { return loadImage(path: path) }
        guard let decoded = Editor.decodeImage(path: path, maxPixelSize: maxPixelSize)
        else { return nil }
        return uploadImage(
            key: ImageStore.key(path: path, maxPixelSize: maxPixelSize),
            path: path,
            pixels: decoded.pixels, width: decoded.width, height: decoded.height
        )
    }

    /// Decode on a worker, upload on the main thread.
    ///
    /// The split is not an optimization, it is a requirement in both
    /// directions: decoding a JPEG is tens of milliseconds and would stall the
    /// frame, and uploading touches the Vulkan device, which is the main
    /// thread's alone.
    public func registerImageAsync(
        path: String, maxPixelSize: UInt32,
        completion: @escaping @Sendable (UIImage?) -> Void
    ) {
        Thread.detachNewThread {
            let decoded = Editor.decodeImage(path: path, maxPixelSize: maxPixelSize)
            MainQueue.async {
                guard let decoded else {
                    completion(nil)
                    return
                }
                completion(self.uploadImage(
                    key: ImageStore.key(path: path, maxPixelSize: maxPixelSize),
                    path: path,
                    pixels: decoded.pixels,
                    width: decoded.width, height: decoded.height
                ))
            }
        }
    }

    public func releaseImage(key: String) { unloadImage(path: key) }

    /// Who names GPU resources for the frames this editor produces.
    ///
    /// Itself, unless told otherwise — which is what makes an ordinary app
    /// unaware that this question exists. A client under a shared renderer
    /// assigns the compositor here, once, at startup:
    ///
    /// ```swift
    /// guard let editor = LavaApp.openClient() else { exit(1) }
    /// editor.resources = compositor      // ids now come from the renderer
    /// ```
    ///
    /// Set before loading anything. Ids already stamped into a `UIFont` or a
    /// `UIImage` are not revisited, so a switch after the fact leaves the
    /// resources loaded before it naming things in the wrong process.
    public var resources: any GPUResourceHost {
        get { remoteResources ?? self }
        set { remoteResources = newValue === self ? nil : newValue }
    }
}
#endif
