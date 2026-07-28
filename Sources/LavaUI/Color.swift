/// sRGB color with alpha. Maps cleanly to `DrawCommand` RGBA8 later.
public struct Color: Equatable, Sendable, Hashable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(r: Float, g: Float, b: Float, a: Float = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Pack as RGBA8 (r in high bits of first byte… actually R,G,B,A little-endian u32).
    public var rgba8: UInt32 {
        let R = UInt32(clamping: Int((r * 255).rounded()))
        let G = UInt32(clamping: Int((g * 255).rounded()))
        let B = UInt32(clamping: Int((b * 255).rounded()))
        let A = UInt32(clamping: Int((a * 255).rounded()))
        return R | (G << 8) | (B << 16) | (A << 24)
    }

    public static let primary = Color(r: 0.90, g: 0.90, b: 0.90)
    public static let secondary = Color(r: 0.55, g: 0.55, b: 0.60)
    public static let accent = Color(r: 0.70, g: 0.75, b: 0.90)
    public static let selected = Color(r: 1.0, g: 0.85, b: 0.40)
    public static let muted = Color(r: 0.50, g: 0.60, b: 0.50)
    public static let dim = Color(r: 0.45, g: 0.55, b: 0.50)
}
