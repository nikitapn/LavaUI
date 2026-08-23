import Foundation

/// Process-wide counters for work the frame pipeline did.
///
/// These exist because wall-clock alone is a bad regression gate: the same
/// machine varies 20-30% run to run, so a threshold loose enough not to cry
/// wolf is too loose to catch a 2x algorithmic regression until it is a 4x
/// one. *Counts* have no variance. "How many lines did we shape to draw this
/// frame" is 41 or it is 200,000, and the second one is the bug — the exact
/// bug that made opening a 10 MB log in TraceLoom take 601 ms.
///
/// So `LavaBench` gates on counters and *reports* times. A counter moving is
/// a hard failure; a time moving is a number to look at.
///
/// Incremented unconditionally rather than behind an `isEnabled` flag. Each
/// site is per-shaped-line or per-Yoga-measure — thousands per frame at the
/// very worst, against work that is orders of magnitude more expensive — and
/// a branch on a second global would cost more than the add it guards.
public enum PerfCounters {
    /// Lines handed to HarfBuzz because `UIFont`'s shape cache missed.
    nonisolated(unsafe) public static var textShapes = 0
    /// Lines served from that cache. `textShapes + textShapeHits` is the
    /// number of shaping *requests*, which is the interesting one for emit:
    /// it should track visible rows, not buffer size.
    nonisolated(unsafe) public static var textShapeHits = 0
    /// Logical lines broken into rows by a soft-wrap pass — the ones the wrap
    /// cache could not reuse. Shaping alone does not show this: a line whose
    /// text is unchanged is served from `UIFont`'s shape cache and never
    /// reaches HarfBuzz, but it still pays for its advances to be laid out and
    /// its breaks to be found. On an edit this should be a handful; anything
    /// proportional to the buffer means the cache was thrown away.
    nonisolated(unsafe) public static var lineWraps = 0
    /// `LeafNode.measureForYoga` calls — Yoga measure-function invocations.
    nonisolated(unsafe) public static var yogaMeasures = 0
    /// `LayoutHost.calculateLayout` calls, including the lazy-window settle
    /// re-passes (which is why this can exceed one per frame).
    nonisolated(unsafe) public static var layoutPasses = 0
    /// Images decoded + uploaded because `ImageStore` missed.
    nonisolated(unsafe) public static var imageDecodes = 0
    /// Images dropped by the byte budget. With `imageDecodes`, this is the
    /// thrash signal: a scroll that decodes and evicts the same covers over
    /// and over shows up here long before it shows up as a slow frame.
    nonisolated(unsafe) public static var imageEvictions = 0

    public static func reset() {
        textShapes = 0
        textShapeHits = 0
        lineWraps = 0
        yogaMeasures = 0
        layoutPasses = 0
        imageDecodes = 0
        imageEvictions = 0
    }

    /// Ordered so a printed table has a stable column order.
    public static func snapshot() -> [(name: String, value: Int)] {
        [
            ("shapes", textShapes),
            ("shapeHits", textShapeHits),
            ("lineWraps", lineWraps),
            ("measures", yogaMeasures),
            ("layouts", layoutPasses),
            ("decodes", imageDecodes),
            ("evictions", imageEvictions),
        ]
    }
}
