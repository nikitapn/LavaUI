import Foundation

// MARK: - Image resource

/// GPU texture handle for LavaUI `Image` views.
///
/// Load via `Editor.loadImage(path:)` (or `ImageStore`). Identity is the
/// absolute path; the engine texture id is stable for the process lifetime of
/// that path (TextureManager refcounts).
public final class UIImage: @unchecked Sendable {
    /// File this was decoded from.
    public let path: String
    /// Cache and engine-texture identity: `path` plus the decode size.
    ///
    /// Not the same thing as `path`, because the same file decoded for a 48pt
    /// avatar and for a 200pt hero are two different textures and must not
    /// evict or alias each other.
    public let cacheKey: String
    public let textureId: UInt32
    public let pixelWidth: Float
    public let pixelHeight: Float
    /// Compositor surface this poster should sample, or 0 for a normal
    /// TextureManager id in `textureId`. A GPU-less client cannot import
    /// a dma-buf; it names the surface and the compositor resolves it.
    public let surfaceId: UInt32
    /// Longest dest edge for a `surfaceId` poster; 0 is native.
    public let surfaceMaxSide: UInt32

    public init(
        path: String,
        cacheKey: String? = nil,
        textureId: UInt32,
        pixelWidth: Float,
        pixelHeight: Float,
        surfaceId: UInt32 = 0,
        surfaceMaxSide: UInt32 = 0
    ) {
        self.path = path
        self.cacheKey = cacheKey ?? path
        self.textureId = textureId
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.surfaceId = surfaceId
        self.surfaceMaxSide = surfaceMaxSide
    }

    /// A window poster resolved by the compositor when this image is drawn.
    public static func surfacePoster(
        surfaceId: UInt32,
        pixelWidth: Float,
        pixelHeight: Float,
        maxSide: UInt32
    ) -> UIImage {
        UIImage(
            path: "surface:\(surfaceId)",
            cacheKey: "surface:\(surfaceId):\(maxSide)",
            textureId: 0,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            surfaceId: surfaceId,
            surfaceMaxSide: maxSide
        )
    }

    public var size: (w: Float, h: Float) { (pixelWidth, pixelHeight) }
}

/// Path → `UIImage` cache with a VRAM budget, async decode, and LRU eviction.
///
/// UI thread only, except for the decode itself.
///
/// **Why the budget evicts and visibility does not.** The obvious policy —
/// drop a poster once it scrolls off — thrashes: reverse direction and every
/// image you just discarded has to be fetched and decoded again. Visibility
/// belongs in *priority*; a byte budget belongs in *lifetime*. An entry is
/// only evicted when the cache is over budget, and never on the frame it was
/// drawn, so a grid larger than the budget degrades to re-decoding rather than
/// flickering mid-frame.
public enum ImageStore {
    private final class Entry {
        let image: UIImage
        /// Bytes this occupies on the GPU. Atlased images still cost their
        /// pixels; the page is shared but the cell is not.
        let bytes: Int
        var lastUsedFrame: UInt64
        var lastUsedOrder: UInt64

        init(image: UIImage, bytes: Int, frame: UInt64, order: UInt64) {
            self.image = image
            self.bytes = bytes
            self.lastUsedFrame = frame
            self.lastUsedOrder = order
        }
    }

    nonisolated(unsafe) private static var cache: [String: Entry] = [:]
    nonisolated(unsafe) private static var inFlight: Set<String> = []
    nonisolated(unsafe) private static var residentBytes = 0
    nonisolated(unsafe) private static var frame: UInt64 = 0
    nonisolated(unsafe) private static var useCounter: UInt64 = 0

    /// Bytes of decoded image the cache will hold before evicting. Generous by
    /// default: a screenful of covers is a few MB, and evicting sooner than
    /// necessary just means decoding again.
    nonisolated(unsafe) public static var budgetBytes = 256 * 1024 * 1024

    /// Called by `LavaApp.run` once a frame has been emitted.
    ///
    /// Evicting *after* emit rather than before is what makes "not drawn this
    /// frame" mean anything: at the start of a frame nothing has been drawn
    /// yet, so every entry would look idle and the cache would throw away the
    /// images it is about to paint. Running it here also means a cache that is
    /// over budget with nothing new arriving still drains — eviction on insert
    /// alone stops the moment loading does, and leaves the cache permanently
    /// over its limit.
    public static func endFrame(into editor: Editor) {
        evictIfOverBudget(into: editor)
        frame &+= 1
    }

