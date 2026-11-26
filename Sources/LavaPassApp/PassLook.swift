import LavaUI

struct PassLook {
    let theme: Theme
    let isPaper: Bool

    // Vault.dc.html uses the warm neutral, orange and olive ramps on Paper.
    private static let orange = Color(rgb24: 0xc6_71_39)
    private static let orangeInk = Color(rgb24: 0x8c_49_1a)
    private static let orangeDark = Color(rgb24: 0x64_33_12)
    private static let peach = Color(rgb24: 0xff_e1_d0)
    private static let peachHover = Color(rgb24: 0xff_c6_a5)
    private static let sage = Color(rgb24: 0x7a_8a_5e)

    init(system: Theme) {
        isPaper = system == .paper
        var theme = system
        if isPaper {
            theme.background = Color(rgb24: 0xf9_f4_ed)
            theme.panel = Color(rgb24: 0xeb_dd_c5)
            theme.inset = theme.background
            theme.canvas = Color(rgb24: 0xee_e7_db)
            theme.hover = theme.canvas
            theme.selectionFill = Self.peach
            theme.textPrimary = Color(rgb24: 0x20_1e_1d)
            theme.textSecondary = Color(rgb24: 0x47_42_38)
            theme.textMuted = Color(rgb24: 0x64_5c_50)
            theme.textDim = theme.textMuted
            theme.accent = Self.orange
            theme.selected = Self.orangeInk
            theme.border = theme.textPrimary.opacity(0.16)
            theme.cornerRadius = 18
        }
        self.theme = theme
    }

    var accentInk: Color { isPaper ? Self.orangeInk : theme.accent }
    var emphasisInk: Color { isPaper ? Self.orangeDark : theme.textPrimary }
    var warmHover: Color { isPaper ? Self.peachHover : theme.hover }
    var success: Color { isPaper ? Self.sage : theme.accent }
    var successFill: Color { isPaper ? Color(rgb24: 0xe1_ee_cc) : theme.inset }
    var successInk: Color { isPaper ? Color(rgb24: 0x3d_47_2b) : theme.accent }
    var subtleBorder: Color { isPaper ? Color(rgb24: 0xdc_d3_c4) : theme.border }
    var recentSelectionFill: Color { isPaper ? Color(rgb24: 0xff_f2_eb) : theme.selectionFill }
    var recentSelectionBorder: Color { isPaper ? Self.peachHover : .clear }

    var windowControls: WindowControlsStyle {
        if isPaper {
            return WindowControlsStyle(size: 13, close: Self.orange,
                                       minimize: Color(rgb24: 0xf6_a0_6b), maximize: Self.sage)
        }
        var style = WindowControlsStyle.monochrome(size: 13, color: theme.textSecondary)
        style.glyphOnHoverOnly = true
        return style
    }
}
