import Foundation

/// One tile of one page at one zoom level.
public struct TileKey: Hashable, Sendable {
    public var page: Int
    /// See `TileGrid.level(forScale:)`.
    public var level: Int
    public var column: Int
    public var row: Int

    public init(page: Int, level: Int, column: Int, row: Int) {
        self.page = page
        self.level = level
        self.column = column
        self.row = row
    }
}

/// Which tiles a view of a page needs, and where each one comes from.
///
/// A page is rendered in square tiles at a quantised scale rather than as one
/// picture at exactly the zoom on screen. Two reasons, and both are about
/// zooming. A tile is bounded in size, so a page zoomed to 800% is a handful of
/// tiles where the viewport is, not one 30-megapixel render. And the scale
/// moves in steps of √2 rather than continuously, so a pinch or a wheel zoom
/// reuses what it already has — drawn a little soft until the sharper level
/// arrives — instead of invalidating everything on every frame of the gesture.
public enum TileGrid {
    /// Pixels along a tile's side. 512² is 1 MiB of BGRX: big enough that a
    /// screenful is a dozen tiles and a dozen uploads, small enough that a
    /// tile at the edge of the viewport is not mostly offscreen.
    public static let tileSize = 512

    /// The levels a scale is clamped to: 1/16× to 256×, far past what anyone
    /// reads at, and nowhere near where a page's pixel size overflows.
    public static let levels = -8...16

    /// The level to render `scale` (pixels per point) at: the smallest one at
    /// least as sharp, so a tile is only ever drawn *down* — up to √2 smaller,
    /// never blown up.
    public static func level(forScale scale: Double) -> Int {
        guard scale > 0, scale.isFinite else { return 0 }
        // A hair of slack so a scale that is exactly a level does not round
        // to the next one through floating-point noise.
        let exact = 2 * log2(scale)
        let level = Int((exact - 1e-9).rounded(.up))
        return min(max(level, levels.lowerBound), levels.upperBound)
    }

    /// Pixels per point at `level`: √2 to the power of the level.
    public static func scale(ofLevel level: Int) -> Double {
        pow(2, Double(level) / 2)
    }

    /// The page's size in pixels at `level`.
    public static func pixelSize(of page: PageSize, level: Int) -> (width: Int, height: Int) {
        let scale = scale(ofLevel: level)
        return (
            max(1, Int((page.width * scale).rounded(.up))),
            max(1, Int((page.height * scale).rounded(.up)))
        )
    }

    /// The tiles of `page` at `level` that any part of `visible` (in the page's
    /// points, from its top-left) covers, nearest the middle of `visible`
    /// first — the order to render them in, so what the eye is on fills in
    /// before the edges.
    public static func tiles(
        page: Int, size: PageSize, level: Int, visible: Box
    ) -> [TileKey] {
        let scale = scale(ofLevel: level)
        let pixels = pixelSize(of: size, level: level)
        let columns = (pixels.width + tileSize - 1) / tileSize
        let rows = (pixels.height + tileSize - 1) / tileSize
        let tile = Double(tileSize)

        let firstColumn = max(0, Int((visible.x * scale / tile).rounded(.down)))
        let lastColumn = min(columns - 1, Int((visible.maxX * scale / tile).rounded(.up)) - 1)
        let firstRow = max(0, Int((visible.y * scale / tile).rounded(.down)))
        let lastRow = min(rows - 1, Int((visible.maxY * scale / tile).rounded(.up)) - 1)
        guard firstColumn <= lastColumn, firstRow <= lastRow else { return [] }

        let centreX = (visible.x + visible.width / 2) * scale / tile
        let centreY = (visible.y + visible.height / 2) * scale / tile
        var keys: [(key: TileKey, distance: Double)] = []
        for row in firstRow...lastRow {
            for column in firstColumn...lastColumn {
                let dx = Double(column) + 0.5 - centreX
                let dy = Double(row) + 0.5 - centreY
                keys.append((
                    TileKey(page: page, level: level, column: column, row: row),
                    dx * dx + dy * dy
                ))
            }
        }
        // Stable on ties, so the order does not shimmer between frames.
        return keys.enumerated()
            .sorted { ($0.element.distance, $0.offset) < ($1.element.distance, $1.offset) }
            .map(\.element.key)
    }

    /// The window to ask the renderer for: where the tile starts in the page's
    /// pixels, and its size — a full tile, or less on the right and bottom
    /// edges, so nothing renders paper past the page.
    public static func pixelRect(
        of key: TileKey, size: PageSize
    ) -> (x: Int, y: Int, width: Int, height: Int) {
        let pixels = pixelSize(of: size, level: key.level)
        let x = key.column * tileSize, y = key.row * tileSize
        return (x, y, max(0, min(tileSize, pixels.width - x)), max(0, min(tileSize, pixels.height - y)))
    }

    /// Where on the page the tile is drawn, in points.
    public static func pointRect(of key: TileKey, size: PageSize) -> Box {
        let rect = pixelRect(of: key, size: size)
        let scale = scale(ofLevel: key.level)
        return Box(
            x: Double(rect.x) / scale, y: Double(rect.y) / scale,
            width: Double(rect.width) / scale, height: Double(rect.height) / scale
        )
    }
}
