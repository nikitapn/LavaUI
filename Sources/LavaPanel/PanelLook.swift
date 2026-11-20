import Foundation
import LavaBluetoothCore
import LavaClient
import LavaMpris
import LavaNetworkCore
import LavaUI

/// How the bar sits on its edge: a strip docked flush, or a pill floating
/// clear of it. `[panel] style` in `lava.conf`; docked unless it says
/// otherwise — the design's own default, since a maximized window meets a
/// docked strip edge to edge, where a pill leaves gaps round itself.
enum PanelStyle: String {
    case floating
    case docked

    /// From the environment the compositor started the panel with, then the
    /// config file. Read once at start; a change is a panel restart.
    static func configured() -> PanelStyle {
        if let raw = ProcessInfo.processInfo.environment["LAVA_PANEL_STYLE"],
           let style = PanelStyle(rawValue: raw.lowercased()) {
            return style
        }
        return PanelConfig.style() ?? .docked
    }
}

/// Every number the bar is drawn with, for one style. The design's own:
/// a 32pt bar, 26pt controls inside it, the pill held 4pt off the top and
/// 6pt off the sides.
struct PanelMetrics {
    let style: PanelStyle

    var barHeight: Float { 32 }
    /// Buttons, menu titles, the clock: a chip this tall, centred in the bar.
    var control: Float { barHeight - 6 }
    var marginTop: Float { style == .floating ? 4 : 0 }
    var marginSide: Float { style == .floating ? 6 : 0 }
    /// Clear space under a floating pill before the work area starts, so a
    /// maximized window does not touch it.
    var marginBottom: Float { style == .floating ? 4 : 0 }
    var radius: Float { style == .floating ? barHeight / 2 : 0 }

    /// What windows are laid out around.
    var reserved: Float { marginTop + barHeight + marginBottom }

    /// From the bar's bottom edge to a popup's or a menu's top: the
    /// design's `popTop`.
    var popupGap: Float { style == .floating ? 10 : 6 }

    /// The shadow: how far it falls and how soft, CSS-style.
    var shadowOffset: Float { style == .floating ? 8 : 6 }
    var shadowBlur: Float { style == .floating ? 28 : 20 }
    var shadowAlpha: Float { style == .floating ? 0.22 : 0.18 }

    /// The surface, which has to hold the shadow as well as the bar. Deeper
    /// than `reserved`: the shadow falls over the windows below, and the
    /// input region keeps the pointer from noticing.
    var surfaceHeight: Float {
        marginTop + barHeight + shadowOffset + shadowBlur
    }

    /// The bar's rectangle in the surface.
    func barFrame(surfaceWidth: Float) -> (x: Float, y: Float, w: Float, h: Float) {
        (marginSide, marginTop, max(0, surfaceWidth - 2 * marginSide), barHeight)
    }
}

/// The bar's colours. The design's palette exactly on the paper theme it was
/// drawn for; derived from the theme's roles anywhere else, so a dark
/// desktop gets a dark bar rather than a cream one.
struct PanelPalette {
    var text: Color
    /// Dates, secondary labels: `--color-neutral-800`.
    var textSoft: Color
    /// The glyphs in the tray: `--color-neutral-900`.
    var icon: Color
    var accent: Color
    var accentHover: Color
    /// A pale accent wash: hover on accent-coloured controls, a selected day.
    var accentSoft: Color
    /// Accent-coloured text and glyphs on a light ground.
    var accentInk: Color
    /// Text and glyphs on `accent`.
    var onAccent: Color
    /// The glass, before the compositor's frost shows through it.
    var glass: Color
    /// The glass, where a popup has to read more solidly.
    var glassStrong: Color
    var glassBorder: Color
    /// A menu title while its menu is open.
    var menuOpen: Color
    /// A chip on the glass (the tray group, the workspace group).
    var chip: Color
    /// A chip under the pointer, or open.
    var chipHover: Color
    var chipOpen: Color
    /// The lit disc behind an open tray glyph.
    var trayOn: Color
    var divider: Color
    var dot: Color
    var dotEmpty: Color
    var dotHover: Color
    var shadow: Color

    static var current: PanelPalette { PanelPalette(theme: Theme.current) }

