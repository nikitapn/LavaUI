import LavaUI
import LavaTermCore

/// `Color` views of `TerminalPalette`. The numbers live in the core
/// enum; this is just the LavaUI wrapping so a cell, the window wash
/// and the caret cannot drift apart.
extension TerminalPalette {
    static var terminalFill: Color { color(defaultBg, a: windowAlpha) }
    static var selectionFill: Color { color(selection, a: selectionAlpha) }
    static var cursorFill: Color { color(cursor, a: cursorAlpha) }

    static func color(_ rgb: RGB, a: Float = 1) -> Color {
        Color(r: rgb.r, g: rgb.g, b: rgb.b, a: a)
    }
}
