import Foundation
import LavaShell
import LavaUI

/// The sound window. Same process as the panel, so it reads `PulseSession`
/// directly — a second process would have to be told the level on every tick.
///
/// Outputs are listed open, not behind a dropdown: switching from the
/// monitor's speakers to headphones is the speaker and then the row, two
/// clicks. Then the microphone the same way, then a level per application.
///
/// The wash is the frosted menu's, not an opaque fill. The compositor
/// frosts the desktop behind this surface; a solid background would hide
/// that plate completely. `WindowBackdrop` cannot say so per window — the
/// panel is `.none` and that setting is the whole process.
struct VolumeWindow: View {
    var pulse: PulseSession

    var body: some View {
        let blocks = SoundBlock.blocks(pulse)
        return ScrollingCard(padding: SoundBlock.padding) {
            ForEach(blocks) { block in
                row(block).frame(height: .pt(block.height))
            }
        }
        .agentId("volume.window")
    }

    @ViewBuilder
    private func row(_ block: SoundBlock) -> some View {
        let palette = PopupPalette.current
        let fonts = popupFonts!
        switch block {
        case .header(let title):
            HStack(padding: 0, alignment: .end) {
                Kicker(text: title)
            }
        case .divider:
            CardDivider()
                .padding(EdgeInsets(top: 2, leading: 0, bottom: 12, trailing: 0))
        case .connecting:
            HStack(padding: 0, alignment: .center) {
                Text("Connecting to PulseAudio…", color: palette.bar.textSoft, font: fonts.small13)
                    .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0))
            }
        case .outputLevel:
            levelRow(
                icon: TrayCluster.volumeIcon(volume: pulse.volume, muted: pulse.muted),
                muted: pulse.muted, volume: pulse.volume,
                label: "output", id: "volume.mute",
                toggle: { pulse.toggleMute() },
                value: pulse.volumeBinding, palette: palette
            )
        case .inputLevel:
            let muted = pulse.input?.muted ?? false
            levelRow(
                icon: muted ? PanelIcons.micOff : PanelIcons.mic,
                muted: muted, volume: pulse.input?.volume ?? 0,
                label: "microphone", id: "volume.mic-mute",
                toggle: { pulse.setInputMuted(!(pulse.input?.muted ?? false)) },
                value: pulse.inputVolumeBinding, palette: palette
            )
        case .route(let route, let isInput):
            routeRow(route, isInput: isInput, palette: palette)
        case .stream(let stream):
            streamRow(stream, palette: palette)
        }
    }

    /// The mute button, the level, and the level as a number.
    private func levelRow(
        icon: String, muted: Bool, volume: Float, label: String, id: String,
        toggle: @escaping () -> Void, value: Binding<Float>, palette: PopupPalette
    ) -> some View {
        HStack(padding: 0, alignment: .center, spacing: 10) {
            muteButton(icon: icon, muted: muted, label: label, id: id, palette: palette,
                       toggle: toggle)
            Slider(value: value, in: Self.range(volume), step: 0.01,
                   style: PopupStyles.slider(palette, width: 200))
                .flexGrow(1)
            levelText(muted ? "Muted" : PulseSession.percent(volume), palette: palette)
        }
        .padding(EdgeInsets(top: 4, leading: 4, bottom: 6, trailing: 8))
    }

    /// Full is 100%, as the design draws it. A level already boosted past
    /// that — by the wheel on the tray glyph, or another mixer — gets the
    /// room up to 150% it needs to be shown and dragged back down.
    static func range(_ volume: Float) -> ClosedRange<Float> {
        volume > 1.001 ? 0...1.5 : 0...1
    }

    private func levelText(_ text: String, palette: PopupPalette) -> some View {
        Text(text, color: palette.bar.text, font: popupFonts.small13SemiTabular, align: .trailing)
            .frame(width: .pt(44))
    }

    private func muteButton(
        icon: String, muted: Bool, label: String, id: String, palette: PopupPalette,
        toggle: @escaping () -> Void
    ) -> some View {
        CardIconButton(icon: [.path(icon)], size: 32, glyph: 16,
                       color: muted ? palette.bar.accentInk : palette.bar.text,
                       hover: palette.bar.accentSoft,
                       fill: muted ? palette.bar.accentSoft : palette.rowHover.opacity(0.8),
                       strokeWidth: 2.25, agentId: id, action: toggle)
            .tooltip(muted ? "Unmute \(label)" : "Mute \(label)")
    }

    /// A device, as a radio row: its name, and the card it is on under it.
    private func routeRow(_ route: SoundRoute, isInput: Bool, palette: PopupPalette) -> some View {
        let fonts = popupFonts!
        let current = route.isCurrent
        let ring = palette.neutral600, fill = palette.bar.accent
        let center = palette.bar.onAccent, empty = palette.rowHover
        return HStack(
            padding: 0, alignment: .center, spacing: 10,
            onClick: { isInput ? pulse.selectInput(route) : pulse.selectOutput(route) }
        ) {
            Canvas(label: "radio", width: .pt(16), height: .pt(16)) { list, frame in
                let cx = frame.x + 8, cy = frame.y + 8
                if current {
                    // A 1.5pt accent edge, a 3.5pt ring of the card's light
                    // colour inside it, and the accent again in the middle:
                    // the design's `inset 0 0 0 3.5px` on a filled dot.
                    list.circle(cx: cx, cy: cy, radius: 8, color: fill)
                    list.circle(cx: cx, cy: cy, radius: 6.5, color: center)
                    list.circle(cx: cx, cy: cy, radius: 3, color: fill)
                } else {
                    // A light centre inside a 1.5pt ring — an outline, so the
                    // translucent centre is not laid over a solid disc.
                    list.circle(cx: cx, cy: cy, radius: 7.5, color: empty)
                    list.strokedRect(x: cx - 8, y: cy - 8, w: 16, h: 16, color: ring,
                                     radius: 8, width: 1.5)
                }
            }
            .flexShrink(0)
            VStack(flexGrow: 1, padding: 0, spacing: 0) {
                Text(route.title, color: palette.bar.text,
                     font: current ? fonts.body14Semi : fonts.body14, lineLimit: 1)
                if !route.subtitle.isEmpty {
                    Text(route.subtitle, color: palette.bar.textSoft, font: fonts.caption12,
                         lineLimit: 1)
                }
            }
            .clipped()
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .hoverBackground(palette.rowHover)
        .cornerRadius(12)
        .cursor(.pointer)
        .agentId((isInput ? "volume.input." : "volume.output.") + route.id)
    }

    /// An application: its disc, its name over its level, and the number.
    private func streamRow(_ stream: SoundStream, palette: PopupPalette) -> some View {
        let fonts = popupFonts!
        return HStack(padding: 0, alignment: .center, spacing: 10) {
            CardIconButton(icon: PanelIcons.appDisc, size: 32, glyph: 15,
                           color: stream.muted ? palette.bar.accentInk : palette.sage800,
                           hover: palette.bar.accentSoft,
                           fill: stream.muted ? palette.bar.accentSoft : palette.sage200,
                           strokeWidth: 2.25, agentId: "volume.stream-mute.\(stream.id)") {
                pulse.setStreamMuted(stream, !stream.muted)
            }
            .tooltip(stream.muted ? "Unmute \(stream.title)" : "Mute \(stream.title)")
            VStack(flexGrow: 1, padding: 0, spacing: 4) {
                Text(stream.title, color: palette.bar.text, font: fonts.small13Semi, lineLimit: 1)
                Slider(value: pulse.streamVolumeBinding(stream), in: Self.range(stream.volume),
                       step: 0.01, style: PopupStyles.slider(palette, width: 200))
            }
            .clipped()
            levelText(stream.muted ? "Muted" : PulseSession.percent(stream.volume),
                      palette: palette)
        }
        .padding(EdgeInsets(top: 4, leading: 4, bottom: 2, trailing: 8))
        .tooltip(stream.media.isEmpty || stream.media == stream.title ? stream.title : stream.media)
        .agentId("volume.stream.\(stream.id)")
    }
}

