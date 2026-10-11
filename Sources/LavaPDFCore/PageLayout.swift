/// Pages in one continuous column, the way a reader scrolls through them.
///
/// In document points at zoom 1: a viewer multiplies by its zoom to place a
/// page on screen, and divides a pointer position by it to ask which page is
/// under it. Pages of different widths are centred on the widest, which is
/// what keeps a landscape page in a portrait document from pulling the
/// column to one side.
public struct PageLayout: Equatable, Sendable {
    /// Where each page sits.
    public let frames: [Box]
    /// The whole column, margins included.
    public let width: Double
    public let height: Double

    public init(pageSizes: [PageSize], gap: Double = 12, margin: Double = 12) {
        let widest = pageSizes.map(\.width).max() ?? 0
        var frames: [Box] = []
        frames.reserveCapacity(pageSizes.count)
        var y = margin
        for size in pageSizes {
            frames.append(Box(
                x: margin + (widest - size.width) / 2, y: y,
                width: size.width, height: size.height
            ))
            y += size.height + gap
        }
        self.frames = frames
        width = widest + 2 * margin
        height = pageSizes.isEmpty ? 2 * margin : y - gap + margin
    }

    /// The pages any part of `rect` covers, in order. Binary search, so a
    /// thousand-page document costs ten comparisons a frame rather than a
    /// thousand.
    public func pages(intersecting rect: Box) -> Range<Int> {
        let first = firstPage(endingAfter: rect.y)
        var last = first
        while last < frames.count, frames[last].y < rect.maxY { last += 1 }
        return first..<last
    }

    /// The page under a point, or nil in a gap or a margin.
    public func page(atX x: Double, y: Double) -> Int? {
        let candidate = firstPage(endingAfter: y)
        guard candidate < frames.count, frames[candidate].contains(x: x, y: y)
        else { return nil }
        return candidate
    }

    /// The first page whose bottom is below `y`.
    private func firstPage(endingAfter y: Double) -> Int {
        var low = 0, high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].maxY <= y { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
