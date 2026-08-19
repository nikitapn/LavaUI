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
    /// **This is not "1 - a of the desktop shows through", and it is not a
    /// number to derive.** Tune it by eye against a real wallpaper.
    ///
    /// It was briefly changed to 0.93 on 2026-08-19, on the reasoning that
    /// the move to sRGB blending made show-through equal `1 - a`, so 0.93
    /// would reproduce the ~7% that 0.99 gave under linear blending. On the
    /// desktop that came out far too transparent, because two things the
    /// arithmetic left out:
    ///
    /// - **The frost is a second wash.** `WindowBackdrop.blur` puts a tint at
    ///   alpha 0.42 under this one, and the compositor's blur composite has
    ///   its own alpha again. What reaches the eye is a stack, not `1 - a`.
    /// - **The old leak was not a flat percentage.** Under linear blending
    ///   what came through depended on how bright the pixel behind was —
    ///   highlights leaked several times more than shadows. Over a photo that
    ///   reads as "a few bright things show"; a uniform leak of the same
    ///   average reads as "the whole wallpaper shows". No single constant
    ///   reproduces the old look, because the old look was not a constant.
    ///
    /// Back at 0.99, which is what the desktop was tuned against and still
    /// looks right. See `docs/colour-and-blending.md`.
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
