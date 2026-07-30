#if canImport(CxxCanvas)
import Foundation

/// Absolute layout box handed to a custom paint callback (window pixels).
public struct CanvasFrame: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var w: Float
    public var h: Float

    public init(x: Float, y: Float, w: Float, h: Float) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// Custom-drawn control: Yoga sizes the box; the app emits draw commands.
///
/// Use this for product-specific widgets (meters, charts, diagram chrome) that
/// should not live in LavaUI. The paint closure runs every emit with the
/// absolute frame; call `DrawList` primitives freely. No Yoga children.
///
/// - `continuousRedraw`: register with `AnimationDriver` so the frame loop
///   keeps painting while true (e.g. a live equalizer). Flip false when idle.
public struct Canvas: PrimitiveView {
    public var label: String
    public var width: Dimension
    public var height: Dimension
    public var flexGrow: Float
    public var minWidth: Float
    public var minHeight: Float
    /// When true, this leaf asks for ~60fps redraws via `AnimationDriver`.
    public var continuousRedraw: Bool
    public var onTap: (() -> Void)?
    public var paint: (DrawList, CanvasFrame) -> Void

    public init(
        label: String = "Canvas",
        width: Dimension = .auto,
        height: Dimension = .auto,
        flexGrow: Float = 0,
        minWidth: Float = 0,
        minHeight: Float = 0,
        continuousRedraw: Bool = false,
        onTap: (() -> Void)? = nil,
        paint: @escaping (DrawList, CanvasFrame) -> Void
    ) {
        self.label = label
        self.width = width
        self.height = height
        self.flexGrow = flexGrow
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.continuousRedraw = continuousRedraw
        self.onTap = onTap
        self.paint = paint
    }

    public var dumpDetail: String {
        var bits = ["w=\(width)", "h=\(height)"]
        if flexGrow > 0 { bits.append("flexGrow=\(flexGrow)") }
        if continuousRedraw { bits.append("live") }
        return bits.joined(separator: " ")
    }

    public func mountPrimitive() -> any AnyViewNode {
        let leaf = LeafNode(
            kind: .canvas,
            label: label,
            width: width,
            height: height,
            flexGrow: flexGrow,
            minWidth: minWidth
        )
        leaf.minHeight = minHeight
        configure(leaf)
        return leaf
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let leaf = node as? LeafNode, leaf.kind == .canvas else {
            return mountPrimitive()
        }
        leaf.label = label
        leaf.width = width
        leaf.height = height
        leaf.flexGrow = flexGrow
        leaf.minWidth = minWidth
        leaf.minHeight = minHeight
        leaf.applyStyle()
        configure(leaf)
        return leaf
    }

    private func configure(_ leaf: LeafNode) {
        leaf.canvasPaint = paint
        leaf.continuousRedraw = continuousRedraw
        let tap = onTap
        leaf.onClickLocal = tap == nil
            ? nil
            : { _, _, _, _ in tap?() }
        leaf.onClick = nil
        leaf.syncContinuousRedraw()
    }
}

extension LeafNode {
    /// Register/unregister with `AnimationDriver` for canvas (and similar) leaves.
    func syncContinuousRedraw() {
        let id = self.id
        if continuousRedraw {
            AnimationDriver.register(id) { [weak self] in
                guard let self, self.continuousRedraw else { return false }
                return true
            }
            ViewInvalidation.markNeedsRedraw()
        } else {
            AnimationDriver.unregister(id)
        }
    }
}

#endif