    init(theme: Theme) {
        if theme == .paper {
            // `organic` design system, `Taskbar.dc.html`.
            text = Color(rgb24: 0x20_1e_1d)
            textSoft = Color(rgb24: 0x47_42_38)
            icon = Color(rgb24: 0x2e_2b_25)
            accent = Color(rgb24: 0xc6_71_39)
            accentHover = Color(rgb24: 0xb2_62_2d)
            accentSoft = Color(rgb24: 0xff_e1_d0)
            accentInk = Color(rgb24: 0x64_33_12)
            onAccent = Color(rgb24: 0xf9_f4_ed)
            let neutral = Color(rgb24: 0xf9_f4_ed)
            // The design says 58%, in CSS terms. The bar is its own surface,
            // though, and wlroots blends surfaces in linear light, where
            // 0.58 of cream over green comes out as 0.74 would in a browser.
            // Tuned by eye (with saturation 1.7 on the frost) against the
            // design's own wallpaper; see
            // docs/colour-and-blending.md before changing it by arithmetic.
            glass = neutral.opacity(0.34)
            glassStrong = neutral.opacity(0.62)
            glassBorder = Color(r: 1, g: 1, b: 1, a: 0.55)
            chip = Color(r: 1, g: 1, b: 1, a: 0.35)
            chipHover = Color(r: 1, g: 1, b: 1, a: 0.55)
            chipOpen = Color(r: 1, g: 1, b: 1, a: 0.65)
            menuOpen = Color(r: 1, g: 1, b: 1, a: 0.75)
            trayOn = neutral
            divider = text.opacity(0.16)
            dot = text.opacity(0.28)
            dotEmpty = text.opacity(0.14)
            dotHover = text.opacity(0.5)
            shadow = Color(r: 20 / 255, g: 30 / 255, b: 30 / 255, a: 1)
            return
        }
        let light = theme.background.luminance > 0.5
        let lift: Color = light ? Color(r: 1, g: 1, b: 1) : Color(r: 1, g: 1, b: 1)
        text = theme.textPrimary
        textSoft = theme.textSecondary
        icon = theme.textPrimary
        accent = theme.accent
        accentHover = light ? theme.accent.darkened(0.12) : theme.accent.lightened(0.12)
        accentSoft = theme.selectionFill
        accentInk = light ? theme.selected : theme.accent
        onAccent = theme.background
        glass = theme.panel.opacity(light ? 0.40 : 0.55)
        glassStrong = theme.panel.opacity(light ? 0.62 : 0.75)
        glassBorder = lift.opacity(light ? 0.55 : 0.10)
        chip = lift.opacity(light ? 0.35 : 0.07)
        chipHover = lift.opacity(light ? 0.55 : 0.13)
        chipOpen = lift.opacity(light ? 0.65 : 0.16)
        menuOpen = lift.opacity(light ? 0.75 : 0.2)
        trayOn = light ? theme.inset : theme.hover
        divider = theme.textPrimary.opacity(0.16)
        dot = theme.textPrimary.opacity(0.28)
        dotEmpty = theme.textPrimary.opacity(0.14)
        dotHover = theme.textPrimary.opacity(0.5)
        shadow = Color(r: 0, g: 0, b: 0, a: 1)
    }
}

extension Color {
    /// Relative luminance in sRGB terms, good enough to tell a light theme
    /// from a dark one.
    var luminance: Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    func darkened(_ amount: Float) -> Color {
        Color(r: r * (1 - amount), g: g * (1 - amount), b: b * (1 - amount), a: a)
    }
}

/// The bar's faces: Figtree throughout, as the design specifies, with
/// tabular figures wherever a number changes in place.
struct PanelFonts {
    /// Menu titles and the now-playing title: 13px semibold.
    let label: UIFont
    /// The date beside the clock.
    let small: UIFont
    /// The time: bold, tabular, so the seconds do not shake the bar.
    let clock: UIFont

    static func load(into editor: Editor) -> PanelFonts? {
        func face(_ weight: String, _ size: Float, features: [String] = []) -> UIFont? {
            guard let path = BundledFont.path("Figtree-\(weight)"),
                  let font = UIFont(path: path, pixelSize: size, features: features)
            else { return nil }
            font.registerWithEngine(editor)
            if let base = FontStore.default {
                let paths = [base.path] + base.fallbacks.map(\.path)
                font.useFallbacks(paths.map { FontFallback(path: $0, pixelSize: size) },
                                  into: editor)
            }
            return font
        }
        guard let label = face("SemiBold", 13),
              let small = face("Regular", 13),
              let clock = face("Bold", 13, features: ["tnum"])
        else { return nil }
        return PanelFonts(label: label, small: small, clock: clock)
    }
}

