import LavaUI

enum PassLook {
    static let card = Color(rgb24: 0xf9_f4_ed)
    static let surface = Color(rgb24: 0xeb_dd_c5)
    static let well = Color(rgb24: 0xee_e7_db)
    static let faint = Color(rgb24: 0xdc_d3_c4)
    static let text = Color(rgb24: 0x20_1e_1d)
    static let soft = Color(rgb24: 0x47_42_38)
    static let muted = Color(rgb24: 0x64_5c_50)
    static let accent = Color(rgb24: 0xc6_71_39)
    static let peach = Color(rgb24: 0xff_e1_d0)
    static let peachHover = Color(rgb24: 0xff_c6_a5)
    static let orange = Color(rgb24: 0x8c_49_1a)
    static let brown = Color(rgb24: 0x64_33_12)
    static let sage = Color(rgb24: 0x7a_8a_5e)
    static let sagePale = Color(rgb24: 0xe1_ee_cc)
    static let sageInk = Color(rgb24: 0x3d_47_2b)
    static let divider = text.opacity(0.16)

    static var theme: Theme {
        var theme = Theme.paper
        theme.background = card
        theme.panel = surface
        theme.inset = card
        theme.hover = well
        theme.selectionFill = peach
        theme.textPrimary = text
        theme.textSecondary = soft
        theme.textMuted = muted
        theme.textDim = muted
        theme.accent = accent
        theme.border = divider
        theme.cornerRadius = 18
        return theme
    }
}

struct PassFonts {
    let body: UIFont?
    let strong: UIFont?
    let caption: UIFont?
    let kicker: UIFont?
    let hero: UIFont?
    let heading: UIFont?
    let detail: UIFont?

    init(editor: Editor) {
        func face(_ name: String, _ size: Float, spacing: Float = 0) -> UIFont? {
            guard let path = BundledFont.path(name),
                  let font = UIFont(path: path, pixelSize: size, letterSpacing: spacing),
                  font.registerWithEngine(editor)
            else { return nil }
            if let base = FontStore.default {
                let paths = [base.path] + base.fallbacks.map(\.path)
                font.useFallbacks(paths.map { FontFallback(path: $0, pixelSize: size) }, into: editor)
            }
            return font
        }

        body = face("Figtree-Regular", 14)
        strong = face("Figtree-SemiBold", 14)
        caption = face("Figtree-Regular", 12)
        kicker = face("Figtree-Bold", 11, spacing: 0.1)
        hero = face("Caprasimo-Regular", 30)
        heading = face("Caprasimo-Regular", 22)
        detail = face("Caprasimo-Regular", 24)
    }
}
