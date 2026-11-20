import Foundation
import LavaExplorerCore
import LavaUI

/// The explorer's colours: `File Explorer.dc.html` (the `organic` design
/// system) exactly on the paper theme it was drawn for, and the nearest theme
/// roles anywhere else, so a dark desktop gets a dark explorer.
struct ExplorerLook {
    /// The window, and the sidebar on it: `--color-surface`.
    var surface: Color
    /// A pane's card, the active tab, the profile pill: `--color-neutral-100`.
    var card: Color
    /// The address bar, a row under the pointer: `--color-neutral-200`.
    var well: Color
    /// A button under the pointer; the selection in a pane that is not
    /// active: `--color-neutral-300`.
    var press: Color
    /// The address bar's separators, an inactive tab's folder.
    var faint: Color
    var text: Color
    /// Dates, sizes, captions: `--color-neutral-700`.
    var soft: Color
    /// The toolbar's glyphs: `--color-neutral-800`.
    var icon: Color
    var divider: Color

    var accent: Color
    var accentHover: Color
    var onAccent: Color
    /// The selection in the active pane, the place being shown.
    var accent200: Color
    /// The active pane's outline.
    var accent300: Color
    var accent400: Color
    /// A folder the desktop knows by name (Documents, Downloads…).
    var accent600: Color
    var accent700: Color
    var accent800: Color
    var accent100: Color

    var sage: Color
    var sage100: Color
    var sage200: Color
    /// An ordinary folder.
    var sage600: Color
    var sage800: Color

    static var current: ExplorerLook { ExplorerLook(theme: Theme.current) }

    init(theme: Theme) {
        if theme == .paper {
            surface = Color(rgb24: 0xeb_dd_c5)
            card = Color(rgb24: 0xf9_f4_ed)
            well = Color(rgb24: 0xee_e7_db)
            press = Color(rgb24: 0xdc_d3_c4)
            faint = Color(rgb24: 0xa1_97_86)
            text = Color(rgb24: 0x20_1e_1d)
            soft = Color(rgb24: 0x64_5c_50)
            icon = Color(rgb24: 0x47_42_38)
            divider = Color(rgb24: 0x20_1e_1d).opacity(0.16)
            accent = Color(rgb24: 0xc6_71_39)
            accentHover = Color(rgb24: 0xb2_62_2d)
            onAccent = Color(rgb24: 0xf9_f4_ed)
            accent100 = Color(rgb24: 0xff_f2_eb)
            accent200 = Color(rgb24: 0xff_e1_d0)
            accent300 = Color(rgb24: 0xff_c6_a5)
            accent400 = Color(rgb24: 0xf6_a0_6b)
            accent600 = Color(rgb24: 0xb2_62_2d)
            accent700 = Color(rgb24: 0x8c_49_1a)
            accent800 = Color(rgb24: 0x64_33_12)
            sage = Color(rgb24: 0x7a_8a_5e)
            sage100 = Color(rgb24: 0xf0_fa_e1)
            sage200 = Color(rgb24: 0xe1_ee_cc)
            sage600 = Color(rgb24: 0x72_81_57)
            sage800 = Color(rgb24: 0x3d_47_2b)
            return
        }
        let light = theme.background.r * 0.2126 + theme.background.g * 0.7152
            + theme.background.b * 0.0722 > 0.5
        surface = theme.panel
        card = theme.background
        well = theme.inset
        press = theme.hover
        faint = theme.textDim
        text = theme.textPrimary
        soft = theme.textSecondary
        icon = theme.textSecondary
        divider = theme.textPrimary.opacity(0.16)
        accent = theme.accent
        accentHover = theme.accent.opacity(0.85)
        onAccent = theme.background
        accent100 = theme.selectionFill.opacity(0.4)
        accent200 = theme.selectionFill
        accent300 = theme.accent.opacity(0.6)
        accent400 = theme.accent.opacity(0.8)
        accent600 = theme.accent
        accent700 = light ? theme.selected : theme.accent
        accent800 = light ? theme.selected : theme.textPrimary
        let sageBase = Color(rgb24: 0x7a_8a_5e)
        sage = sageBase
        sage100 = sageBase.opacity(light ? 0.18 : 0.22)
        sage200 = sageBase.opacity(light ? 0.3 : 0.35)
        sage600 = light ? sageBase : Color(rgb24: 0x9c_ad_7e)
        sage800 = light ? Color(rgb24: 0x3d_47_2b) : Color(rgb24: 0xcc_db_b2)
    }
}

