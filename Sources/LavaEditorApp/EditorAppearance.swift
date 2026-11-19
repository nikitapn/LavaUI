import Foundation
import LavaUI

struct EditorAppearance {
    let theme: Theme
    let usesPaper: Bool

    init(theme: Theme) {
        usesPaper = theme == .paper
        var colors = theme
        if usesPaper {
            colors.textPrimary = Color(rgb24: 0x20_1e_1d)
            colors.textSecondary = Color(rgb24: 0x64_5c_50)
            colors.textMuted = Color(rgb24: 0x82_79_6a)
            colors.textDim = Color(rgb24: 0xa1_97_86)
            colors.accent = Color(rgb24: 0x8c_49_1a)
            colors.panel = Color(rgb24: 0xeb_dd_c5)
            colors.inset = Color(rgb24: 0xf9_f4_ed)
            colors.hover = Color(rgb24: 0xdc_d3_c4)
            colors.selectionFill = Color(rgb24: 0xff_e1_d0)
            colors.border = Color(rgb24: 0xcb_be_aa)
        }
        self.theme = colors
    }

    var currentLine: Color { usesPaper ? Color(rgb24: 0xff_f2_eb) : theme.canvas }
    var modified: Color { usesPaper ? Color(rgb24: 0xc6_71_39) : theme.accent }
    var thumb: Color { usesPaper ? Color(rgb24: 0xdc_d3_c4) : theme.border }
    var languageFill: Color { usesPaper ? Color(rgb24: 0xf0_fa_e1) : theme.canvas }
    var languageText: Color { usesPaper ? Color(rgb24: 0x3d_47_2b) : theme.textPrimary }

    var windowControls: WindowControlsStyle {
        guard usesPaper else { return WindowControlsStyle(size: 13) }
        return WindowControlsStyle(
            size: 13,
            close: Color(rgb24: 0xc6_71_39), minimize: Color(rgb24: 0xf6_a0_6b),
            maximize: Color(rgb24: 0x7a_8a_5e)
        )
    }

    var documentTheme: Theme {
        var document = theme
        document.controlPadding = 8
        return document
    }
}

/// Figtree's faces are bundled with LavaUI so this window uses the same type in both hosts.
struct EditorFonts {
    static let documentSize: Float = 17

    let document: UIFont?
    let documentBold: UIFont?
    let tab: UIFont?
    let tabSelected: UIFont?
    let status: UIFont?
    let statusEmphasis: UIFont?

    init(editor: Editor?) {
        document = Self.load("Regular", size: Self.documentSize, document: true, editor: editor)
        documentBold = Self.load("Bold", size: Self.documentSize, document: true, editor: editor)
        tab = Self.load("Regular", size: 14, editor: editor)
        tabSelected = Self.load("SemiBold", size: 14, editor: editor)
        status = Self.load("Regular", size: 13, editor: editor)
        statusEmphasis = Self.load("SemiBold", size: 13, editor: editor)
    }

    static func load(
        _ weight: String, size: Float, document: Bool = false, editor: Editor?
    ) -> UIFont? {
        guard let editor,
              let path = BundledFont.path("Figtree-\(weight)"),
              let font = UIFont(path: path, pixelSize: size,
                                lineHeightMultiple: document ? 1.75 : nil),
              font.registerWithEngine(editor)
        else { return nil }

        if let base = FontStore.default {
            let paths = [base.path] + base.fallbacks.map(\.path)
            font.useFallbacks(paths.map { FontFallback(path: $0, pixelSize: size) }, into: editor)
        }
        return font
    }
}
