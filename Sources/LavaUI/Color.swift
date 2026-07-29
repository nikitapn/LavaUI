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

    /// Moves toward white by `amount` (0…1), keeping alpha.
    ///
    /// For deriving a hover or pressed variant from a semantic token, so a
    /// control does not have to hard-code a second colour that a theme swap
    /// would then fail to update.
    public func lightened(_ amount: Float) -> Color {
        Color(
            r: r + (1 - r) * amount,
            g: g + (1 - g) * amount,
            b: b + (1 - b) * amount,
            a: a
        )
    }

    /// Returns a copy with alpha replaced (0…1). Useful for glass tints on
    /// top of `.blur()`.
    public func opacity(_ alpha: Float) -> Color {
        Color(r: r, g: g, b: b, a: alpha)
    }

    /// Perceived brightness, 0…1 (Rec. 601 weights). For deciding whether a
    /// foreground drawn *on* this colour should be light or dark.
    public var luminance: Float { 0.299 * r + 0.587 * g + 0.114 * b }

    // Semantic tokens live in Theme.swift so they resolve through
    // `Theme.current` rather than being frozen here.
}
