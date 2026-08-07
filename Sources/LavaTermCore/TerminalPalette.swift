/// xterm 256-colour palette helpers (pure data, no UI).
public enum TerminalPalette {
    /// Classic 16 ANSI colours (normal + bright), dark-terminal defaults.
    public static let ansi16: [(r: Float, g: Float, b: Float)] = [
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

    public static let defaultFg: (r: Float, g: Float, b: Float) = (0.85, 0.87, 0.90)
    public static let defaultBg: (r: Float, g: Float, b: Float) = (0.08, 0.09, 0.11)

    public static func rgb(for color: TerminalColor, isForeground: Bool) -> (r: Float, g: Float, b: Float) {
        switch color {
        case .default:
            return isForeground ? defaultFg : defaultBg
        case .rgb(let r, let g, let b):
            return (Float(r) / 255, Float(g) / 255, Float(b) / 255)
        case .index(let idx):
            return rgb256(idx)
        }
    }

    public static func rgb256(_ index: UInt8) -> (r: Float, g: Float, b: Float) {
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