/// Path data for the bar's glyphs, from the design (Lucide's set).
enum PanelIcons {
    static let bluetooth = "m7 7 10 10-5 5V2l5 5L7 17"
    static let bluetoothOff = "m17 17-5 5V12l-5 5M2 2l20 20M14.5 9.5 17 7l-5-5v4.5"
    static let bluetoothConnected = "m7 7 10 10-5 5V2l5 5L7 17M18 12h.01M6 12h.01"
    static let wifiArcs = [
        "M12 20h.01",
        "M8.5 16.05a6 6 0 0 1 7 0",
        "M5 12.55a11 11 0 0 1 14 0",
        "M2 8.82a15 15 0 0 1 20 0",
    ]
    static let wifiOff = "M12 20h.01M8.5 16.43a5 5 0 0 1 7 0M2 8.82a15 15 0 0 1 4.17-2.65"
        + "M10.66 5c4.01-.36 8.14.9 11.34 3.76M16.85 11.25a10 10 0 0 1 2.22 1.68"
        + "M5 13a10 10 0 0 1 5.24-2.76M2 2l20 20"
    static let wired = "M16 17l5-5-5-5M8 7l-5 5 5 5M14 4l-4 16"
    static let ethernet = "M3 14h18v6H3zM6 14v-3h4V8h4v3h4v3M7 17v.01M12 17v.01M17 17v.01"
    static let volume = "M11 5 6 9H2v6h4l5 4ZM15.5 8.5a5 5 0 0 1 0 7M19 5a10 10 0 0 1 0 14"
    static let volumeLow = "M11 5 6 9H2v6h4l5 4ZM15.5 8.5a5 5 0 0 1 0 7"
    static let volumeOff = "M11 5 6 9H2v6h4l5 4Z"
    static let mute = "M11 5 6 9H2v6h4l5 4ZM22 9l-6 6M16 9l6 6"
    static let music = "M9 18V5l12-2v13"
    static let power = "M12 3v9M6.4 6.6a8 8 0 1 0 11.2 0"
    static let shield = "M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10Z"
}

/// One workspace dot per workspace worth showing: the current one drawn
/// long, in the accent; the rest round. Four at least, as the design shows,
/// and as many more as reach the last one with a window on it.
struct WorkspaceDots: View {
    var workspaces: DesktopMenus.Workspaces
    var metrics: PanelMetrics
    var palette: PanelPalette

    var body: some View {
        let shown = Self.shownCount(workspaces)
        let current = Int(workspaces.current)
        let palette = palette
        let dot: Float = 8
        return HStack(height: .pt(max(16, metrics.control - 6)), padding: 0,
                      alignment: .center, spacing: 5) {
            ForEach(0..<shown, id: \.self) { index in
                let on = index == current
                let occupied = index < workspaces.windows.count && workspaces.windows[index] > 0
                HStack(width: .pt(on ? 26 : dot), height: .pt(dot), padding: 0,
                       onClick: { LavaClient.switchWorkspace(UInt32(index)) }) {}
                    .background(on ? palette.accent : occupied ? palette.dot : palette.dotEmpty)
                    .hoverBackground(on ? palette.accentHover : palette.dotHover)
                    .cornerRadius(dot / 2)
                    .tooltip("Workspace \(index + 1)")
                    .agentId("workspace.\(index + 1)")
            }
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .background(palette.chip)
        .cornerRadius(10)
        .agentId("workspaces")
    }

    static func shownCount(_ workspaces: DesktopMenus.Workspaces) -> Int {
        let lastOccupied = workspaces.windows.lastIndex(where: { $0 > 0 }) ?? -1
        return min(DesktopMenus.Workspaces.count,
                   max(4, lastOccupied + 1, Int(workspaces.current) + 1))
    }
}

/// A round button on the glass holding one glyph.
struct GlassIconButton: View {
    var icon: [IconShape]
    var size: Float
    var glyph: Float = 15
    var color: Color
    var fill: Color = .clear
    var hover: Color
    var strokeWidth: Float = 2.25
    var faint: [IconShape] = []
    var faintColor: Color = .clear
    var agentId: String
    var onPointer: (_ button: Int32) -> Void
    var onWheel: ((Float) -> Void)? = nil

