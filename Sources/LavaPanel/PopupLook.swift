import Foundation
import LavaUI

/// The rest of the design's palette, for the popups: neutrals and the second
/// (sage) accent, which the bar itself never needs. The design's values on
/// paper; the nearest theme role elsewhere.
struct PopupPalette {
    var bar: PanelPalette
    var neutral200: Color
    var neutral300: Color
    var neutral400: Color
    var neutral600: Color
    var neutral700: Color
    var accent100: Color
    var accent300: Color
    var accent700: Color
    var sage100: Color
    var sage200: Color
    var sage600: Color
    var sage700: Color
    var sage800: Color
    /// The card's rim.
    var rim: Color
    /// A row under the pointer.
    var rowHover: Color
    /// A slider's empty track.
    var track: Color

    static var current: PopupPalette { PopupPalette(theme: Theme.current) }

    init(theme: Theme) {
        bar = PanelPalette(theme: theme)
        if theme == .paper {
            neutral200 = Color(rgb24: 0xee_e7_db)
            neutral300 = Color(rgb24: 0xdc_d3_c4)
            neutral400 = Color(rgb24: 0xc0_b6_a5)
            neutral600 = Color(rgb24: 0x82_79_6a)
            neutral700 = Color(rgb24: 0x64_5c_50)
            accent100 = Color(rgb24: 0xff_f2_eb)
            accent300 = Color(rgb24: 0xff_c6_a5)
            accent700 = Color(rgb24: 0x8c_49_1a)
            sage100 = Color(rgb24: 0xf0_fa_e1)
            sage200 = Color(rgb24: 0xe1_ee_cc)
            sage600 = Color(rgb24: 0x72_81_57)
            sage700 = Color(rgb24: 0x56_63_3f)
            sage800 = Color(rgb24: 0x3d_47_2b)
            rim = Color(r: 1, g: 1, b: 1, a: 0.6)
            rowHover = Color(r: 1, g: 1, b: 1, a: 0.55)
            track = Color(rgb24: 0x20_1e_1d).opacity(0.18)
            return
        }
        let light = theme.background.luminance > 0.5
        neutral200 = theme.inset
        neutral300 = theme.hover
        neutral400 = theme.border
        neutral600 = theme.textDim
        neutral700 = theme.textMuted
        accent100 = theme.selectionFill.opacity(0.6)
        accent300 = theme.accent.opacity(0.5)
        accent700 = light ? theme.selected : theme.accent
        let sage = Color(rgb24: 0x7a_8a_5e)
        sage100 = sage.opacity(light ? 0.18 : 0.22)
        sage200 = sage.opacity(light ? 0.3 : 0.35)
        sage600 = sage
        sage700 = light ? sage.darkened(0.25) : sage.lightened(0.25)
        sage800 = light ? sage.darkened(0.45) : sage.lightened(0.45)
        rim = Color(r: 1, g: 1, b: 1, a: light ? 0.6 : 0.12)
        rowHover = Color(r: 1, g: 1, b: 1, a: light ? 0.55 : 0.08)
        track = theme.textPrimary.opacity(0.18)
    }
}

/// Every face the popups use. Loaded once, after the editor exists: a face
/// built in `body` would reopen FreeType on every clock tick.
struct PopupFonts {
    /// Caprasimo, for a calendar's month and a track's title.
    let heading18: UIFont
    let heading19: UIFont
    let heading22: UIFont
    let title15: UIFont
    let body14: UIFont
    let body14Semi: UIFont
    let body14Bold: UIFont
    let small13: UIFont
    let small13Semi: UIFont
    /// A level beside its slider: "25%", without the width shifting.
    let small13SemiTabular: UIFont
    let caption12: UIFont
    /// Times on a seek bar, ISO week numbers: figures that hold their width.
    let caption12Tabular: UIFont
    let week10: UIFont
    /// Spaced-out uppercase section labels: OUTPUT, DEVICES, VPN.
    let kicker: UIFont
    /// The weekday strip over a month: M T W T F S S.
    let weekday: UIFont
    let tag: UIFont

