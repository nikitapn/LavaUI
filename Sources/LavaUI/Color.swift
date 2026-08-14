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

    /// From hue (turns, 0…1), saturation and *value* — the square a colour
    /// picker draws. Distinct from `hue:saturation:lightness:`: value is
    /// the brightest channel, so the top-right of the square is the pure
    /// hue rather than a pastel, which is what the hand expects to land on.
    ///
    /// Same authored sRGB as `r`/`g`/`b`. A picker that used linear
    /// components here would disagree with the hex it prints.
    public init(hue: Float, saturation: Float, value: Float, alpha: Float = 1) {
        let h = hue - hue.rounded(.down)
        let s = min(max(saturation, 0), 1)
        let v = min(max(value, 0), 1)
        let c = v * s
        let x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
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

    /// Hue / saturation / value of these authored components.
    ///
    /// Hue is undefined (and returned as 0) when the colour is grey.
    /// A picker that has to keep the strip still while the user drags
    /// through white should remember the last non-zero hue itself.
    public var hsv: (hue: Float, saturation: Float, value: Float) {
        let maxc = max(r, max(g, b))
        let minc = min(r, min(g, b))
        let d = maxc - minc
        let value = maxc
        let saturation = maxc > 0 ? d / maxc : 0
        var hue: Float = 0
        if d > 1e-6 {
            if maxc == r {
                hue = (g - b) / d + (g < b ? 6 : 0)
            } else if maxc == g {
                hue = (b - r) / d + 2
            } else {
                hue = (r - g) / d + 4
            }
            hue /= 6
        }
        return (hue, saturation, value)
    }

    /// `#rrggbb` when opaque, `#rrggbbaa` otherwise. The bytes a picker
    /// and a CSS author share.
    public var hex: String {
        let R = Int((r * 255).rounded())
        let G = Int((g * 255).rounded())
        let B = Int((b * 255).rounded())
        let A = Int((a * 255).rounded())
        if A >= 255 {
            return String(format: "#%02X%02X%02X", R, G, B)
        }
        return String(format: "#%02X%02X%02X%02X", R, G, B, A)
    }

    /// Reads `#rgb`, `#rrggbb`, `#rrggbbaa`, with or without the hash.
    /// Nil if the string is not one of those — including a half-typed field.
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        let expand: (Int) -> Float = { nibble in
            Float(nibble << 4 | nibble) / 255
        }
        let pair: (Int, Int) -> Float = { hi, lo in
            Float((hi << 4) | lo) / 255
        }
        func nibble(_ i: Int) -> Int? {
            Int(String(digits[digits.index(digits.startIndex, offsetBy: i)]), radix: 16)
        }
        switch digits.count {
        case 3:
            // CSS #rgb. Four digits is almost always a half-typed #rrggbb,
            // not #rgba, so it is rejected rather than parsed as alpha 0.
            guard let r = nibble(0), let g = nibble(1), let b = nibble(2) else { return nil }
            self.init(r: expand(r), g: expand(g), b: expand(b), a: 1)
        case 6, 8:
            guard let rH = nibble(0), let rL = nibble(1),
                  let gH = nibble(2), let gL = nibble(3),
                  let bH = nibble(4), let bL = nibble(5) else { return nil }
            let a: Float
            if digits.count == 8 {
                guard let aH = nibble(6), let aL = nibble(7) else { return nil }
                a = pair(aH, aL)
            } else {
                a = 1
            }
            self.init(r: pair(rH, rL), g: pair(gH, gL), b: pair(bH, bL), a: a)
        default:
            return nil
        }
    }

    /// Packed `0x00RRGGBB`, the compositor wallpaper spelling. Alpha is
    /// dropped on the way out and assumed opaque on the way in.
    public var rgb24: UInt32 {
        let R = UInt32(clamping: Int((r * 255).rounded()))
        let G = UInt32(clamping: Int((g * 255).rounded()))
        let B = UInt32(clamping: Int((b * 255).rounded()))
        return (R << 16) | (G << 8) | B
    }

    public init(rgb24: UInt32, alpha: Float = 1) {
        self.init(
            r: Float((rgb24 >> 16) & 0xff) / 255,
            g: Float((rgb24 >> 8) & 0xff) / 255,
            b: Float(rgb24 & 0xff) / 255,
            a: alpha
        )
    }

    // Semantic tokens live in Theme.swift so they resolve through
    // `Theme.current` rather than being frozen here.
}