/// Figtree throughout, Caprasimo where the design sets a display line. Loaded
/// once, after the editor exists.
struct ExplorerFonts {
    /// Rows, places, tabs: 14px.
    let body: UIFont
    let bodySemi: UIFont
    /// Sizes and dates, figures that keep their width: 14px.
    let bodyTabular: UIFont
    /// The address bar: 13px.
    let crumb: UIFont
    let crumbSemi: UIFont
    /// The status bar and its pills.
    let status: UIFont
    let statusSemi: UIFont
    /// A device's mount point under its name; a pane's footer.
    let caption: UIFont
    let captionTabular: UIFont
    /// Section headings and column titles: 11px bold, spaced, upper case.
    let kicker: UIFont
    let tag: UIFont
    /// The profile's initial.
    let display14: UIFont
    /// "Nothing here yet".
    let display18: UIFont

    static func load(into editor: Editor) -> ExplorerFonts? {
        func face(_ file: String, _ size: Float, features: [String] = [],
                  letterSpacing: Float = 0) -> UIFont? {
            guard let path = BundledFont.path(file),
                  let font = UIFont(path: path, pixelSize: size, features: features,
                                    letterSpacing: letterSpacing)
            else { return nil }
            font.registerWithEngine(editor)
            // File names come in every script there is.
            if let base = FontStore.default {
                let paths = [base.path] + base.fallbacks.map(\.path)
                font.useFallbacks(paths.map { FontFallback(path: $0, pixelSize: size) },
                                  into: editor)
            }
            return font
        }
        guard let body = face("Figtree-Regular", 14),
              let bodySemi = face("Figtree-SemiBold", 14),
              let bodyTabular = face("Figtree-Regular", 14, features: ["tnum"]),
              let crumb = face("Figtree-Regular", 13),
              let crumbSemi = face("Figtree-SemiBold", 13),
              let status = face("Figtree-Regular", 13),
              let statusSemi = face("Figtree-SemiBold", 13),
              let caption = face("Figtree-Regular", 12),
              let captionTabular = face("Figtree-Regular", 12, features: ["tnum"]),
              let kicker = face("Figtree-Bold", 11, letterSpacing: 0.1),
              let tag = face("Figtree-Regular", 11, letterSpacing: 0.02),
              let display14 = face("Caprasimo-Regular", 14),
              let display18 = face("Caprasimo-Regular", 18)
        else { return nil }
        return ExplorerFonts(
            body: body, bodySemi: bodySemi, bodyTabular: bodyTabular,
            crumb: crumb, crumbSemi: crumbSemi, status: status, statusSemi: statusSemi,
            caption: caption, captionTabular: captionTabular, kicker: kicker, tag: tag,
            display14: display14, display18: display18)
    }
}

nonisolated(unsafe) var explorerFonts: ExplorerFonts?

