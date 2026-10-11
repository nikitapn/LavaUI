/// An axis-aligned rectangle, top-left origin, in whatever unit the caller
/// is in — page points for text, document points for layout.
///
/// Its own type rather than LavaUI's, which this module does not import: the
/// model has to be testable with no engine at all.
public struct Box: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midY: Double { y + height / 2 }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < maxX && py >= y && py < maxY
    }

    public func intersects(_ other: Box) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    public func union(_ other: Box) -> Box {
        let left = min(x, other.x), top = min(y, other.y)
        return Box(
            x: left, y: top,
            width: max(maxX, other.maxX) - left,
            height: max(maxY, other.maxY) - top
        )
    }

    /// How far a point is from the box: zero inside, else to the nearest edge.
    func distance(x px: Double, y py: Double) -> Double {
        let dx = max(x - px, 0, px - maxX)
        let dy = max(y - py, 0, py - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
