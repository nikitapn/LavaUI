import Foundation
import LavaUI

/// The menu's colours: `Taskbar.dc.html`'s menus on the paper theme it was
/// drawn for, and the nearest theme roles anywhere else, so a dark desktop
/// gets a dark plate rather than a cream one.
struct MenuLook {
    /// The plate's glass, over the compositor's frost: the design's
    /// `glassBgStrong`, tuned by eye like the panel's cards (surfaces blend
    /// in linear light; see docs/colour-and-blending.md).
    var glass: Color
    /// The plate's 1px rim.
    var rim: Color
    var text: Color
    /// Glyphs, shortcuts and captions: `--color-neutral-800`.
    var soft: Color
    /// A submenu's chevron: `--color-neutral-700`.
    var chevron: Color
    /// The row under the pointer: `--color-accent-200`.
    var hover: Color
    /// The tick on a checked row: `--color-accent-700`.
    var check: Color
    var divider: Color

    static var current: MenuLook { MenuLook(theme: Theme.current) }

    init(theme: Theme) {
        if theme == .paper {
            glass = Color(rgb24: 0xf9_f4_ed).opacity(0.62)
            rim = Color(r: 1, g: 1, b: 1, a: 0.6)
            text = Color(rgb24: 0x20_1e_1d)
            soft = Color(rgb24: 0x47_42_38)
            chevron = Color(rgb24: 0x64_5c_50)
            hover = Color(rgb24: 0xff_e1_d0)
            check = Color(rgb24: 0x8c_49_1a)
            divider = Color(rgb24: 0x20_1e_1d).opacity(0.16)
            return
        }
        let light = theme.background.luminance > 0.5
        glass = theme.panel.opacity(light ? 0.62 : 0.75)
        rim = Color(r: 1, g: 1, b: 1, a: light ? 0.6 : 0.12)
        text = theme.textPrimary
        soft = theme.textSecondary
        chevron = theme.textDim
        hover = theme.selectionFill
        check = light ? theme.selected : theme.accent
        divider = theme.textPrimary.opacity(0.16)
    }

    /// Figtree, as the design's menus are set. Loaded once at start-up: a
    /// face built in `body` would reopen FreeType on every menu.
    struct Fonts {
        /// A row's title: 14px.
        let row: UIFont
        /// The shortcut beside it: 12px.
        let shortcut: UIFont
        /// A caption over a group of rows: 11px bold, spaced, upper case.
        let kicker: UIFont

        static func load(into editor: Editor) -> Fonts? {
            func face(_ file: String, _ size: Float, letterSpacing: Float = 0) -> UIFont? {
                guard let path = BundledFont.path(file),
                      let font = UIFont(path: path, pixelSize: size,
                                        letterSpacing: letterSpacing)
                else { return nil }
                font.registerWithEngine(editor)
                // Titles come from other programs — a window's, an app's
                // menu — in whatever script they were written in.
                if let base = FontStore.default {
                    let paths = [base.path] + base.fallbacks.map(\.path)
                    font.useFallbacks(paths.map { FontFallback(path: $0, pixelSize: size) },
                                      into: editor)
                }
                return font
            }
            guard let row = face("Figtree-Regular", 14),
                  let shortcut = face("Figtree-Regular", 12),
                  let kicker = face("Figtree-Bold", 11, letterSpacing: 0.1)
            else { return nil }
            return Fonts(row: row, shortcut: shortcut, kicker: kicker)
        }
    }

    // The design's numbers.
    static let plateRadius: Float = 18
    static let platePadding: Float = 6
    static let rowRadius: Float = 12
    /// 7px round a 21px CSS line; Figtree sets 14px 17px tall, so 9.
    static let rowPadding = EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10)
    /// Between a row's glyph column, its title and what follows.
    static let rowGap: Float = 10
    static let iconColumn: Float = 18
    static let iconSize: Float = 16
    static let iconStroke: Float = 2.25
    /// Blur and saturation of the frost: the panel's cards'.
    static let blur: Float = 22
    static let saturation: Float = 1.7

    static let checkGlyph = "M20 6 9 17l-5-5"
    static let chevronGlyph = "m9 6 6 6-6 6"
}

nonisolated(unsafe) var menuFonts: MenuLook.Fonts?