    static func load(into editor: Editor) -> PopupFonts? {
        func face(_ file: String, _ size: Float, features: [String] = [],
                  letterSpacing: Float = 0) -> UIFont? {
            guard let path = BundledFont.path(file),
                  let font = UIFont(path: path, pixelSize: size, features: features,
                                    letterSpacing: letterSpacing)
            else { return nil }
            font.registerWithEngine(editor)
            if let base = FontStore.default {
                let paths = [base.path] + base.fallbacks.map(\.path)
                font.useFallbacks(paths.map { FontFallback(path: $0, pixelSize: size) },
                                  into: editor)
            }
            return font
        }
        guard let heading18 = face("Caprasimo-Regular", 18),
              let heading19 = face("Caprasimo-Regular", 19),
              let heading22 = face("Caprasimo-Regular", 22),
              let title15 = face("Figtree-Bold", 15),
              let body14 = face("Figtree-Regular", 14),
              let body14Semi = face("Figtree-SemiBold", 14),
              let body14Bold = face("Figtree-Bold", 14),
              let small13 = face("Figtree-Regular", 13),
              let small13Semi = face("Figtree-SemiBold", 13),
              let small13SemiTabular = face("Figtree-SemiBold", 13, features: ["tnum"]),
              let caption12 = face("Figtree-Regular", 12),
              let caption12Tabular = face("Figtree-Regular", 12, features: ["tnum"]),
              let week10 = face("Figtree-Regular", 10.5, features: ["tnum"]),
              let kicker = face("Figtree-Bold", 11, letterSpacing: 0.1),
              let weekday = face("Figtree-Bold", 11, letterSpacing: 0.06),
              let tag = face("Figtree-Regular", 11, letterSpacing: 0.02)
        else { return nil }
        return PopupFonts(
            heading18: heading18, heading19: heading19, heading22: heading22,
            title15: title15, body14: body14, body14Semi: body14Semi,
            body14Bold: body14Bold, small13: small13, small13Semi: small13Semi,
            small13SemiTabular: small13SemiTabular,
            caption12: caption12, caption12Tabular: caption12Tabular, week10: week10,
            kicker: kicker, weekday: weekday, tag: tag)
    }
}

nonisolated(unsafe) var popupFonts: PopupFonts!

/// The card every popup is: a plate of stronger glass with a white rim and
/// round corners, frosted on its own rectangle so the frost takes the card's
/// corner rather than the window's.
///
/// An inner view, not the popup's root: a root's frost is the window's and
/// is cut to the desktop's corner radius, which is half the card's.
struct PopupCard<Content: View>: View {
    var padding: Float
    var content: Content

    static var radius: Float { 24 }

    init(padding: Float = 12, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        let palette = PopupPalette.current
        return VStack(flexGrow: 1, padding: 0, spacing: 0) {
            VStack(flexGrow: 1, padding: padding, spacing: 0) {
                content
            }
            .background(palette.bar.glassStrong)
            .border(palette.rim)
            .cornerRadius(Self.radius)
            .backdropBlur(radius: 22, adaptation: 0)
        }
    }
}

/// The design's controls, as LavaUI styles.
enum PopupStyles {
    /// 42×24, accent when on, the knob white either way.
    static func toggle(_ palette: PopupPalette) -> ToggleStyle {
        ToggleStyle(trackWidth: 42, trackHeight: 24, knobInset: 3,
                    offTrack: palette.neutral400, onTrack: palette.bar.accent,
                    knob: Color(r: 1, g: 1, b: 1), labelGap: 0, duration: 0.15)
    }

    /// A 6px track filled in the accent, under a white knob ringed in it.
    static func slider(_ palette: PopupPalette, width: Float) -> SliderStyle {
        var style = SliderStyle(
            trackWidth: width, trackThickness: 6, knobRadius: 8, knobHoverScale: 1.1,
            activeTrack: palette.bar.accent, inactiveTrack: palette.track,
            knob: palette.bar.onAccent, valueGap: 0, valueWidth: 0)
        style.knobRing = palette.bar.accent
        return style
    }
}

/// OUTPUT, DEVICES, VPN: a section's label.
struct Kicker: View {
    var text: String

    var body: some View {
        Text(text.uppercased(), color: PopupPalette.current.bar.textSoft, font: popupFonts.kicker)
            .padding(EdgeInsets(top: 0, leading: 8, bottom: 6, trailing: 8))
    }
}

/// A hairline across a card, between sections.
struct CardDivider: View {
    var body: some View {
        let color = PopupPalette.current.bar.divider
        return Canvas(label: "divider", width: .pct(100), height: .pt(1)) { list, frame in
            list.rect(x: frame.x, y: frame.y, w: frame.w, h: 1, color: color)
        }
    }
}

/// A glyph centred on a disc — a device, a network, a mute button.
struct IconDisc: View {
    var icon: [IconShape]
    var size: Float
    var glyph: Float
    var fill: Color
    var color: Color
    var strokeWidth: Float = 2.25

    var body: some View {
        HStack(width: .pt(size), height: .pt(size), padding: 0, alignment: .center) {
            Spacer()
            Icon(icon, size: glyph, color: color, strokeWidth: strokeWidth)
            Spacer()
        }
        .background(fill)
        .cornerRadius(size / 2)
    }
}

/// "Today", "Disconnect": an outlined pill on the card.
struct PillButton: View {
    var title: String
    var agentId: String
    var action: () -> Void

