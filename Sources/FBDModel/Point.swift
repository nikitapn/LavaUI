/// A plain 2D point. FBDModel has no dependencies (not even Foundation), so
/// this is its own minimal type rather than `CGPoint` — the rendering layer
/// is free to convert to/from whatever point type it uses.
public struct Point: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
