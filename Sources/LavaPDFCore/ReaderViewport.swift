import Foundation

/// How the column of pages sits in the window: the zoom, and how far it is
/// scrolled.
///
/// In screen pixels. `zoom` is pixels per PDF point, and the scroll is the
/// offset of the window's top-left into the zoomed column — so a scroll is a
/// number of pixels, which is what a wheel notch and a scrollbar drag both
/// speak in. Everything else about where a page lands is derived, and derived
/// here, so the app only ever hands this a box and reads positions back.
public struct ReaderViewport: Equatable, Sendable {
    public var zoom: Double
    public var scrollX: Double
    public var scrollY: Double

    /// Pixels per point at "100%": a page at its real size on a 96 dpi
    /// screen, which is what every other reader calls 100%. A point is 1/72
    /// of an inch, so this is not 1.
    public static let actualSize = 96.0 / 72.0
    public static let zoomRange = 0.1...16.0

    /// The `+` and `-` steps, as a share of `actualSize`. A browser's ladder,
    /// because that is the one everybody has in their fingers.
    public static let ladder: [Double] = [
        0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75,
        2, 2.5, 3, 4, 5, 6, 8, 10,
    ]

    public init(zoom: Double = actualSize, scrollX: Double = 0, scrollY: Double = 0) {
        self.zoom = zoom
        self.scrollX = scrollX
        self.scrollY = scrollY
    }

    /// The zoom as a reader states it: 100 is real size.
    public var percent: Int { Int((zoom / Self.actualSize * 100).rounded()) }

    // ─── Where things are ────────────────────────────────────────────────

    /// Where the column's left edge is, from the window's left. A column
    /// narrower than the window is centred and does not scroll sideways.
    public func originX(_ layout: PageLayout, boxWidth: Double) -> Double {
        let content = layout.width * zoom
        return content <= boxWidth ? ((boxWidth - content) / 2).rounded(.down) : -scrollX
    }

    public func originY(_ layout: PageLayout) -> Double { -scrollY }

    /// What part of the column is on screen, in document points.
    public func visible(_ layout: PageLayout, boxWidth: Double, boxHeight: Double) -> Box {
        Box(
            x: -originX(layout, boxWidth: boxWidth) / zoom, y: scrollY / zoom,
            width: boxWidth / zoom, height: boxHeight / zoom
        )
    }

    /// The document point under a window position, for a press or a wheel.
    public func documentPoint(
        _ layout: PageLayout, boxWidth: Double, x: Double, y: Double
    ) -> (x: Double, y: Double) {
        ((x - originX(layout, boxWidth: boxWidth)) / zoom, (y - originY(layout)) / zoom)
    }

    /// The page a reader would call "the one you are on": the one under the
    /// middle of the window, or the nearest one when the middle is in a gap.
    public func currentPage(_ layout: PageLayout, boxWidth: Double, boxHeight: Double) -> Int {
        guard !layout.frames.isEmpty else { return 0 }
        let middle = visible(layout, boxWidth: boxWidth, boxHeight: boxHeight).midY
        var best = 0
        var bestDistance = Double.infinity
        for page in layout.pages(intersecting: Box(x: 0, y: middle - 1000, width: 1, height: 2000)) {
            let frame = layout.frames[page]
            let distance = middle < frame.y ? frame.y - middle : max(0, middle - frame.maxY)
            if distance < bestDistance { best = page; bestDistance = distance }
        }
        return best
    }

    // ─── Moving ──────────────────────────────────────────────────────────

    /// The same viewport with the scroll kept inside the column.
    public func clamped(_ layout: PageLayout, boxWidth: Double, boxHeight: Double) -> ReaderViewport {
        var next = self
        next.zoom = min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let width = layout.width * next.zoom, height = layout.height * next.zoom
        next.scrollX = width <= boxWidth ? 0 : min(max(0, scrollX), width - boxWidth)
        next.scrollY = height <= boxHeight ? 0 : min(max(0, scrollY), height - boxHeight)
        return next
    }