    /// Marks an image as used. Called from the draw list on every emit, which
    /// is what makes "least recently used" mean "least recently *drawn*"
    /// rather than least recently asked for.
    public static func touch(_ image: UIImage) {
        guard let entry = cache[image.cacheKey] else { return }
        useCounter &+= 1
        entry.lastUsedFrame = frame
        entry.lastUsedOrder = useCounter
    }

    /// Cache identity for a file decoded at a given cap. `0` is the native
    /// decode and keys on the bare path, so existing callers keep their key.
    ///
    /// Public because a `GPUResourceHost` outside this module has to stamp
    /// the same key into the `UIImage` it returns — this cache looks entries
    /// up by it, so a host that spelled it differently would register an
    /// image and then miss it on every subsequent frame.
    public static func key(path: String, maxPixelSize: UInt32) -> String {
        maxPixelSize == 0 ? path : "\(path)@\(maxPixelSize)"
    }

    /// Cache identity for bytes with no path: a hash of the content, so the
    /// same image registered twice is one texture and the caller invents no
    /// name.
    ///
    /// Public for the same reason as `key`, and for one more: the compositor
    /// derives this key independently, from the bytes it received, and a
    /// client that spelled it differently would be talking about a different
    /// texture. One implementation, both sides.
    ///
    /// FNV-1a with the length mixed in. A collision means two unrelated images
    /// share a texture, which is worth caring about — and takes roughly 2³²
    /// distinct images in one session to become likely, which is why 64 bits
    /// is enough here and would not be for an untrusted store.
    public static func contentKey(data: [UInt8], maxPixelSize: UInt32) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return "mem:\(String(hash, radix: 16))-\(data.count)-\(maxPixelSize)"
    }

    /// Cached image, loaded synchronously. Kept for assets an app needs before
    /// its first frame — an icon, a brand mark — where a placeholder would be
    /// worse than a stall.
    @discardableResult
    public static func load(path: String, into editor: Editor) -> UIImage? {
        if let hit = cache[path] {
            touch(hit.image)
            return hit.image
        }
        guard let img = editor.resources.registerImage(path: path, maxPixelSize: 0)
        else { return nil }
        PerfCounters.imageDecodes &+= 1
        insert(img, into: editor)
        return img
    }

    /// Cached image, or nil while it loads.
    ///
    /// Returns nil the first time and decodes on a worker; when the pixels
    /// arrive they are uploaded on the main thread and a redraw is requested,
    /// so the next frame gets the image. Callers draw a placeholder for the nil
    /// case — which they need anyway, because a real client is waiting on the
    /// network too.
    ///
    /// `maxPixelSize` caps the longer edge at decode time (0 = native). Pass
    /// the size it will be drawn at. Two reasons, and the second is the one
    /// that bites: the pixels you don't decode cost nothing to hold, *and*
    /// `ImageAtlas` refuses anything wider than one cell, so an oversized
    /// decode silently costs a whole texture binding per image.
    @discardableResult
    public static func imageIfLoaded(
        path: String,
        maxPixelSize: UInt32 = 0,
        into editor: Editor
    ) -> UIImage? {
        let cacheKey = key(path: path, maxPixelSize: maxPixelSize)
        if let hit = cache[cacheKey] {
            touch(hit.image)
            return hit.image
        }
        guard !inFlight.contains(cacheKey) else { return nil }
        inFlight.insert(cacheKey)

        // Where the work happens is the host's business, not this cache's: a
        // local one decodes on a worker and uploads on the main thread, a
        // remote one does the whole thing in the renderer. Either way the
        // completion lands on the main queue, which is the only part the
        // bookkeeping below depends on.
        editor.resources.registerImageAsync(
            path: path, maxPixelSize: maxPixelSize
        ) { image in
            inFlight.remove(cacheKey)
            guard let img = image else { return }
            PerfCounters.imageDecodes &+= 1
            insert(img, into: editor)
            // `.redraw`, not `.body`. Nothing observed this — the cache is
            // a plain store — so the frame has to be asked for explicitly.
            // But asking for `body` rebuilds the whole view tree (~46ms on
            // a large grid, and with a menubar there is no per-node path),
            // once per arriving image, to change one leaf's texture. The
            // image leaf resolves its own texture at emit, so re-emitting
            // is all that is actually required.
            //
            // A caller whose view *structure* depends on the image being
            // ready still needs `.body` — that is why `Image(path:)`
            // exists, so it doesn't.
            ViewInvalidation.markNeedsRedraw()
        }
        return nil
    }

    private static func insert(_ image: UIImage, into editor: Editor) {
        let bytes = Int(image.pixelWidth) * Int(image.pixelHeight) * 4
        useCounter &+= 1
        cache[image.cacheKey] = Entry(
            image: image, bytes: bytes, frame: frame, order: useCounter
        )
        residentBytes += bytes
        evictIfOverBudget(into: editor)
    }

    /// Drops least-recently-drawn entries until under budget.
    ///
    /// Skips anything touched this frame: a grid that does not fit would
    /// otherwise evict images it is in the middle of drawing, and the result
    /// is a frame with holes in it rather than a slightly stale cache.
    private static func evictIfOverBudget(into editor: Editor) {
        guard residentBytes > budgetBytes else { return }
        let candidates = cache.values
            .filter { $0.lastUsedFrame != frame }
            .sorted { $0.lastUsedOrder < $1.lastUsedOrder }
        for entry in candidates {
            guard residentBytes > budgetBytes else { break }
            editor.resources.releaseImage(key: entry.image.cacheKey)
            cache.removeValue(forKey: entry.image.cacheKey)
            residentBytes -= entry.bytes
            PerfCounters.imageEvictions &+= 1
        }
    }

    /// Resolve a file under `assetsRoot` (`fonts/` / `assets/` / root).
    public static func loadAsset(
        named name: String,
        assetsRoot: String,
        into editor: Editor
    ) -> UIImage? {
        let root = assetsRoot as NSString
        let candidates = [
            root.appendingPathComponent(name),
            root.appendingPathComponent("assets").appendingPathComponent(name),
            root.appendingPathComponent("images").appendingPathComponent(name),
            root.appendingPathComponent("assets").appendingPathComponent("images").appendingPathComponent(name),
        ]
        for p in candidates {
            if FileManager.default.fileExists(atPath: p) {
                return load(path: p, into: editor)
            }
        }
        return nil
    }

    /// Load a resource from a SwiftPM / app `Bundle` (prefer the app's
    /// `Bundle.module` for brand art — not the engine or LavaUI bundles).
    public static func loadAsset(
        named name: String,
        bundle: Bundle,
        into editor: Editor
    ) -> UIImage? {
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        if !ext.isEmpty,
           let url = bundle.url(forResource: base, withExtension: ext)
        {
            return load(path: url.path, into: editor)
        }
        // Nested or process() layouts: search the resource directory tree.
        if let root = bundle.resourcePath {
            return loadAsset(named: name, assetsRoot: root, into: editor)
        }
        return nil
    }

    /// Bytes currently held, for tests and diagnostics.
    public static var residentByteCount: Int { residentBytes }
    public static var count: Int { cache.count }

    public static func clearCache() {
        cache.removeAll(keepingCapacity: true)
        residentBytes = 0
    }
}

