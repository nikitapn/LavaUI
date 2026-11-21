import Foundation
import LavaEditorSettings
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

struct EditorFonts {
    private(set) var document: UIFont?
    private(set) var documentBold: UIFont?
    let tab: UIFont?
    let tabSelected: UIFont?
    let status: UIFont?
    let statusEmphasis: UIFont?

    init(editor: Editor?) {
        tab = Self.load(BundledFont.path("Figtree-Regular"), size: 14, editor: editor)
        tabSelected = Self.load(BundledFont.path("Figtree-SemiBold"), size: 14, editor: editor)
        status = Self.load(BundledFont.path("Figtree-Regular"), size: 13, editor: editor)
        statusEmphasis = Self.load(BundledFont.path("Figtree-SemiBold"), size: 13, editor: editor)
    }

    mutating func updateDocument(_ settings: EditorPreferences, editor: Editor?) -> String? {
        guard let editor else { return nil }
        let catalog = FontCatalog.installed
        func load(_ path: String?, index: UInt32 = 0) -> UIFont? {
            Self.load(path, size: settings.fontSize, faceIndex: index,
                      lineHeight: settings.lineHeight, editor: editor)
        }
        func loadFace(_ family: String, style: FontStyle) -> UIFont? {
            guard let face = catalog.resolveFace(family: family, style: style) else { return nil }
            return load(face.path, index: face.index)
        }
        func faces(_ family: String) -> (UIFont, UIFont)? {
            guard let regular = loadFace(family, style: .regular),
                  let bold = loadFace(family, style: .bold) else { return nil }
            return (regular, bold)
        }

        let requested = settings.fontFamily
        if let (regular, bold) = faces(requested) {
            document = regular
            documentBold = bold
            return nil
        }

        let fallback = EditorPreferences.defaults.fontFamily
        if requested.caseInsensitiveCompare(fallback) != .orderedSame,
           let (regular, bold) = faces(fallback) {
            document = regular
            documentBold = bold
            return "Could not load font family '\(requested)'. Using '\(fallback)'."
        }
        document = load(BundledFont.path("Figtree-Regular"))
        documentBold = load(BundledFont.path("Figtree-Bold"))
        return "Could not load font family '\(requested)'. Using bundled Figtree."
    }

    private static func load(
        _ path: String?, size: Float, faceIndex: UInt32 = 0, lineHeight: Float? = nil, editor: Editor?
    ) -> UIFont? {
        guard let editor, let path,
              let font = UIFont(path: path, pixelSize: size, faceIndex: faceIndex, lineHeightMultiple: lineHeight),
              font.registerWithEngine(editor) else { return nil }

        if let base = FontStore.default {
            let paths = [base.path] + base.fallbacks.map(\.path)
            font.useFallbacks(paths.map { FontFallback(path: $0, pixelSize: size) }, into: editor)
        }
        return font
    }
}