    /// `zoom` on the tile grid's steps — the zoom a viewport may actually
    /// have, because tiles are rendered at those and drawn 1:1.
    ///
    /// Everything that solves for a scroll from a zoom has to solve with this
    /// one, not the zoom it was asked for. Rounding afterwards moves the page
    /// by `scroll × error`: nothing at the top of a document, and up to a few
    /// dozen pixels on page sixty, in a different direction every frame —
    /// which is what a fit-width resize looked like.
    public static func quantized(
        _ zoom: Double, rounding: FloatingPointRoundingRule = .toNearestOrAwayFromZero
    ) -> Double {
        let clamped = min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound)
        return TileGrid.scale(ofKey: TileGrid.scaleKey(forScale: clamped, rounding: rounding))
    }

    /// Zoomed to `zoom` with the document point under (`anchorX`, `anchorY`)
    /// staying under it — the wheel's zoom, at the pointer.
    public func zoomed(
        to zoom: Double, anchorX: Double, anchorY: Double,
        _ layout: PageLayout, boxWidth: Double, boxHeight: Double
    ) -> ReaderViewport {
        let target = Self.quantized(zoom)
        let point = documentPoint(layout, boxWidth: boxWidth, x: anchorX, y: anchorY)
        var next = ReaderViewport(zoom: target, scrollX: 0, scrollY: 0)
        // Solve for the scroll that puts `point` back at the anchor. Sideways
        // only matters once the column overflows; until then it is centred
        // and `originX` ignores the scroll.
        next.scrollX = point.x * target - anchorX
        next.scrollY = point.y * target - anchorY
        return next.clamped(layout, boxWidth: boxWidth, boxHeight: boxHeight)
    }

    /// The next step of the ladder above or below the current zoom.
    public static func stepped(_ zoom: Double, by direction: Int) -> Double {
        let rungs = ladder.map { $0 * actualSize }
        if direction > 0 {
            return rungs.first(where: { $0 > zoom * (1 + 1e-6) }) ?? rungs.last!
        }
        return rungs.last(where: { $0 < zoom * (1 - 1e-6) }) ?? rungs.first!
    }

    /// Scrolled so `page`'s top is a gap's width below the window's top.
    public func showing(
        page: Int, _ layout: PageLayout, boxWidth: Double, boxHeight: Double
    ) -> ReaderViewport {
        guard layout.frames.indices.contains(page) else { return self }
        var next = self
        next.scrollY = layout.frames[page].y * zoom - 12
        return next.clamped(layout, boxWidth: boxWidth, boxHeight: boxHeight)
    }

    /// Scrolled the least distance that brings `box` (document points) fully
    /// into view, with `margin` pixels to spare — a search match, say. Already
    /// visible, nothing moves.
    public func revealing(
        _ box: Box, margin: Double = 48, _ layout: PageLayout,
        boxWidth: Double, boxHeight: Double
    ) -> ReaderViewport {
        var next = self
        let top = box.y * zoom, bottom = box.maxY * zoom
        if top - margin < scrollY {
            next.scrollY = top - margin
        } else if bottom + margin > scrollY + boxHeight {
            next.scrollY = bottom + margin - boxHeight
        }
        if layout.width * zoom > boxWidth {
            let left = box.x * zoom, right = box.maxX * zoom
            if left - margin < scrollX {
                next.scrollX = left - margin
            } else if right + margin > scrollX + boxWidth {
                next.scrollX = right + margin - boxWidth
            }
        }
        return next.clamped(layout, boxWidth: boxWidth, boxHeight: boxHeight)
    }

    // ─── Fitting ─────────────────────────────────────────────────────────

    /// The viewport at a new fitted `zoom`, with document point `top` (in
    /// points) at the top of the window.
    ///
    /// `top` is passed rather than read from the scroll because a resize
    /// refits on every frame, and a scroll is whole pixels: deriving the
    /// anchor from the last frame's rounded scroll lets half a pixel of error
    /// a frame add up over a drag. The caller keeps one `top` for the whole
    /// of it. The zoom is rounded *down* onto the grid, so a page fitted to
    /// the width is never a fraction of a pixel wider than the window.
    public func refitted(
        to zoom: Double, keepingTop top: Double, _ layout: PageLayout,
        boxWidth: Double, boxHeight: Double
    ) -> ReaderViewport {
        let target = Self.quantized(zoom, rounding: .down)
        var next = ReaderViewport(zoom: target, scrollX: scrollX, scrollY: (top * target).rounded())
        next = next.clamped(layout, boxWidth: boxWidth, boxHeight: boxHeight)
        return next
    }

    /// The zoom at which the widest page fills the window's width.
    public static func fitWidth(_ layout: PageLayout, boxWidth: Double) -> Double {
        guard layout.width > 0, boxWidth > 0 else { return actualSize }
        return boxWidth / layout.width
    }

    /// The zoom at which every page fits whole — the tallest in height and the
    /// widest in width, margins included.
    public static func fitPage(_ layout: PageLayout, boxWidth: Double, boxHeight: Double) -> Double {
        guard let tallest = layout.frames.map(\.height).max(), tallest > 0,
              layout.width > 0, boxWidth > 0, boxHeight > 0
        else { return actualSize }
        let margin = layout.frames.first.map { $0.y } ?? 0
        return min(boxWidth / layout.width, boxHeight / (tallest + 2 * margin))
    }
}
