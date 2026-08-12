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

    /// Fully transparent — draws nothing at all.
    ///
    /// What a conditional background needs for its "neither" case. A row that
    /// is highlighted when selected and hovered has to fall back to *no fill*
    /// the rest of the time, and the nearest thing without this is the theme's
    /// own background painted over whatever the row actually sits on, which is
    /// right until the day something sits behind it.
    public static let clear = Color(r: 0, g: 0, b: 0, a: 0)

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

    /// From hue (turns, 0…1 and wrapping), saturation and lightness.
    ///
    /// Here rather than at a call site because the useful thing about HSL is
    /// generating a *family* — a row of tints that vary in hue while holding
    /// saturation and lightness fixed, so they read as one set instead of as
    /// an argument. Doing that in RGB means picking every member by hand and
    /// getting the brightness subtly wrong on the ones near yellow.
    ///
    /// `lightness` is in the same space as `r`/`g`/`b`, which is the space the
    /// pipeline treats as **linear** — the swapchain encodes to sRGB on the way
    /// out, so a component of 0.28 leaves the GPU looking like 0.56 and every
    /// palette in this codebase is authored against that. Worth knowing before
    /// picking a number: a lightness that reads as "dark" in a colour picker
    /// arrives on screen as a mid-tone.
    public init(hue: Float, saturation: Float, lightness: Float, alpha: Float = 1) {
        let h = hue - hue.rounded(.down)  // wrap into 0…1
        let s = min(max(saturation, 0), 1)
        let l = min(max(lightness, 0), 1)
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r1, g1, b1): (Float, Float, Float)
        switch Int(h * 6) {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        self.init(r: r1 + m, g: g1 + m, b: b1 + m, a: alpha)
    }

    // Semantic tokens live in Theme.swift so they resolve through
    // `Theme.current` rather than being frozen here.
}
