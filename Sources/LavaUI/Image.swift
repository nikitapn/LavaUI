import Foundation

#if canImport(CxxCanvas)

// MARK: - Image resource

/// GPU texture handle for LavaUI `Image` views.
///
/// Load via `Editor.loadImage(path:)` (or `ImageStore`). Identity is the
/// absolute path; the engine texture id is stable for the process lifetime of
/// that path (TextureManager refcounts).
public final class UIImage: @unchecked Sendable {
    public let path: String
    public let textureId: UInt32
    public let pixelWidth: Float
    public let pixelHeight: Float

    public init(path: String, textureId: UInt32, pixelWidth: Float, pixelHeight: Float) {
        self.path = path
        self.textureId = textureId
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
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
        guard let entry = cache[image.path] else { return }
        useCounter &+= 1
        entry.lastUsedFrame = frame
        entry.lastUsedOrder = useCounter
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
        guard let img = editor.loadImage(path: path) else { return nil }
        insert(img, into: editor)
        return img
    }

    /// Cached image, or nil while it loads.
    ///
    /// Returns nil the first time and decodes on a worker; when the pixels
    /// arrive they are uploaded on the main thread and the view is marked
    /// dirty, so the next frame gets the image. Callers draw a placeholder for
    /// the nil case — which they need anyway, because a real client is waiting
    /// on the network too.
    @discardableResult
    public static func imageIfLoaded(path: String, into editor: Editor) -> UIImage? {
        if let hit = cache[path] {
            touch(hit.image)
            return hit.image
        }
        guard !inFlight.contains(path) else { return nil }
        inFlight.insert(path)

        Thread.detachNewThread {
            let decoded = Editor.decodeImage(path: path)
            MainQueue.async {
                inFlight.remove(path)
                guard let decoded else { return }
                guard let img = editor.uploadImage(
                    key: path, pixels: decoded.pixels,
                    width: decoded.width, height: decoded.height
                ) else { return }
                insert(img, into: editor)
                // Nothing observed this: the cache is a plain store, so the
                // frame that shows the image has to be asked for.
                ViewInvalidation.markNeedsBody()
            }
        }
        return nil
    }

    private static func insert(_ image: UIImage, into editor: Editor) {
        let bytes = Int(image.pixelWidth) * Int(image.pixelHeight) * 4
        useCounter &+= 1
        cache[image.path] = Entry(
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
            editor.unloadImage(path: entry.image.path)
            cache.removeValue(forKey: entry.image.path)
            residentBytes -= entry.bytes
        }
    }

    /// Resolve a file under `assetsRoot` (checks `assets/` then root).
    public static func loadAsset(
        named name: String,
        assetsRoot: String,
        into editor: Editor
    ) -> UIImage? {
        let root = assetsRoot as NSString
        let candidates = [
            root.appendingPathComponent("assets").appendingPathComponent(name),
            root.appendingPathComponent(name),
        ]
        for p in candidates {
            if FileManager.default.fileExists(atPath: p) {
                return load(path: p, into: editor)
            }
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
    public var image: UIImage
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

    public var dumpDetail: String {
        let name = (image.path as NSString).lastPathComponent
        return "\"\(name)\" \(Int(image.pixelWidth))×\(Int(image.pixelHeight))"
    }

    public func mountPrimitive() -> any AnyViewNode {
        let leaf = LeafNode(
            kind: .image,
            label: "Image \(dumpDetail)",
            width: resolvedWidth,
            height: resolvedHeight
        )
        leaf.image = image
        leaf.imageTint = tint
        leaf.imageContentMode = contentMode
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
            leaf.image = image
            leaf.imageTint = tint
            leaf.imageContentMode = contentMode
            return leaf
        }
        return mountPrimitive()
    }

    /// Auto → intrinsic pixel size so Yoga has a definite box.
    private var resolvedWidth: Dimension {
        if case .auto = width { return .point(image.pixelWidth) }
        return width
    }

    private var resolvedHeight: Dimension {
        if case .auto = height { return .point(image.pixelHeight) }
        return height
    }
}

#endif