/// The window's rows, each a stated height — which is what lets the panel
/// open the window at the size of its contents without a layout pass to ask.
/// A popup is a fixed-size surface; past `maxHeight` the list scrolls.
enum SoundBlock: Identifiable {
    case header(String)
    /// Named after the section it opens: `ForEach` keys must be unique.
    case divider(String)
    case connecting
    case outputLevel
    case inputLevel
    case route(SoundRoute, isInput: Bool)
    case stream(SoundStream)

    static let padding: Float = 12
    static let width: Float = 360
    static let maxHeight: Float = 600

    var id: String {
        switch self {
        case .header(let title): return "header." + title
        case .divider(let name): return "divider." + name
        case .connecting: return "connecting"
        case .outputLevel: return "level.output"
        case .inputLevel: return "level.input"
        case .route(let route, let isInput): return (isInput ? "in." : "out.") + route.id
        case .stream(let stream): return "stream.\(stream.id)"
        }
    }

    var height: Float {
        switch self {
        case .header: return 21
        case .divider: return 15
        case .connecting: return 30
        case .outputLevel, .inputLevel: return 42
        case .route(let route, _): return route.subtitle.isEmpty ? 34 : 44
        case .stream: return 48
        }
    }

    static func blocks(_ pulse: PulseSession) -> [SoundBlock] {
        guard pulse.isReady else { return [.connecting] }
        var out: [SoundBlock] = [.header("Output"), .outputLevel]
        out += pulse.outputRoutes.map { .route($0, isInput: false) }
        let inputs = pulse.inputRoutes
        if !inputs.isEmpty {
            out += [.divider("input"), .header("Input"), .inputLevel]
            out += inputs.map { .route($0, isInput: true) }
        }
        if !pulse.streams.isEmpty {
            out += [.divider("apps"), .header("Applications")]
            out += pulse.streams.map { .stream($0) }
        }
        return out
    }

