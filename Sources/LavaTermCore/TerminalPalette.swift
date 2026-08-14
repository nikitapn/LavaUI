/// Every colour LavaTerm draws. RGB tuples so this file stays in
/// `LavaTermCore` (no LavaUI). The app turns them into `Color` in one
/// place; change a number here and the grid, the window wash and the
/// chrome all follow.
///
/// `defaultBg` is the gray behind the glyphs. The window is that same
/// paper at `windowAlpha` — mostly solid, a little desktop through.
public enum TerminalPalette {
    public typealias RGB = (r: Float, g: Float, b: Float)

    /// Classic 16 ANSI colours (normal + bright), dark-terminal defaults.
    public static let ansi16: [RGB] = [
        // Normal
        (0.00, 0.00, 0.00),  // 0 black
        (0.80, 0.00, 0.00),  // 1 red
        (0.00, 0.80, 0.00),  // 2 green
        (0.80, 0.80, 0.00),  // 3 yellow
        (0.20, 0.40, 0.90),  // 4 blue
        (0.80, 0.00, 0.80),  // 5 magenta
        (0.00, 0.80, 0.80),  // 6 cyan
        (0.75, 0.75, 0.75),  // 7 white
        // Bright
        (0.40, 0.40, 0.40),  // 8
        (1.00, 0.30, 0.30),  // 9
        (0.30, 1.00, 0.30),  // 10
        (1.00, 1.00, 0.30),  // 11
        (0.40, 0.60, 1.00),  // 12
        (1.00, 0.40, 1.00),  // 13
        (0.30, 1.00, 1.00),  // 14
        (1.00, 1.00, 1.00),  // 15
    ]

    /// Ink when a cell has no explicit foreground.
    public static let defaultFg: RGB = (0.85, 0.87, 0.90)
    /// Paper when a cell has no explicit background. Also the window tint.
    public static let defaultBg: RGB = (0, 0, 0)
    /// Window wash over the desktop. 1 is a slab; 0 is a hole.
    ///
    /// Almost all of the useful range is above 0.98, which is not where a
    /// number like this normally lives. The compositor blends in linear light
    /// and then encodes to sRGB, and that curve is near-vertical at the
    /// bottom: over a wallpaper around 0.8, the desktop coming through reads
    /// as 0.27 at a=0.90 and still 0.17 at a=0.96 — a grey haze, not a tint.
    /// 0.99 lands near 0.07, which is the "little desktop through" this file
    /// has always claimed to describe.
    ///
    /// Anything picked before 2026-08-14 was tuned against a nested session
    /// running wlroots' GLES2 renderer, which blends the encoded values and
    /// so made every one of these look ~5x more solid than the desktop did.
    /// `dev-run` pins Vulkan now and the two agree; 0.9959 here would
    /// reproduce exactly what 0.96 used to look like nested.
    public static let windowAlpha: Float = 0.99
    /// Selection overlay, drawn on top of the cells.
    public static let selection: RGB = (0.35, 0.55, 0.85)
    public static let selectionAlpha: Float = 0.35
    /// Block caret fill.
    public static let cursor: RGB = (0.85, 0.88, 0.92)
    public static let cursorAlpha: Float = 0.45

    public static func rgb(for color: TerminalColor, isForeground: Bool) -> RGB {
        switch color {
        case .default:
            return isForeground ? defaultFg : defaultBg
        case .rgb(let r, let g, let b):
            return (Float(r) / 255, Float(g) / 255, Float(b) / 255)
        case .index(let idx):
            return rgb256(idx)
        }
    }

    public static func rgb256(_ index: UInt8) -> RGB {
        if index < 16 {
            return ansi16[Int(index)]
        }
        if index < 232 {
            // 6×6×6 colour cube
            let i = Int(index) - 16
            let r = i / 36
            let g = (i / 6) % 6
            let b = i % 6
            func level(_ n: Int) -> Float {
                n == 0 ? 0 : Float(55 + n * 40) / 255
            }
            return (level(r), level(g), level(b))
        }
        // Greyscale ramp 232…255
        let v = Float(8 + (Int(index) - 232) * 10) / 255
        return (v, v, v)
    }
}
