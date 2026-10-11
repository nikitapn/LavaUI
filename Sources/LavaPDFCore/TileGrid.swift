import Foundation

/// One tile of one page at one scale.
public struct TileKey: Hashable, Sendable {
    public var page: Int
    /// The scale it was rendered at — see `TileGrid.scaleKey(forScale:)`.
    public var scaleKey: Int
    public var column: Int
    public var row: Int

    public init(page: Int, scaleKey: Int, column: Int, row: Int) {
        self.page = page
        self.scaleKey = scaleKey
        self.column = column
        self.row = row
    }
}

/// Which tiles a view of a page needs, and where each one comes from.
///
/// A page is rendered in square tiles rather than as one picture, so a page
/// zoomed to 800% is a handful of tiles where the viewport is, not one
/// 30-megapixel render.
///
/// The tiles a reader *reads* are rendered at exactly the zoom on screen, so
/// each of their pixels lands on one of the screen's. Quantising the scale to
/// steps of √2 and drawing the result a little smaller was the first version,
/// and it is the obvious one — a wheel zoom then reuses what it has — but text
/// minified by up to 0.7 through a bilinear sampler is visibly soft, and
/// sharp text is the one thing a reader is for. So the steps are only for the
/// preview a page gets before its real tiles arrive; during a zoom, whatever
/// is resident stays on screen, scaled, until the new scale renders.
public enum TileGrid {
    /// Pixels along a tile's side. 512² is 1 MiB of BGRX: big enough that a
    /// screenful is a dozen tiles and a dozen uploads, small enough that a
    /// tile at the edge of the viewport is not mostly offscreen.
    public static let tileSize = 512

    /// A scale key is pixels per point in 1024ths: an integer, so two frames
    /// at the same zoom ask for the same tiles and a dictionary finds them,
    /// where a `Double` from two different computations would not agree in
    /// its last bit. 1/1024 is far finer than anyone can see.
    public static let keysPerUnit = 1024

    /// 1/64 to 32 pixels per point: past the zoom range on both sides,
    /// preview included, and nowhere near where a page's pixel size overflows.
    public static let scaleKeys = 16...32768

    /// The key for rendering at `scale` pixels per point — the nearest, or
    /// with `.down` the largest not above it.
    public static func scaleKey(
        forScale scale: Double, rounding: FloatingPointRoundingRule = .toNearestOrAwayFromZero
    ) -> Int {
        guard scale > 0, scale.isFinite else { return keysPerUnit }
        let key = Int((scale * Double(keysPerUnit)).rounded(rounding))
        return min(max(key, scaleKeys.lowerBound), scaleKeys.upperBound)
    }

    /// Pixels per point at `key`.
    public static func scale(ofKey key: Int) -> Double {
        Double(key) / Double(keysPerUnit)
    }

    /// The key for a page's preview while its tiles at `key` are coming: about
    /// a quarter of the scale, on a √2 ladder so that the preview for 150% and
    /// the one for 152% are the same picture, rendered once.
    public static func previewKey(for key: Int) -> Int {
        let quarter = scale(ofKey: key) / 4
        let rung = (2 * log2(quarter)).rounded(.down)
        return scaleKey(forScale: pow(2, rung / 2))
    }

    /// The page's size in pixels at `scaleKey`.
    public static func pixelSize(of page: PageSize, scaleKey: Int) -> (width: Int, height: Int) {
        let scale = scale(ofKey: scaleKey)
        return (
            max(1, Int((page.width * scale).rounded(.up))),
            max(1, Int((page.height * scale).rounded(.up)))
        )
    }

    /// The tiles of `page` at `scaleKey` that any part of `visible` (in the page's
    /// points, from its top-left) covers, nearest the middle of `visible`
    /// first — the order to render them in, so what the eye is on fills in
    /// before the edges.
    public static func tiles(
        page: Int, size: PageSize, scaleKey: Int, visible: Box
    ) -> [TileKey] {
        let scale = scale(ofKey: scaleKey)
        let pixels = pixelSize(of: size, scaleKey: scaleKey)
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
                    TileKey(page: page, scaleKey: scaleKey, column: column, row: row),
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
        let pixels = pixelSize(of: size, scaleKey: key.scaleKey)
        let x = key.column * tileSize, y = key.row * tileSize
        return (x, y, max(0, min(tileSize, pixels.width - x)), max(0, min(tileSize, pixels.height - y)))
    }