    /// The window height for `blocks`, padding included.
    static func height(of blocks: [SoundBlock]) -> Float {
        min(blocks.reduce(padding * 2) { $0 + $1.height }, maxHeight)
    }
}

/// The speaker is `SpeakerMark`; the microphone is drawn here.
enum SoundGlyph {
    enum Kind { case speaker, microphone }

    static func paint(
        _ kind: Kind, list: DrawList, frame: CanvasFrame,
        volume: Float, muted: Bool,
        color: Color, accent: Color
    ) {
        if kind == .microphone {
            microphone(list: list, frame: frame, muted: muted, color: color, accent: accent)
            return
        }
        SpeakerMark.paint(
            list: list, frame: frame, level: volume, muted: muted,
            color: color, mutedColor: accent
        )
    }

    /// Capsule, cradle and stand.
    private static func microphone(
        list: DrawList, frame: CanvasFrame, muted: Bool, color: Color, accent: Color
    ) {
        let s = min(frame.w, frame.h)
        let cx = frame.x + frame.w * 0.5
        let top = frame.y + (frame.h - s) * 0.5 + s * 0.12
        let capW = s * 0.28
        let capH = s * 0.44
        list.roundedRect(
            x: cx - capW * 0.5, y: top, w: capW, h: capH, color: color, radius: capW * 0.5
        )
        // The cradle: half a ring below the capsule's middle.
        let r = s * 0.25
        let cy = top + capH * 0.55
        var arc: [(x: Float, y: Float)] = []
        for i in 0...12 {
            let a = Float.pi * Float(i) / 12
            arc.append((cx + cos(a) * r, cy + sin(a) * r))
        }
        for i in 1..<arc.count {
            list.line(x1: arc[i - 1].x, y1: arc[i - 1].y, x2: arc[i].x, y2: arc[i].y,
                      color: color, width: 1.5)
        }
        let stemTop = cy + r
        let stemBottom = frame.y + (frame.h + s) * 0.5 - s * 0.1
        list.line(x1: cx, y1: stemTop, x2: cx, y2: stemBottom, color: color, width: 1.5)
        list.line(x1: cx - s * 0.16, y1: stemBottom, x2: cx + s * 0.16, y2: stemBottom,
                  color: color, width: 1.5)
        if muted {
            list.line(
                x1: frame.x + frame.w * 0.2, y1: frame.y + frame.h * 0.82,
                x2: frame.x + frame.w * 0.8, y2: frame.y + frame.h * 0.18,
                color: accent, width: 2
            )
        }
    }
}