// MARK: - Content mode

/// How the source bitmap maps into the layout box.
public enum ImageContentMode: Equatable, Sendable {
    /// Stretch to fill the layout box (default).
    case stretch
    /// Preserve aspect, letterbox inside the box.
    case fit
    /// Preserve aspect, crop to fill the box.
    case fill
}

// MARK: - View

/// Raster image laid out as a Yoga leaf and drawn as a textured quad.
///
/// ```swift
/// Image(logo, width: .pt(64), height: .pt(64))
/// Image(icon)  // intrinsic pixel size
/// ```
public struct Image: PrimitiveView {
    public var image: UIImage?
    /// Set instead of `image` by the path initialiser — see its doc comment.
    public var path: String?
    public var placeholder: Color?
    public var placeholderCornerRadius: Float = 0
    public var width: Dimension
    public var height: Dimension
    /// Multiplied with sample RGBA (white = no tint).
    public var tint: Color
    public var contentMode: ImageContentMode
    public var onClick: (() -> Void)?

    public init(
        _ image: UIImage,
        width: Dimension = .auto,
        height: Dimension = .auto,
        tint: Color = Color(r: 1, g: 1, b: 1),
        contentMode: ImageContentMode = .stretch,
        onClick: (() -> Void)? = nil
    ) {
        self.image = image
        self.width = width
        self.height = height
        self.tint = tint
        self.contentMode = contentMode
        self.onClick = onClick
    }