    /// Where on the page the tile is drawn, in points.
    public static func pointRect(of key: TileKey, size: PageSize) -> Box {
        let rect = pixelRect(of: key, size: size)
        let scale = scale(ofKey: key.scaleKey)
        return Box(
            x: Double(rect.x) / scale, y: Double(rect.y) / scale,
            width: Double(rect.width) / scale, height: Double(rect.height) / scale
        )
    }
}

/// One render that produces several tiles: a window of one page at one
/// scaleKey, and the tiles to cut out of it.
public struct TileBatch: Equatable, Sendable {
    public var page: Int
    public var scaleKey: Int
    /// The window, in the page's pixels at `scaleKey`.
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    /// The tiles inside it that were asked for, in the order they were.
    public var tiles: [TileKey]
}

extension TileGrid {
    /// The most pixels one batch renders: 4 MP, 16 MiB of BGRX. Past this a
    /// render holds its worker long enough that a scroll which made it
    /// pointless cannot cancel it, and the buffer is a large allocation for
    /// one call.
    public static let maxBatchPixels = 4 * 1024 * 1024

    /// Groups `tiles` into renders.
    ///
    /// A tile costs poppler about what its whole page costs — it interprets
    /// the entire content stream for every slice, and clips at the end — so
    /// twelve tiles of one page rendered one by one is twelve renders of the
    /// page. One window over all of them is one. Measured: 14 ms for a 64×64
    /// corner of a page that renders whole in 23.
    ///
    /// So: per page and scaleKey, the bounding window of the tiles asked for,
    /// split into bands of whole tile rows when it is over `maxPixels`. A
    /// tile inside the window that was *not* asked for is rendered and thrown
    /// away, which is cheaper than a second pass over the page. Batches come
    /// out in the order of the first tile each contains, so the caller's
    /// priority survives.
    public static func batches(
        for tiles: [TileKey], sizes: (Int) -> PageSize,
        maxPixels: Int = maxBatchPixels
    ) -> [TileBatch] {
        struct Group { var keys: [TileKey]; var first: Int }
        var groups: [[Int]: Group] = [:]
        for (order, key) in tiles.enumerated() {
            groups[[key.page, key.scaleKey], default: Group(keys: [], first: order)].keys.append(key)
        }

        var result: [(first: Int, batch: TileBatch)] = []
        for group in groups.values {
            let page = group.keys[0].page, scaleKey = group.keys[0].scaleKey
            let size = sizes(page)
            let firstColumn = group.keys.map(\.column).min()!
            let lastColumn = group.keys.map(\.column).max()!
            let rows = Set(group.keys.map(\.row)).sorted()

            // Rows per band: as many whole tile rows as fit the budget, and
            // never fewer than one, so a single enormous tile row still renders.
            let bandWidth = (lastColumn - firstColumn + 1) * tileSize
            let rowsPerBand = max(1, maxPixels / max(1, bandWidth * tileSize))

            var bandStart = 0
            while bandStart < rows.count {
                // Contiguous rows only: two runs of rows with a gap between them
                // are two windows, not one that renders the gap.
                var bandEnd = bandStart
                while bandEnd + 1 < rows.count,
                      rows[bandEnd + 1] == rows[bandEnd] + 1,
                      bandEnd + 1 - bandStart < rowsPerBand
                { bandEnd += 1 }
                let firstRow = rows[bandStart], lastRow = rows[bandEnd]

                let topLeft = pixelRect(of: TileKey(page: page, scaleKey: scaleKey, column: firstColumn, row: firstRow), size: size)
                let bottomRight = pixelRect(of: TileKey(page: page, scaleKey: scaleKey, column: lastColumn, row: lastRow), size: size)
                let keys = group.keys.filter { $0.row >= firstRow && $0.row <= lastRow }
                let first = keys.compactMap { key in tiles.firstIndex(of: key) }.min() ?? group.first
                result.append((first, TileBatch(
                    page: page, scaleKey: scaleKey,
                    x: topLeft.x, y: topLeft.y,
                    width: bottomRight.x + bottomRight.width - topLeft.x,
                    height: bottomRight.y + bottomRight.height - topLeft.y,
                    tiles: keys
                )))
                bandStart = bandEnd + 1
            }
        }
        return result.sorted { $0.first < $1.first }.map(\.batch)
    }
}
