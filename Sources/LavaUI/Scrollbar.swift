import Foundation

/// Geometry for a scroll indicator, shared by the two things that have one.
///
/// `ScrollView` scrolls by moving a renderer-owned transform, and `EditorView`
/// scrolls by moving its own offset and re-emitting. They have nothing else in
/// common — but a scrollbar is a scrollbar, and a user who learns that the
/// thumb is grabbable in one of them is entitled to find it grabbable in the
/// other, in the same place, the same width, with the same feel. Two copies of
/// this arithmetic is how that stops being true.
enum Scrollbar {
    /// What is painted. Thin on purpose: this is an indicator that happens to
    /// be draggable, not a widget competing with the content.
    static let thickness: Float = 4
    /// What is grabbable. A four-pixel target is not a target — every desktop
    /// toolkit makes the hit area several times the ink, and it is the single
    /// difference between a scrollbar that feels broken and one that does not.
    static let hitThickness: Float = 14
    /// Gap between the bar and the edge of the box.
    static let margin: Float = 2
    /// A thumb shorter than this cannot be aimed at, however long the content.
    /// Past that point it stops being proportional, which is the usual and
    /// correct trade.
    static let minimumThumb: Float = 24

    /// Where the thumb sits along a track, in the track's own coordinates.
    struct Metrics {
        /// Length of the groove the thumb travels in.
        var track: Float
        /// Length of the thumb itself.
        var thumb: Float
        /// How far the thumb can travel: `track - thumb`.
        var travel: Float
        /// Distance from the start of the track to the top of the thumb.
        var along: Float
    }

    /// Nil when there is nothing to indicate — no box, no content, or content
    /// that already fits.
    static func metrics(
        track: Float, content: Float, offset: Float, maxOffset: Float
    ) -> Metrics? {
        guard track > 0, content > 0, maxOffset > 0 else { return nil }
        let ratio = min(1, track / content)
        let thumb = min(track, max(minimumThumb, track * ratio))
        let travel = max(0, track - thumb)
        let progress = min(1, max(0, offset / maxOffset))
        return Metrics(track: track, thumb: thumb, travel: travel, along: travel * progress)
    }

    /// Scroll offset for a thumb whose top sits `along` down the track.
    ///
    /// The inverse of `metrics`, and it has to be exactly that: a drag reads
    /// the pointer, converts here, and the next frame converts back through
    /// `metrics` to draw. Any disagreement shows up as a thumb that lags or
    /// runs ahead of the finger holding it.
    static func offset(forAlong along: Float, travel: Float, maxOffset: Float) -> Float {
        guard travel > 0 else { return 0 }
        return min(maxOffset, max(0, along / travel * maxOffset))
    }

    /// True when a point in box-local coordinates is on the vertical bar.
    ///
    /// The whole track, not just the thumb: clicking the groove is a page
    /// jump in every toolkit, and more to the point a hit test that only
    /// covered the thumb would let a near miss place a caret instead.
    static func hitsVertical(localX: Float, boxWidth: Float) -> Bool {
        localX >= boxWidth - hitThickness
    }

    static func hitsHorizontal(localY: Float, boxHeight: Float) -> Bool {
        localY >= boxHeight - hitThickness
    }
}

/// Which scrollbar the pointer currently has hold of.
///
/// One drag at a time, process-wide, for the same reason `PointerCapture` is:
/// there is one pointer. This exists only so the thumb can be drawn brighter
/// while it is held — the drag itself lives in the `PointerCapture` closure
/// that started it.
enum ScrollbarDrag {
    nonisolated(unsafe) private static var owner: (node: NodeID, axis: ScrollAxis)?

    static func begin(_ node: NodeID, axis: ScrollAxis) {
        owner = (node, axis)
        ViewInvalidation.markNeedsRedraw()
    }

    static func end() {
        guard owner != nil else { return }
        owner = nil
        ViewInvalidation.markNeedsRedraw()
    }

    static func isDragging(_ node: NodeID, axis: ScrollAxis) -> Bool {
        owner?.node == node && owner?.axis == axis
    }

    /// For a container with only one bar, where the axis is not in question.
    static func isDragging(_ node: NodeID) -> Bool { owner?.node == node }
}

extension LeafNode {
    /// Takes a press that landed on one of this editor's scrollbars.
    ///
    /// Returns false when it did not, so the caller can go on to place a
    /// caret. Vertical wins a corner overlap: it is the bar people reach for,
    /// and a press in the last few pixels of both is far more likely to be
    /// aimed at it.
    ///
    /// Grabbing the thumb keeps the grab offset, so the content does not jump
    /// to put the thumb's *top* under the finger. Pressing the empty track
    /// jumps there and then drags from the middle, which is what a press on
    /// bare track means everywhere else.
    func beginScrollbarDrag(
        localX: Float, localY: Float, originX: Float, originY: Float
    ) -> Bool {
        guard let font = self.font ?? FontStore.default else { return false }

        if let m = verticalScrollbar(font: font),
           Scrollbar.hitsVertical(localX: localX, boxWidth: viewportWidth)
        {
            let maximum = maxScrollY(lineHeight: font.lineHeight)
            let grab = localY >= m.along && localY < m.along + m.thumb
                ? localY - m.along : m.thumb / 2
            ScrollbarDrag.begin(id, axis: .vertical)
            let apply = { [weak self] (windowY: Float) in
                guard let self else { return }
                self.scrollY = Scrollbar.offset(
                    forAlong: windowY - originY - grab, travel: m.travel, maxOffset: maximum
                )
                ViewInvalidation.markNeedsRedraw()
            }
            apply(originY + localY)
            PointerCapture.capture(
                id, onMove: { _, wy in apply(wy) }, onUp: { ScrollbarDrag.end() }
            )
            return true
        }

        if let m = horizontalScrollbar(font: font),
           Scrollbar.hitsHorizontal(localY: localY, boxHeight: viewportHeight)
        {
            let maximum = maxScrollX(font: font)
            // The gutter is not part of the horizontal track.
            let trackX = localX - gutterWidth
            let grab = trackX >= m.along && trackX < m.along + m.thumb
                ? trackX - m.along : m.thumb / 2
            ScrollbarDrag.begin(id, axis: .horizontal)
            let apply = { [weak self] (windowX: Float) in
                guard let self else { return }
                self.scrollX = Scrollbar.offset(
                    forAlong: windowX - originX - self.gutterWidth - grab,
                    travel: m.travel, maxOffset: maximum
                )
                ViewInvalidation.markNeedsRedraw()
            }
            apply(originX + localX)
            PointerCapture.capture(
                id, onMove: { wx, _ in apply(wx) }, onUp: { ScrollbarDrag.end() }
            )
            return true
        }

        return false
    }
}
