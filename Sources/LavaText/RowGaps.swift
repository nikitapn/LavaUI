/// Blank rows set between an editor's rows — the room a side-by-side diff
/// leaves on one side for lines only the other side has.
///
/// An editor that draws them stops being "row `r` is `r` row-heights down":
/// a row's *slot* is its index plus every blank row above it, and the slot
/// is what is multiplied by the line height. Everything that turns rows into
/// pixels and back goes through `slot(ofRow:)` and `row(atSlot:)`, so this
/// is the whole of the mapping, kept here where it is tested without a font.
public struct RowGaps: Equatable, Sendable {
    /// `(row, count)`: `count` blank rows directly above `row`, sorted by
    /// row with one entry per row. `row` may be the row count — blank rows
    /// after the last one.
    public private(set) var entries: [(row: Int, count: Int)] = []
    /// Blank rows in `entries[0...i]`.
    private var through: [Int] = []

    public init() {}

    /// From unsorted, possibly repeated `(row, count)` pairs; zero and
    /// negative counts are dropped, repeats are added together.
    public init(_ gaps: [(row: Int, count: Int)]) {
        var merged: [Int: Int] = [:]
        for gap in gaps where gap.count > 0 { merged[max(0, gap.row), default: 0] += gap.count }
        entries = merged.sorted { $0.key < $1.key }.map { (row: $0.key, count: $0.value) }
        var total = 0
        through = entries.map { total += $0.count; return total }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Every blank row.
    public var total: Int { through.last ?? 0 }

    /// Blank rows above `row`, its own gap included.
    public func before(row: Int) -> Int {
        // The last entry at or above `row`.
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].row <= row { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? 0 : through[low - 1]
    }

    /// Where `row` is drawn, counting blank rows.
    public func slot(ofRow row: Int) -> Int { row + before(row: row) }

    /// The row drawn at `slot`, and whether the slot is blank. A blank slot
    /// answers with the row below the gap — where a click there should land.
    /// Past the last row the answer is past it too; the caller clamps.
    public func row(atSlot slot: Int) -> (row: Int, isGap: Bool) {
        // The last entry whose gap starts at or above `slot`. Entry `i`'s gap
        // starts at slot `row_i + through[i-1]`, which only grows with `i`.
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            let start = entries[mid].row + (mid == 0 ? 0 : through[mid - 1])
            if start <= slot { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return (slot, false) }
        let i = low - 1
        let start = entries[i].row + (i == 0 ? 0 : through[i - 1])
        if slot < start + entries[i].count { return (entries[i].row, true) }
        return (slot - through[i], false)
    }

    /// The gaps directly above rows `rows`, for drawing.
    public func entries(above rows: ClosedRange<Int>) -> ArraySlice<(row: Int, count: Int)> {
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].row < rows.lowerBound { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < entries.count, entries[end].row <= rows.upperBound { end += 1 }
        return entries[low..<end]
    }

    public static func == (lhs: RowGaps, rhs: RowGaps) -> Bool {
        lhs.entries.count == rhs.entries.count
            && zip(lhs.entries, rhs.entries).allSatisfy { $0.row == $1.row && $0.count == $1.count }
    }
}
