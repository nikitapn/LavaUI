import Foundation

/// A size in pixels — either the picture's, or the box it is shown in.
public struct PixelSize: Equatable, Sendable {
    public var width: Float
    public var height: Float

    public init(width: Float, height: Float) {
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// What the two buttons in the control bar mean, plus the state they fall out
/// of the moment the wheel is touched.
///
/// `fit` and `actual` are *modes*, not scales: they are recomputed when the
/// window changes size, which is the whole point of Fit. `free` is a scale the
/// user chose, and a resize must leave it alone.
public enum ZoomMode: Equatable, Sendable {
    case fit
    case actual
    case free
}

/// Where the picture sits in the view box and how big it is drawn.
///
/// `offset` is the top-left corner of the drawn image in box-local
/// coordinates, so it goes negative exactly when the image is larger than the
/// box — which is also when panning is possible.
public struct Viewport: Equatable, Sendable {
    public var scale: Float
    public var offsetX: Float
    public var offsetY: Float

    public init(scale: Float = 1, offsetX: Float = 0, offsetY: Float = 0) {
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

/// Fit, actual size, cursor-anchored zoom, and the clamp that keeps the
/// picture in the window.
///
/// Pure arithmetic on purpose. Everything here is decided per frame from the
/// canvas box, the pointer, and the picture's own size — none of which needs a
/// GPU to reason about — so the behaviour that is easiest to get subtly wrong
/// is the part that can be tested without one.
public enum ViewportMath {
    /// Scale range the controls will go to. The bottom is "a wall poster on a
    /// phone screen", the top is far enough into a photograph to see the
    /// sensor's own noise.
    public static let minScale: Float = 0.02
    public static let maxScale: Float = 32

    // MARK: - Modes

    /// The largest scale at which the whole picture fits.
    ///
    /// Capped at 1: Fit shrinks, it does not enlarge. A 64×64 icon blown up to
    /// fill a 1200px window is a wall of soft squares, and it is not what
    /// anyone means by "fit to window" when they say it about an icon — they
    /// mean it about a photograph, which is always the larger of the two.
    /// Original size is one click away for the other case.
    public static func fitScale(image: PixelSize, box: PixelSize) -> Float {
        guard !image.isEmpty, !box.isEmpty else { return 1 }
        return min(1, min(box.width / image.width, box.height / image.height))
    }

    public static func scale(
        for mode: ZoomMode, image: PixelSize, box: PixelSize, free: Float
    ) -> Float {
        switch mode {
        case .fit: return fitScale(image: image, box: box)
        case .actual: return 1
        case .free: return clampScale(free)
        }
    }

    public static func clampScale(_ scale: Float) -> Float {
        guard scale.isFinite, scale > 0 else { return 1 }
        return min(maxScale, max(minScale, scale))
    }

    // MARK: - Placement

    /// A viewport at `scale` with the picture centred in the box.
    public static func centered(
        scale: Float, image: PixelSize, box: PixelSize
    ) -> Viewport {
        Viewport(
            scale: scale,
            offsetX: (box.width - image.width * scale) / 2,
            offsetY: (box.height - image.height * scale) / 2
        )
    }

    /// Pulls an offset back to something legal.
    ///
    /// Two different rules on the two sides of one comparison, and both are
    /// what people expect without being able to say so: an image *smaller*
    /// than the box is centred and cannot be dragged at all, and an image
    /// *larger* than it may be dragged but never far enough to show a gap at
    /// an edge. Per axis, because a panorama is both at once.
    public static func clamped(
        _ viewport: Viewport, image: PixelSize, box: PixelSize
    ) -> Viewport {
        var out = viewport
        out.scale = clampScale(viewport.scale)
        out.offsetX = clampAxis(
            viewport.offsetX, span: image.width * out.scale, extent: box.width
        )
        out.offsetY = clampAxis(
            viewport.offsetY, span: image.height * out.scale, extent: box.height
        )
        return out
    }

    private static func clampAxis(
        _ offset: Float, span: Float, extent: Float
    ) -> Float {
        guard offset.isFinite else { return (extent - span) / 2 }
        if span <= extent { return (extent - span) / 2 }
        return min(0, max(extent - span, offset))
    }

    // MARK: - Gestures

    /// Rescales so the picture-point under (`anchorX`, `anchorY`) stays under
    /// it.
    ///
    /// This is the whole difference between a viewer that zooms where you are
    /// looking and one that zooms into the middle and makes you drag back.
    /// The anchor is in box-local coordinates; the point of the *picture*
    /// beneath it is `(anchor - offset) / scale`, and the new offset is
    /// whatever puts that point back where it was.
    ///
    /// The clamp afterwards is what makes zooming out land gracefully: once
    /// the picture is smaller than the box the anchor stops mattering and it
    /// recentres, rather than drifting into a corner.
    public static func zoomed(
        _ viewport: Viewport,
        to newScale: Float,
        anchorX: Float,
        anchorY: Float,
        image: PixelSize,
        box: PixelSize
    ) -> Viewport {
        let target = clampScale(newScale)
        guard viewport.scale > 0, target != viewport.scale else {
            return clamped(viewport, image: image, box: box)
        }
        let ratio = target / viewport.scale
        let next = Viewport(
            scale: target,
            offsetX: anchorX - (anchorX - viewport.offsetX) * ratio,
            offsetY: anchorY - (anchorY - viewport.offsetY) * ratio
        )
        return clamped(next, image: image, box: box)
    }

    /// Zoom about the middle of the box — what the `+` / `-` keys and the
    /// control-bar buttons do, having no pointer to anchor to.
    public static func zoomedCentre(
        _ viewport: Viewport, to newScale: Float, image: PixelSize, box: PixelSize
    ) -> Viewport {
        zoomed(
            viewport, to: newScale,
            anchorX: box.width / 2, anchorY: box.height / 2,
            image: image, box: box
        )
    }

    public static func panned(
        _ viewport: Viewport, dx: Float, dy: Float,
        image: PixelSize, box: PixelSize
    ) -> Viewport {
        var next = viewport
        next.offsetX += dx
        next.offsetY += dy
        return clamped(next, image: image, box: box)
    }

    /// Whether a drag can move anything, per axis. What the pointer shape and
    /// the "drag to pan" hint are decided from.
    public static func isPannable(
        _ viewport: Viewport, image: PixelSize, box: PixelSize
    ) -> Bool {
        image.width * viewport.scale > box.width + 0.5
            || image.height * viewport.scale > box.height + 0.5
    }

    /// The source rectangle actually on screen, in picture pixels. Only used
    /// for the status readout, but it is the honest answer to "what am I
    /// looking at" when zoomed into a large photograph.
    public static func visibleSource(
        _ viewport: Viewport, image: PixelSize, box: PixelSize
    ) -> PixelSize {
        guard viewport.scale > 0 else { return image }
        return PixelSize(
            width: min(image.width, box.width / viewport.scale),
            height: min(image.height, box.height / viewport.scale)
        )
    }
}

/// The stops the `+` / `-` controls walk between.
///
/// A ladder rather than a fixed multiplier because the useful steps are not
/// evenly spaced: near 100% people want 25-point increments and a stop exactly
/// on 100, far from it they want to double. This is the sequence the old
/// Windows viewer used, which is where the muscle memory comes from.
///
/// The wheel does *not* use it — a wheel wants to be continuous, and snapping
/// each detent to a stop makes a slow scroll feel like it is sticking.
public enum ZoomLadder {
    /// Ascending, as fractions rather than percentages.
    public static let stops: [Float] = [
        0.02, 0.05, 0.07, 0.10, 0.15, 0.20, 0.25, 0.33, 0.50, 0.66,
        1.00,
        1.50, 2.00, 3.00, 4.00, 6.00, 8.00, 12.00, 16.00, 24.00, 32.00,
    ]

    /// Smallest stop strictly above `scale`, or the top when there is none.
    /// The epsilon keeps a scale that is already *on* a stop from being
    /// defeated by the float it was computed as.
    public static func next(above scale: Float) -> Float {
        let threshold = scale * 1.001
        return stops.first { $0 > threshold } ?? stops[stops.count - 1]
    }

    public static func next(below scale: Float) -> Float {
        let threshold = scale * 0.999
        return stops.last { $0 < threshold } ?? stops[0]
    }

    /// One wheel notch, as a multiplier. Geometric so that zooming in and
    /// straight back out returns to where it started, which a linear step
    /// does not.
    public static let notchFactor: Float = 1.20

    public static func wheeled(_ scale: Float, notches: Float) -> Float {
        guard notches != 0 else { return scale }
        return ViewportMath.clampScale(scale * pow(notchFactor, notches))
    }
}
