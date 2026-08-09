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

/// A phase in a `Canvas` pointer gesture — a press, its drag, and its release.
public enum CanvasGesturePhase: Sendable, Equatable {
    /// The hit test that starts the gesture and captures the pointer.
    case began
    /// Delivered on every move after `.began`, even once the pointer has
    /// left the canvas's own bounds — the same capture lifecycle
    /// `Slider`/`TextField` get from `PointerCapture`, just surfaced.
    case moved
    /// Button released. Always paired with a `.began`.
    case ended
}

/// One pointer event delivered to a `Canvas`'s `onGesture`.
public struct CanvasGesture: Sendable, Equatable {
    public var phase: CanvasGesturePhase
    /// Relative to the canvas's own top-left, matching `CanvasFrame`. Can go
    /// negative, or past `w`/`h`, once a drag leaves the box.
    public var localX: Float
    public var localY: Float
    public var windowX: Float
    public var windowY: Float
    /// Current absolute canvas geometry, identical to the frame passed to
    /// `paint`. This makes local coordinates reversible without app-owned
    /// frame caches (for example, committing a drag range to chart values).
    public var frame: CanvasFrame
    /// Modifiers held at `.began` (see `KeyMods`). Not re-read for
    /// `.moved`/`.ended` — a drag can't ask again mid-flight, only a fresh
    /// press reflects current state, so this stays whatever `.began` saw.
    public var mods: Int32
}

/// Custom-drawn control: Yoga sizes the box; the app emits draw commands.
///
/// Use this for product-specific widgets (meters, charts, diagram chrome) that
/// should not live in LavaUI. The paint closure runs every emit with the
/// absolute frame; call `DrawList` primitives freely. No Yoga children.
///
/// - `continuousRedraw`: register with `AnimationDriver` so the frame loop
///   keeps painting while true (e.g. a live equalizer). Flip false when idle.
/// - `onGesture`: down/move/up with local + window coordinates, for a
///   synchronized inspection cursor, drag-to-zoom, or range selection.
///   Store paint-only interaction values in `@DrawState`; ordinary `@State`
///   intentionally recomputes the owning body on every change.
/// - `onWheel`: deltas plus the pointer's position local to this canvas, for
///   zooming around the cursor rather than the center.
/// - `onHover`: enter/leave, for a canvas whose paint changes under the
///   pointer. A hover fill would come free from a `.hoverBackground()`; this
///   is for the ones that draw the difference themselves, and it is also what
///   makes the canvas resolvable as a hover target at all.
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
    public var onGesture: ((CanvasGesture) -> Void)?
    public var onWheel: ((_ dx: Float, _ dy: Float, _ localX: Float, _ localY: Float) -> Void)?
    public var onHover: ((Bool) -> Void)?
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
        onGesture: ((CanvasGesture) -> Void)? = nil,
        onWheel: ((_ dx: Float, _ dy: Float, _ localX: Float, _ localY: Float) -> Void)? = nil,
        onHover: ((Bool) -> Void)? = nil,
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
        self.onGesture = onGesture
        self.onWheel = onWheel
        self.onHover = onHover
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
        let gesture = onGesture
        leaf.onClickLocal = (tap == nil && gesture == nil)
            ? nil
            : { [weak leaf] localX, localY, originX, originY, mods in
                tap?()
                guard let gesture else { return }
                guard let leaf else { return }
                // Reused by `.ended` below: `PointerCapture`'s `onUp` carries
                // no position of its own, and re-deriving it from `originX`/Y
                // plus whatever the *last* `.moved` reported is simpler and
                // more obviously correct than reaching for a separate global.
                var lastWindow = (x: originX + localX, y: originY + localY)
                let beganFrame = leaf.lastCanvasFrame
                gesture(CanvasGesture(
                    phase: .began, localX: localX, localY: localY,
                    windowX: lastWindow.x, windowY: lastWindow.y,
                    frame: beganFrame, mods: mods
                ))
                PointerCapture.capture(
                    leaf.id,
                    onMove: { windowX, windowY in
                        lastWindow = (windowX, windowY)
                        let frame = leaf.lastCanvasFrame
                        gesture(CanvasGesture(
                            phase: .moved,
                            localX: windowX - frame.x, localY: windowY - frame.y,
                            windowX: windowX, windowY: windowY,
                            frame: frame, mods: mods
                        ))
                    },
                    onUp: {
                        let frame = leaf.lastCanvasFrame
                        gesture(CanvasGesture(
                            phase: .ended,
                            localX: lastWindow.x - frame.x,
                            localY: lastWindow.y - frame.y,
                            windowX: lastWindow.x, windowY: lastWindow.y,
                            frame: frame, mods: mods
                        ))
                    }
                )
            }
        leaf.onClick = nil

        // Set before the wheel's placeholder below, so a canvas with both keeps
        // the real handler. `HoverState` is what calls it — the renderer owns
        // the pointer and answers hover, and a client has no other way to hear
        // about it at all.
        if let hover = onHover {
            leaf.onHover = hover
            HoverState.register(leaf.id) { [weak leaf] inside in
                leaf?.onHover?(inside)
            }
        } else {
            HoverState.unregister(leaf.id)
        }

        if let wheel = onWheel {
            // Keeps the canvas resolvable as the hover target despite having
            // no hover fill of its own — an empty handler is that signal (see
            // `hoverWalk`). Wheel routing no longer depends on this, since
            // `hitTestScrollChain` collects boxes rather than hover targets,
            // but hover and capture still do.
            if leaf.onHover == nil { leaf.onHover = { _ in } }
            ScrollRouter.register(leaf.id) { [weak leaf] dx, dy in
                guard let leaf else { return }
                let p = PointerState.window
                wheel(dx, dy, p.x - leaf.lastCanvasFrame.x, p.y - leaf.lastCanvasFrame.y)
            }
        } else {
            ScrollRouter.unregister(leaf.id)
        }

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