    /// An image identified by file path, loaded on demand and drawn when ready.
    ///
    /// Prefer this to branching on `ImageStore.imageIfLoaded` in a body. Writing
    /// it as `if let img = …imageIfLoaded(…) { Image(img) } else { placeholder }`
    /// makes the *shape of the view tree* depend on whether a decode has
    /// finished, so every arriving image has to invalidate `body` and rebuild
    /// the tree. Here the leaf is the same leaf either way; it resolves its own
    /// texture at emit, and an arriving image costs one redraw.
    ///
    /// `width`/`height` must be definite for the decode cap to be derived from
    /// them — with `.auto` there is no box to size against yet, and the file
    /// decodes at native resolution. Pass `decodePixels` to override.
    public init(
        path: String,
        width: Dimension,
        height: Dimension,
        placeholder: Color? = nil,
        placeholderCornerRadius: Float = 0,
        decodePixels: UInt32? = nil,
        tint: Color = Color(r: 1, g: 1, b: 1),
        contentMode: ImageContentMode = .stretch,
        onClick: (() -> Void)? = nil
    ) {
        self.image = nil
        self.path = path
        self.placeholder = placeholder
        self.placeholderCornerRadius = placeholderCornerRadius
        self.width = width
        self.height = height
        self.tint = tint
        self.contentMode = contentMode
        self.onClick = onClick
        self.explicitDecodePixels = decodePixels
    }

    private var explicitDecodePixels: UInt32?

    /// Longer edge to decode at: the box in physical pixels, so a HiDPI or
    /// zoomed UI still gets the resolution it draws at rather than a soft
    /// upscale of a smaller decode.
    var decodePixels: UInt32 {
        if let explicitDecodePixels { return explicitDecodePixels }
        guard case .point(let w) = width, case .point(let h) = height else { return 0 }
        let longEdge = max(w, h) * FontStore.scale.multiplier
        guard longEdge >= 1 else { return 0 }
        return UInt32(longEdge.rounded(.up))
    }

    public var dumpDetail: String {
        if let image {
            let name = (image.path as NSString).lastPathComponent
            return "\"\(name)\" \(Int(image.pixelWidth))×\(Int(image.pixelHeight))"
        }
        let name = ((path ?? "") as NSString).lastPathComponent
        return "\"\(name)\" →\(decodePixels)px"
    }

    public func mountPrimitive() -> any AnyViewNode {
        let leaf = LeafNode(
            kind: .image,
            label: "Image \(dumpDetail)",
            width: resolvedWidth,
            height: resolvedHeight
        )
        apply(to: leaf)
        leaf.onClick = onClick
        leaf.color = tint
        return leaf
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        if let leaf = node as? LeafNode, leaf.kind == .image {
            leaf.update(
                label: "Image \(dumpDetail)",
                width: resolvedWidth,
                height: resolvedHeight,
                color: tint,
                onClick: onClick
            )
            apply(to: leaf)
            return leaf
        }
        return mountPrimitive()
    }

    private func apply(to leaf: LeafNode) {
        leaf.image = image
        leaf.imagePath = path
        leaf.imageDecodePixels = path == nil ? 0 : decodePixels
        leaf.imagePlaceholder = placeholder
        leaf.imagePlaceholderRadius = placeholderCornerRadius
        leaf.imageTint = tint
        leaf.imageContentMode = contentMode
    }

    /// Auto → intrinsic pixel size so Yoga has a definite box. A path-backed
    /// image has no intrinsic size to fall back on until it decodes, so `.auto`
    /// there collapses to zero — which is why the path initialiser demands
    /// definite dimensions.
    private var resolvedWidth: Dimension {
        if case .auto = width, let image { return .point(image.pixelWidth) }
        return width
    }

    private var resolvedHeight: Dimension {
        if case .auto = height, let image { return .point(image.pixelHeight) }
        return height
    }
}
