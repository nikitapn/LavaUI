import Foundation

/// Hierarchical min/max index for viewport-aware rendering.
///
/// Leaves are source points and every parent stores the indices of the minimum
/// and maximum values below it. A viewport query divides time—not point count—
/// into screen-width buckets, then asks the tree for each bucket's extrema.
/// This matters for irregular telemetry: every horizontal pixel column keeps
/// its own spike and dip, even if one column contains far more samples than its
/// neighbours.
public struct TracePyramid: Sendable {
    public let points: [TracePoint]
    private let leafBase: Int
    private let minima: [Int]
    private let maxima: [Int]

    public var valueRange: ClosedRange<Double>? {
        guard !points.isEmpty, minima.count > 1, maxima.count > 1 else { return nil }
        return points[minima[1]].value...points[maxima[1]].value
    }

    public init(points: [TracePoint]) {
        self.points = points
        var base = 1
        while base < points.count { base *= 2 }
        leafBase = base

        guard !points.isEmpty else {
            minima = []
            maxima = []
            return
        }
        var minTree = [Int](repeating: -1, count: base * 2)
        var maxTree = [Int](repeating: -1, count: base * 2)
        for index in points.indices {
            minTree[base + index] = index
            maxTree[base + index] = index
        }
        if base > 1 {
            for node in stride(from: base - 1, through: 1, by: -1) {
                minTree[node] = Self.chooseMinimum(minTree[node * 2], minTree[node * 2 + 1], points)
                maxTree[node] = Self.chooseMaximum(maxTree[node * 2], maxTree[node * 2 + 1], points)
            }
        }
        minima = minTree
        maxima = maxTree
    }

    /// Returns original points in chronological order, retaining at most the
    /// first/minimum/maximum/last point from each time bucket. Consequently the
    /// output is bounded by `targetBucketCount * 4` and all per-pixel extrema
    /// survive. When the visible source already fits, it is returned exactly.
    public func sampled(
        in timeRange: ClosedRange<Double>, targetBucketCount: Int
    ) -> [TracePoint] {
        guard !points.isEmpty, targetBucketCount > 0,
              timeRange.upperBound >= timeRange.lowerBound else { return [] }
        let visibleLower = lowerBound(timeRange.lowerBound)
        let visibleUpper = upperBound(timeRange.upperBound)
        guard visibleLower < visibleUpper else { return [] }

        if visibleUpper - visibleLower <= targetBucketCount ||
            timeRange.upperBound == timeRange.lowerBound {
            return Array(points[visibleLower..<visibleUpper])
        }

        let duration = timeRange.upperBound - timeRange.lowerBound
        var result: [TracePoint] = []
        result.reserveCapacity(targetBucketCount * 4)

        for bucket in 0..<targetBucketCount {
            let startTime = timeRange.lowerBound
                + duration * Double(bucket) / Double(targetBucketCount)
            let endTime = timeRange.lowerBound
                + duration * Double(bucket + 1) / Double(targetBucketCount)
            let lower = max(visibleLower, lowerBound(startTime))
            let upper = min(
                visibleUpper,
                bucket == targetBucketCount - 1 ? upperBound(endTime) : lowerBound(endTime)
            )
            guard lower < upper else { continue }
            let extrema = rangeExtrema(lower..<upper)
            let indices = orderedUnique([lower, extrema.minimum, extrema.maximum, upper - 1])
            result.append(contentsOf: indices.map { points[$0] })
        }
        return result
    }

    private func rangeExtrema(_ range: Range<Int>) -> (minimum: Int, maximum: Int) {
        var lower = range.lowerBound + leafBase
        var upper = range.upperBound + leafBase
        var minimum = -1
        var maximum = -1
        while lower < upper {
            if lower & 1 == 1 {
                minimum = Self.chooseMinimum(minimum, minima[lower], points)
                maximum = Self.chooseMaximum(maximum, maxima[lower], points)
                lower += 1
            }
            if upper & 1 == 1 {
                upper -= 1
                minimum = Self.chooseMinimum(minimum, minima[upper], points)
                maximum = Self.chooseMaximum(maximum, maxima[upper], points)
            }
            lower /= 2
            upper /= 2
        }
        return (minimum, maximum)
    }

    private func orderedUnique(_ candidates: [Int]) -> [Int] {
        var result: [Int] = []
        for index in candidates.sorted() where index >= 0 && result.last != index {
            result.append(index)
        }
        return result
    }

    private static func chooseMinimum(_ lhs: Int, _ rhs: Int, _ points: [TracePoint]) -> Int {
        if lhs < 0 { return rhs }
        if rhs < 0 { return lhs }
        return points[lhs].value <= points[rhs].value ? lhs : rhs
    }

    private static func chooseMaximum(_ lhs: Int, _ rhs: Int, _ points: [TracePoint]) -> Int {
        if lhs < 0 { return rhs }
        if rhs < 0 { return lhs }
        return points[lhs].value >= points[rhs].value ? lhs : rhs
    }

    private func lowerBound(_ time: Double) -> Int {
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].time < time { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    private func upperBound(_ time: Double) -> Int {
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].time <= time { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
}
