import Foundation
import Testing
@testable import TraceLoomCore

@Test func pyramidPreservesLocalExtremaAndChronologicalOrder() {
    var points = (0..<1_024).map { TracePoint(time: Double($0), value: 10) }
    points[333].value = -900
    points[334].value = 1_200
    let sampled = TracePyramid(points: points).sampled(in: 0...1_023, targetBucketCount: 32)

    #expect(sampled.contains(points[333]))
    #expect(sampled.contains(points[334]))
    #expect(zip(sampled, sampled.dropFirst()).allSatisfy { $0.time <= $1.time })
    #expect(sampled.count <= 32 * 4)
}

@Test func pyramidReturnsExactPointsWhenTheyFitViewport() {
    let points = (0..<20).map { TracePoint(time: Double($0), value: Double($0 * $0)) }
    let sampled = TracePyramid(points: points).sampled(in: 5...12, targetBucketCount: 20)
    #expect(sampled == Array(points[5...12]))
}

@Test func viewportEdgesDoNotLeakOutsideExtrema() {
    var points = (0..<128).map { TracePoint(time: Double($0), value: 5) }
    points[31].value = 99_999
    let sampled = TracePyramid(points: points).sampled(in: 32...80, targetBucketCount: 4)
    #expect(!sampled.contains(points[31]))
    #expect(sampled.allSatisfy { $0.time >= 32 && $0.time <= 80 })
}

@Test func fiftyThousandIrregularPointsStayPixelBoundedAndKeepSpikes() {
    var time = 0.0
    var points: [TracePoint] = []
    points.reserveCapacity(50_000)
    for index in 0..<50_000 {
        // Alternating cadence ensures point-count buckets would not line up
        // with equal screen-time columns.
        time += index.isMultiple(of: 7) ? 20 : 0.2
        points.append(TracePoint(time: time, value: sin(Double(index) * 0.01)))
    }
    points[12_345].value = 50_000
    points[40_001].value = -40_000

    let width = 800
    let sampled = TracePyramid(points: points).sampled(
        in: points.first!.time...points.last!.time,
        targetBucketCount: width
    )
    #expect(sampled.count <= width * 4)
    #expect(sampled.contains(points[12_345]))
    #expect(sampled.contains(points[40_001]))
}
