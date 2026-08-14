import Foundation

/// sRGB colour with alpha. Components are what a colour picker shows —
/// `Color(r: 0.5, g: 0, b: 0)` is `#800000`, and that is what the swapchain
/// should present. The engine linearises at the vertex stage so the sRGB
/// attachment does not encode the value a second time.
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

    /// Pack as authored sRGB RGBA8 (R in the low byte). The renderer decodes
    /// to linear; do not pre-linearise here or the attachment encodes twice.
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

    /// This colour with the sRGB curve removed — components proportional to
    /// light rather than to perceived brightness.
    ///
    /// Needed wherever colours are *multiplied* rather than merely carried:
    /// a light times a surface, a fade times a fill. Doing that arithmetic on
    /// authored components is the classic error — it looks like a dimming
    /// that is simply too strong, because halving an encoded value takes far
    /// more than half the light out. See `docs/colour-and-blending.md`.
    ///
    /// Not what to hand to the renderer: the wire format is authored sRGB and
    /// the vertex stage linearises. Convert back with `fromLinear` first.
    /// Alpha is a coverage fraction, not light, and is carried through.
    public var linear: Color {
        func f(_ c: Float) -> Float {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return Color(r: f(r), g: f(g), b: f(b), a: a)
    }

    /// The inverse of `linear`: re-applies the sRGB curve, so the result can
    /// be packed and sent like any authored colour. Clamps, because lighting
    /// arithmetic overshoots and 8-bit packing has nowhere to put it.
    public static func fromLinear(_ c: Color) -> Color {
        func f(_ v: Float) -> Float {
            let x = min(max(v, 0), 1)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return Color(r: f(c.r), g: f(c.g), b: f(c.b), a: min(max(c.a, 0), 1))
    }

    /// From hue (turns, 0…1 and wrapping), saturation and lightness.
    ///
    /// Here rather than at a call site because the useful thing about HSL is
    /// generating a *family* — a row of tints that vary in hue while holding
    /// saturation and lightness fixed, so they read as one set instead of as
    /// an argument. Doing that in RGB means picking every member by hand and
    /// getting the brightness subtly wrong on the ones near yellow.
    ///
    /// `lightness` is in the same space as `r`/`g`/`b`: authored sRGB, the
    /// numbers a colour picker shows. The engine linearises them before
    /// blending so they survive the swapchain encode unchanged.
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