    var body: some View {
        let palette = PopupPalette.current
        return Text(title, color: palette.bar.accentInk, font: popupFonts.small13Semi,
                    hoverFill: palette.bar.accentSoft, onClick: action)
            .padding(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
            .background(palette.bar.onAccent)
            .border(palette.accent300)
            .cornerRadius(14)
            .cursor(.pointer)
            .agentId(agentId)
    }
}

/// "Playing", "16": a small rounded label.
struct TagLabel: View {
    enum Tone { case sage, neutral }
    var text: String
    var tone: Tone

    var body: some View {
        let palette = PopupPalette.current
        let fill = tone == .sage ? palette.sage100 : palette.bar.onAccent
        let ink = tone == .sage ? palette.sage800 : palette.bar.textSoft
        return Text(text, color: ink, font: popupFonts.tag)
            .padding(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
            .background(fill)
            .cornerRadius(12)
    }
}

/// A round button holding one glyph, for a card: chevrons, transport, forget.
struct CardIconButton: View {
    var icon: [IconShape]
    var size: Float
    var glyph: Float
    var color: Color
    var hover: Color
    var fill: Color = .clear
    var strokeWidth: Float = 2.75
    var agentId: String
    var action: () -> Void

    var body: some View {
        HStack(width: .pt(size), height: .pt(size), padding: 0, alignment: .center,
               onClick: action) {
            Spacer()
            Icon(icon, size: glyph, color: color, strokeWidth: strokeWidth)
            Spacer()
        }
        .background(fill)
        .hoverBackground(hover)
        .cornerRadius(size / 2)
        .cursor(.pointer)
        .agentId(agentId)
    }
}

/// More of the design's glyphs, for the cards.
extension PanelIcons {
    static let chevronLeft = "m15 6-6 6 6 6"
    static let chevronRight = "m9 6 6 6-6 6"
    static let close = "M18 6 6 18M6 6l12 12"
    static let plus = "M12 5v14M5 12h14"
    static let lock = "M5 11h14v10H5zM8 11V7a4 4 0 0 1 8 0v4"
    static let wifi = "M5 12.55a11 11 0 0 1 14 0M8.5 16.05a6 6 0 0 1 7 0M2 8.82a15 15 0 0 1 20 0M12 20h.01"
    static let spinner = "M21 12a9 9 0 1 1-6.2-8.56"
    static let mic = "M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3ZM19 10v2a7 7 0 0 1-14 0v-2M12 19v3"
    static let micOff = "M2 2l20 20M9 9v3a3 3 0 0 0 5.1 2.1M15 9.3V5a3 3 0 0 0-5.9-.6M19 10v2a7 7 0 0 1-1.1 3.8M5 10v2a7 7 0 0 0 11.7 5.2M12 19v3"
    static let headphones = "M3 14h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a9 9 0 0 1 18 0v7a2 2 0 0 1-2 2h-1a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3"
    static let mouse = "M12 2a6 6 0 0 0-6 6v8a6 6 0 0 0 12 0V8a6 6 0 0 0-6-6ZM12 6v4"
    static let keyboard = "M2 6h20v12H2zM6 10h.01M10 10h.01M14 10h.01M18 10h.01M8 14h8"
    static let phone = "M7 2h10v20H7zM12 18h.01"
    static let speaker = "M5 2h14v20H5zM12 6h.01"
    static let gamepad = "M6 12h4M8 10v4M15 13h.01M18 11h.01M17.32 5H6.68a4 4 0 0 0-3.98 3.59l-.9 7.28A2.5 2.5 0 0 0 4.27 19c.6 0 1.17-.24 1.6-.66L8.5 15.7h7l2.63 2.63c.43.43 1 .67 1.6.67a2.5 2.5 0 0 0 2.47-3.13l-.9-7.28A4 4 0 0 0 17.32 5Z"
    static let device = "M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20ZM12 8v4M12 16h.01"
    static let appDisc: [IconShape] = [.circle(cx: 12, cy: 12, r: 9), .circle(cx: 12, cy: 12, r: 3)]
}

extension MenuSession {
    /// Where a popup hangs: 10pt under the bar — the compositor adds its own
    /// 6 to an anchor's bottom — with its right edge `rightOverhang` past the
    /// right edge of what opened it, as the design places each card.
    ///
    /// Falls back to the right end of the screen before the first layout.
    func popupAnchor(under sid: String, width: Float, rightOverhang: Float = 0)
        -> LavaApp.SurfaceAnchor
    {
        let host = LavaApp.mainLayoutHost
        let bar = host?.agentFrame(sid: "panel.bar")
        let barBottom = (bar.map { $0.y + $0.h } ?? panelMetrics.marginTop + panelMetrics.barHeight)
        let right: Float
        if let trigger = host?.agentFrame(sid: sid) {
            right = trigger.x + trigger.w + rightOverhang
        } else {
            right = (editor?.framebufferSize().w ?? 1280) - panelMetrics.marginSide
        }
        return LavaApp.SurfaceAnchor(x: max(0, right - width), y: barBottom - 1, w: 1,
                                     h: 1 + 4)
    }
}