    var body: some View {
        let onPointer = onPointer, onWheel = onWheel
        return HStack(width: .pt(size), height: .pt(size), padding: 0, alignment: .center, spacing: 0,
                      onPointer: { _, button in onPointer(button) },
                      onWheel: onWheel.map { wheel in { _, dy in wheel(dy) } }) {
            Spacer()
            Icon(icon, size: glyph, color: color, strokeWidth: strokeWidth,
                 faint: faint, faintColor: faintColor)
            Spacer()
        }
        .background(fill)
        .hoverBackground(hover)
        .cornerRadius(size / 2)
        .cursor(.pointer)
        .agentId(agentId)
    }
}

/// Bluetooth, network and sound in one capsule, as the design groups them.
/// Each lights up while its popup is open.
struct TrayCluster: View {
    var metrics: PanelMetrics
    var palette: PanelPalette

    var body: some View {
        let size = metrics.control - 4
        let palette = palette
        return HStack(padding: 0, alignment: .center, spacing: 2) {
            if bluetooth.status != .absent {
                let open = session.bluetoothWindow != nil
                GlassIconButton(
                    icon: [.path(Self.bluetoothIcon(bluetooth.status))], size: size,
                    color: open ? palette.accentInk : Self.dimmed(bluetooth.status, palette),
                    fill: open ? palette.trayOn : .clear, hover: palette.chipOpen,
                    agentId: "applet.bluetooth",
                    onPointer: { button in
                        if button == PointerButton.left { session.toggleBluetooth() }
                    })
                    .tooltip("Bluetooth")
            }
            if network.state.running {
                let open = session.networkWindow != nil
                let fan = Self.networkIcon(network.status)
                let ink = open ? palette.accentInk : palette.icon
                GlassIconButton(
                    icon: fan.lit, size: size, color: ink,
                    fill: open ? palette.trayOn : .clear, hover: palette.chipOpen,
                    faint: fan.faint, faintColor: ink.mixed(with: palette.trayOn, 0.62),
                    agentId: "applet.network",
                    onPointer: { button in
                        if button == PointerButton.left { session.toggleNetwork() }
                    })
                    .tooltip("Network")
            }
            let open = session.volumeWindow != nil
            GlassIconButton(
                icon: [.path(Self.volumeIcon(volume: pulse.volume, muted: pulse.muted))],
                size: size,
                color: open ? palette.accentInk : palette.icon,
                fill: open ? palette.trayOn : .clear, hover: palette.chipOpen,
                agentId: "applet.volume",
                onPointer: { button in
                    if button == PointerButton.left {
                        session.toggleVolume()
                    } else if button == PointerButton.right {
                        pulse.toggleMute()
                    }
                },
                onWheel: { dy in
                    // Positive dy = scroll up = louder. One notch ≈ 5%.
                    let step: Float = dy > 0 ? 0.05 : -0.05
                    pulse.adjustVolume(by: step)
                    if pulse.muted && step > 0 { pulse.setMuted(false) }
                })
                .tooltip("Sound")
        }
        .padding(2)
        .background(palette.chip)
        .cornerRadius((size + 4) / 2)
        .agentId("tray")
    }

    static func bluetoothIcon(_ status: BluetoothStatus) -> String {
        switch status {
        case .absent, .off, .blocked: return PanelIcons.bluetoothOff
        case .on: return PanelIcons.bluetooth
        case .connected: return PanelIcons.bluetoothConnected
        }
    }

    static func dimmed(_ status: BluetoothStatus, _ palette: PanelPalette) -> Color {
        switch status {
        case .absent, .off, .blocked: return palette.textSoft
        default: return palette.icon
        }
    }

    /// A glyph in two layers: what is lit, and what is drawn faint under it.
    struct SplitIcon {
        var lit: [IconShape]
        var faint: [IconShape] = []
    }

