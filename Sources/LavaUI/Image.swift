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

/// Path → `UIImage` cache (UI thread).
public enum ImageStore {
    nonisolated(unsafe) private static var cache: [String: UIImage] = [:]

    /// Load (or return cached) image through the engine.
    @discardableResult
    public static func load(path: String, into editor: Editor) -> UIImage? {
        if let hit = cache[path] { return hit }
        guard let img = editor.loadImage(path: path) else { return nil }
        cache[path] = img
        return img
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

    public static func clearCache() { cache.removeAll(keepingCapacity: true) }
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
