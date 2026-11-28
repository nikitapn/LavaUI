import LavaUI

extension ScrollPosition {
    /// Scrolls only as far as it takes to show row `index` of a list of
    /// `rowHeight` rows in a view `viewportHeight` tall — a row above comes
    /// in at the top, one below at the bottom, the way a list follows its
    /// keyboard. Through the offset rather than `scrollIntoView`: the
    /// sidebar's lists are lazy, and a row past the view has no node to ask.
    func keepRowInSight(_ index: Int, rowHeight: Float, viewportHeight: Float) {
        guard viewportHeight > 0, index >= 0 else { return }
        let top = Float(index) * rowHeight
        if top < offset {
            scroll(to: top)
        } else if top + rowHeight > offset + viewportHeight {
            scroll(to: top + rowHeight - viewportHeight)
        }
    }
}