    /// The design's whole fan, always — the dot and three arcs — with the
    /// arcs beyond the signal's reach drawn faint: the strength is the one
    /// thing the old glyph said that a static icon would lose, and leaving
    /// those arcs out made a different glyph.
    static func networkIcon(_ status: NetworkStatus) -> SplitIcon {
        let arcs = PanelIcons.wifiArcs.map { IconShape.path($0) }
        switch status.link {
        case .off, .disconnected:
            return SplitIcon(lit: [.path(PanelIcons.wifiOff)])
        case .connecting:
            return SplitIcon(lit: Array(arcs.prefix(2)), faint: Array(arcs.dropFirst(2)))
        case .wired:
            return SplitIcon(lit: [.path(PanelIcons.ethernet)])
        case .wifi(let bars):
            let lit = max(1, min(4, bars))
            return SplitIcon(lit: Array(arcs.prefix(lit)), faint: Array(arcs.dropFirst(lit)))
        }
    }

    static func volumeIcon(volume: Float, muted: Bool) -> String {
        if muted { return PanelIcons.mute }
        if volume <= 0.001 { return PanelIcons.volumeOff }
        return volume < 0.5 ? PanelIcons.volumeLow : PanelIcons.volume
    }
}

/// The date and the time, one chip; the calendar opens from it.
struct ClockChip: View {
    var date: String
    var time: String
    var metrics: PanelMetrics
    var palette: PanelPalette
    var fonts: PanelFonts

    var body: some View {
        let open = session.calendarWindow != nil
        return HStack(height: .pt(metrics.control), padding: 0, alignment: .center,
                      spacing: 8, onClick: { session.toggleCalendar() }) {
            Text(date, color: palette.textSoft, font: fonts.small)
            Text(time, color: palette.text, font: fonts.clock)
        }
        .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
        .background(open ? palette.chipOpen : .clear)
        .hoverBackground(palette.chipOpen)
        .cornerRadius(metrics.control / 2)
        .cursor(.pointer)
        .agentId("applet.calendar")
    }
}

/// What is playing: the cover (or a note on the accent), the title, and
/// three bars that move while it plays.
struct NowPlayingChip: View {
    var mpris: MprisSession
    var metrics: PanelMetrics
    var palette: PanelPalette
    var fonts: PanelFonts

    static let maxTitleWidth: Float = 240

    var body: some View {
        let open = session.playerWindow != nil
        let playing = mpris.isPlaying
        let art = metrics.control - 4
        let title = mpris.title.isEmpty ? "Not playing" : mpris.title
        let titleWidth = min(Self.maxTitleWidth, fonts.label.measure(title).width)
        let palette = palette
        return HStack(padding: 0, alignment: .center, spacing: 9, onPointer: { _, button in
            if button == PointerButton.right {
                mpris.playPause()
            } else if button == PointerButton.left {
                session.togglePlayer()
            }
        }, onWheel: { _, dy in mpris.skipByWheel(dy: dy) }) {
            cover(size: art)
            Text(title, color: palette.text, font: fonts.label, lineLimit: 1)
                .frame(width: .pt(titleWidth))
                .clipped()
            Equalizer(playing: playing, color: palette.accent)
        }
        .padding(EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 12))
        .background(open ? palette.chipOpen : palette.chip)
        .hoverBackground(palette.chipOpen)
        .cornerRadius((art + 4) / 2)
        .cursor(.pointer)
        .agentId("applet.player")
    }

    @ViewBuilder
    private func cover(size: Float) -> some View {
        if let path = ArtCache.pathIfReady(for: mpris.artURL, onReady: {
            MainQueue.async { ViewInvalidation.markNeedsBody() }
        }) {
            Image(path: path, width: .pt(size), height: .pt(size),
                  placeholder: palette.accent, placeholderCornerRadius: size / 2,
                  contentMode: .fill)
                .cornerRadius(size / 2)
                .frame(width: .pt(size), height: .pt(size))
        } else {
            let accent = palette.accent, ink = palette.accentInk, on = palette.onAccent
            HStack(width: .pt(size), height: .pt(size), padding: 0, alignment: .center, spacing: 0) {
                Spacer()
                Icon([.path(PanelIcons.music), .circle(cx: 6, cy: 18, r: 3),
                      .circle(cx: 18, cy: 16, r: 3)],
                     size: 12, color: on, strokeWidth: 2.75)
                Spacer()
            }
            .background(Gradient(from: accent.lightened(0.2), to: ink, angle: .pi * 0.72))
            .cornerRadius(size / 2)
        }
    }
}