/// The design's glyphs: SVG path data on a 24-unit grid.
enum ExplorerGlyphs {
    static let folder = "M3 7a2 2 0 0 1 2-2h4.2l2 2.2H19a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"
    static let page = "M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7ZM14 2v4a2 2 0 0 0 2 2h4"
    static let home = "M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1Z"
    static let desktop = "M3 4h18v12H3zM8 20h8M12 16v4"
    static let docs = "M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7ZM14 2v4a2 2 0 0 0 2 2h4M8 13h8M8 17h5"
    static let down = "M12 3v12M7 10l5 5 5-5M5 21h14"
    static let pictures = "M3 5h18v14H3zM3 16l5-5 4 4 3-3 6 6M15.5 8.5h.01"
    static let music = "M9 18V5l12-2v13M9 18a3 3 0 1 1-6 0 3 3 0 0 1 6 0ZM21 16a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"
    static let videos = "M2 6h14v12H2zM16 10l6-4v12l-6-4Z"
    static let computer = "M2 4h20v12H2zM6 20h12"
    static let trash = "M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14"
    static let star = "M12 2l3.09 6.26L22 9.27l-5 4.87 1.18 6.88L12 17.77l-6.18 3.25L7 14.14 2 9.27l6.91-1.01Z"
    static let drive = "M22 12H2M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11ZM6 16h.01M10 16h.01"
    static let server = "M3 3h18v8H3zM3 13h18v8H3zM7 7h.01M7 17h.01"
    static let eject = "M12 5 5 13h14ZM5 19h14"
    static let cross = "M18 6 6 18M6 6l12 12"
    static let plus = "M12 5v14M5 12h14"
    static let chevronRight = "m9 6 6 6-6 6"
    static let chevronDown = "m6 9 6 6 6-6"
    static let back = "M19 12H5M12 19l-7-7 7-7"
    static let forward = "M5 12h14M12 5l7 7-7 7"
    static let up = "M12 19V5M5 12l7-7 7 7"
    static let newFolder = "M3 7a2 2 0 0 1 2-2h4.2l2 2.2H19a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2ZM12 11v6M9 14h6"
    static let list = "M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"
    static let grid = "M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z"
    static let eye = "M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12ZM12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6Z"
    static let columns = "M3 4h18v16H3zM12 4v16"

    /// A place in the sidebar, by the theme name the list uses for it.
    static func place(_ place: Place) -> String {
        switch FileIcon.folder(place.path).first?.name ?? "folder" {
        case "user-home": return home
        case "user-desktop": return desktop
        case "folder-documents": return docs
        case "folder-download": return down
        case "folder-pictures": return pictures
        case "folder-music": return music
        case "folder-videos": return videos
        case "drive-harddisk": return computer
        case "user-trash": return trash
        default: return folder
        }
    }

    /// What a file is, for the mark drawn inside its page and the colour of it.
    enum Kind {
        case text, font, image, audio, video, archive, code

        /// The mark inside the page outline.
        var mark: String {
            switch self {
            case .text: return "M8 13h8M8 17h6"
            case .font: return "M9 18l3-8 3 8M10 16h4"
            case .image: return "M8 18l2.5-3.5 2 2.5 1.5-2 2 3"
            case .audio: return "M11 17.5a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0Zm0 0V12l5-1v5"
            case .video: return "M10 12v6l5-3Z"
            case .archive: return "M12 9v1M12 12v1M12 15v1M11 18h2v2h-2Z"
            case .code: return "m10 13-2 2 2 2M14 13l2 2-2 2"
            }
        }

        /// The tag after the name, for the kinds the design marks.
        var tag: String? { self == .font ? "font" : nil }
    }

    /// By the icon theme's generic name for it, which the core already works
    /// out from the extension.
    static func kind(_ entry: FileEntry) -> Kind {
        let names = FileIcon.candidates(for: entry).map(\.name)
        if names.contains("font-x-generic") { return .font }
        if names.contains("image-x-generic") { return .image }
        if names.contains("audio-x-generic") { return .audio }
        if names.contains("video-x-generic") { return .video }
        if names.contains("package-x-generic") { return .archive }
        if names.contains(where: { $0.hasPrefix("text-x-") && $0 != "text-x-generic" })
            || names.contains("text-html") || names.contains("application-x-executable")
        {
            return .code
        }
        return .text
    }

    /// A folder the desktop knows by name — drawn in the accent, where an
    /// ordinary one is sage.
    static func isSpecialFolder(_ entry: FileEntry) -> Bool {
        guard entry.isDirectory else { return false }
        let name = FileIcon.folder(entry.path).first?.name ?? "folder"
        return name != "folder"
    }
}