/// Three bars bouncing out of phase while something plays; still and faint
/// when paused.
///
/// Fifteen frames a second rather than every frame: the bars are three
/// pixels wide and nobody can tell, and a panel redrawn at the display rate
/// for as long as music plays is a desktop that never idles.
struct Equalizer: View {
    var playing: Bool
    var color: Color

    static let period: Double = 0.9
    static let frame: Double = 1.0 / 15

    var body: some View {
        let playing = playing, color = color
        return Canvas(label: "equalizer", width: .pt(13), height: .pt(12)) { list, frame in
            let now = Date().timeIntervalSinceReferenceDate
            for bar in 0..<3 {
                let scale: Float
                if playing {
                    // `tb-eq`: 0.35 → 1 → 0.35 per period, each bar a third
                    // of a period behind the last.
                    let phase = (now / Self.period + Double(bar) / 3)
                        .truncatingRemainder(dividingBy: 1)
                    let wave = Float((1 - cos(phase * 2 * .pi)) / 2)
                    scale = 0.35 + 0.65 * wave
                } else {
                    scale = 0.35
                }
                let h = max(2, frame.h * scale)
                list.roundedRect(x: frame.x + Float(bar) * 5, y: frame.y + frame.h - h,
                                 w: 3, h: h, color: playing ? color : color.opacity(0.4),
                                 radius: 1.5)
            }
            if playing { FrameScheduler.requestRedraw(in: Self.frame) }
        }
    }
}

/// The power button at the end of the bar.
/// The flame on an accent disc, first on the bar: starts the launcher.
struct LavaButton: View {
    var icon: UIImage
    var metrics: PanelMetrics
    var palette: PanelPalette

    var body: some View {
        let size = metrics.control
        return HStack(width: .pt(size), height: .pt(size), padding: 0, alignment: .center,
                      spacing: 0, onClick: { launchDesktopProgram("LavaLauncher") }) {
            Spacer()
            Image(icon, width: .pt(14), height: .pt(14), tint: palette.onAccent,
                  contentMode: .fit)
            Spacer()
        }
        .background(palette.accent)
        .hoverBackground(palette.accentHover)
        .cornerRadius(size / 2)
        .cursor(.pointer)
        .agentId("panel.lava")
        .tooltip("Applications")
    }
}

struct PowerButton: View {
    var metrics: PanelMetrics
    var palette: PanelPalette

    var body: some View {
        let busy = session.powerBusy
        return GlassIconButton(
            icon: [.path(PanelIcons.power)], size: metrics.control,
            color: busy ? palette.textSoft : palette.accentInk,
            // Lit while its card is up, as the tray's buttons are.
            fill: session.sessionCard != nil ? palette.accentSoft : .clear,
            hover: busy ? .clear : palette.accentSoft, strokeWidth: 2.75,
            agentId: "applet.power",
            onPointer: { button in
                guard button == PointerButton.left, !session.powerBusy else { return }
                session.toggleSessionCard()
            })
            .tooltip("Power")
    }
}

/// `[panel]` in `lava.conf`, read directly. The compositor owns the file and
/// ignores the section; this is the one key the panel needs before it has
/// drawn anything, and asking the compositor for it would be a call per
/// setting nobody else reads.
enum PanelConfig {
    static func style() -> PanelStyle? {
        guard let text = configText() else { return nil }
        var section = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            guard section == "panel", let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces).lowercased()
            if key == "style" { return PanelStyle(rawValue: value) }
        }
        return nil
    }

    /// The file the compositor reads (`configPath` in config.cpp): the first
    /// of `LAVA_CONFIG`, `$XDG_CONFIG_HOME/lava/lava.conf` and
    /// `~/.config/lava/lava.conf` that is *set*, whether or not it exists —
    /// so a test session pointed at a scratch config never picks up the
    /// user's own.
    private static func configText() -> String? {
        let env = ProcessInfo.processInfo.environment
        let path: String
        if let explicit = env["LAVA_CONFIG"] {
            path = explicit
        } else if let xdg = env["XDG_CONFIG_HOME"] {
            path = xdg + "/lava/lava.conf"
        } else if let home = env["HOME"] {
            path = home + "/.config/lava/lava.conf"
        } else {
            return nil
        }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }
}
