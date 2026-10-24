import Foundation
import LavaShell
import LavaUI

/// Panel sound control: speaker glyph, scroll to change volume, right click
/// to mute, click for the sound window — outputs, inputs and applications.
/// Talks to PulseAudio via `PulseSession`.
///
/// The window is a surface of this process, not a dropdown painted into the
/// strip. The strip is 32pt; a slider does not fit there, and growing the
/// panel to hold it is what made the top of the screen a transparent window.
struct VolumeApplet: View {
    var pulse: PulseSession

    var body: some View {
        // Read on the body path so Observation invalidates when Pulse posts
        // a new level (the paint closure alone is not tracked).
        let volume = pulse.volume
        let muted = pulse.muted
        let theme = Theme.current

        // Presenter height must reach the strip bottom. A short 22pt canvas is
        // centred in the 32pt bar, so a hit box that stopped at the glyph
        // missed the padding around it.
        HStack(height: .pt(36), padding: 0, alignment: .center) {
            Canvas(
                label: "volume",
                width: .pt(36),
                height: .pt(22),
                onGesture: { gesture in
                    guard gesture.phase == .began else { return }
                    if gesture.button == PointerButton.right {
                        pulse.toggleMute()
                    } else if gesture.button == PointerButton.left {
                        session.toggleVolume()
                    }
                },
                onWheel: { _, dy, _, _ in
                    // Positive dy = scroll up = louder. One notch ≈ 5%.
                    let step: Float = dy > 0 ? 0.05 : -0.05
                    pulse.adjustVolume(by: step)
                    if pulse.muted && step > 0 { pulse.setMuted(false) }
                },
                paint: { list, frame in
                    SoundGlyph.paint(
                        .speaker, list: list, frame: frame,
                        volume: volume, muted: muted,
                        color: muted ? theme.textDim : theme.textPrimary,
                        accent: theme.accent
                    )
                }
            )
        }
        .padding(2)
        .hoverBackground(PanelChrome.style.titleHover)
        .cornerRadius(6)
        .agentId("applet.volume")
    }
}

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
        ScrollView(showsIndicator: true) {
            VStack(padding: SoundBlock.padding, spacing: 0) {
                ForEach(blocks) { block in
                    row(block).frame(height: .pt(block.height))
                }
            }
        }
        .background(PanelChrome.popupWash)
        .agentId("volume.window")
    }

    @ViewBuilder
    private func row(_ block: SoundBlock) -> some View {
        let theme = Theme.current
        switch block {
        case .header(let title):
            HStack(padding: 0, alignment: .end) {
                Text(title, color: theme.textSecondary)
                    .padding(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 0))
            }
        case .divider:
            HStack(padding: 0, alignment: .center) {
                VStack(height: .pt(1)) {}
                    .flexGrow(1)
                    .background(theme.border)
            }
        case .connecting:
            HStack(padding: 0, alignment: .center) {
                Text("Connecting to PulseAudio…", color: theme.textDim)
                    .padding(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
            }
        case .outputLevel:
            levelRow(
                glyph: .speaker, muted: pulse.muted, volume: pulse.volume,
                label: "Mute output", id: "volume.mute",
                toggle: { pulse.toggleMute() },
                value: pulse.volumeBinding
            )
        case .inputLevel:
            levelRow(
                glyph: .microphone, muted: pulse.input?.muted ?? false,
                volume: pulse.input?.volume ?? 0,
                label: "Mute microphone", id: "volume.mic-mute",
                toggle: { pulse.setInputMuted(!(pulse.input?.muted ?? false)) },
                value: pulse.inputVolumeBinding
            )
        case .route(let route, let isInput):
            routeRow(route, isInput: isInput)
        case .stream(let stream):
            streamRow(stream)
        }
    }

    private func levelRow(
        glyph: SoundGlyph.Kind, muted: Bool, volume: Float, label: String, id: String,
        toggle: @escaping () -> Void, value: Binding<Float>
    ) -> some View {
        HStack(padding: 0, alignment: .center, spacing: 6) {
            muteButton(glyph: glyph, muted: muted, volume: volume, label: label, id: id, toggle: toggle)
            Slider(value: value, in: 0...1.5, step: 0.01, format: PulseSession.percent)
                .flexGrow(1)
        }
    }

    private func muteButton(
        glyph: SoundGlyph.Kind, muted: Bool, volume: Float, label: String, id: String,
        size: Float = 22, toggle: @escaping () -> Void
    ) -> some View {
        let theme = Theme.current
        return HStack(padding: 2, alignment: .center, onClick: toggle) {
            Canvas(label: label, width: .pt(size), height: .pt(size)) { list, frame in
                SoundGlyph.paint(
                    glyph, list: list, frame: frame, volume: volume, muted: muted,
                    color: muted ? theme.textDim : theme.textPrimary, accent: theme.accent
                )
            }
        }
        .hoverBackground(theme.hover)
        .cornerRadius(6)
        .cursor(.pointer)
        .tooltip(muted ? "Unmute" : "Mute")
        .agentId(id)
    }

    private func routeRow(_ route: SoundRoute, isInput: Bool) -> some View {
        let theme = Theme.current
        let current = route.isCurrent
        return HStack(
            padding: 0, alignment: .center, spacing: 8,
            onClick: { isInput ? pulse.selectInput(route) : pulse.selectOutput(route) }
        ) {
            Canvas(label: "radio", width: .pt(12), height: .pt(12)) { list, frame in
                let cx = frame.x + frame.w * 0.5
                let cy = frame.y + frame.h * 0.5
                list.circle(cx: cx, cy: cy, radius: 6, color: current ? theme.accent : theme.border)
                list.circle(cx: cx, cy: cy, radius: 4.5, color: theme.panel)
                if current { list.circle(cx: cx, cy: cy, radius: 3, color: theme.accent) }
            }
            .flexShrink(0)
            Text(route.title, color: current ? theme.textPrimary : theme.textSecondary, lineLimit: 1)
                .flexShrink(0)
            if !route.subtitle.isEmpty {
                Text(route.subtitle, color: theme.textDim, lineLimit: 1)
                    .flexShrink(1)
            }
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .hoverBackground(theme.hover)
        .cornerRadius(6)
        .cursor(.pointer)
        .agentId((isInput ? "volume.input." : "volume.output.") + route.id)
    }

    private func streamRow(_ stream: SoundStream) -> some View {
        let theme = Theme.current
        return HStack(padding: 0, alignment: .center, spacing: 6) {
            muteButton(
                glyph: .speaker, muted: stream.muted, volume: stream.volume,
                label: "Mute \(stream.title)", id: "volume.stream-mute.\(stream.id)", size: 18,
                toggle: { pulse.setStreamMuted(stream, !stream.muted) }
            )
            Text(stream.title, color: stream.muted ? theme.textDim : theme.textPrimary, lineLimit: 1)
                .frame(width: .pt(92))
                .flexShrink(0)
            Slider(
                value: pulse.streamVolumeBinding(stream), in: 0...1.5, step: 0.01,
                format: PulseSession.percent
            )
            .flexGrow(1)
        }
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
    static let width: Float = 340
    static let maxHeight: Float = 560

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
        case .header: return 26
        case .divider: return 13
        case .connecting: return 30
        case .outputLevel, .inputLevel: return 32
        case .route: return 30
        case .stream: return 32
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

/// Vector speaker + level arcs drawn into a `DrawList`.
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
        let cx = frame.x + frame.w * 0.38
        let cy = frame.y + frame.h * 0.5
        let s = min(frame.w, frame.h)

        // Body: small rounded rect (magnet).
        let bodyW = s * 0.22
        let bodyH = s * 0.38
        list.roundedRect(
            x: cx - bodyW * 0.9, y: cy - bodyH * 0.5,
            w: bodyW, h: bodyH,
            color: color, radius: 2
        )

        // Horn: triangle via a thick polyline-ish stack of short rects
        // (no triangle primitive). Approximate with a widening ramp.
        let hornBase = cx + bodyW * 0.15
        let steps = 5
        for i in 0..<steps {
            let t = Float(i) / Float(steps)
            let x = hornBase + t * s * 0.22
            let h = bodyH * (0.45 + t * 0.7)
            let w = s * 0.06
            list.rect(
                x: x, y: cy - h * 0.5, w: w, h: h, color: color
            )
        }

        if muted {
            // Slash.
            let x0 = frame.x + frame.w * 0.15
            let y0 = frame.y + frame.h * 0.78
            let x1 = frame.x + frame.w * 0.85
            let y1 = frame.y + frame.h * 0.22
            // Two short rects as a diagonal bar.
            for i in 0..<8 {
                let t = Float(i) / 7
                let x = x0 + (x1 - x0) * t
                let y = y0 + (y1 - y0) * t
                list.rect(x: x - 1.2, y: y - 1.2, w: 2.4, h: 2.4, color: accent)
            }
            return
        }

        // Level arcs — rings that light with volume.
        let level = min(1, max(0, volume))
        let rings = 3
        for i in 0..<rings {
            let threshold = Float(i + 1) / Float(rings + 1)
            let on = level + 0.001 >= threshold
            let ringColor = on ? color : color.opacity(0.2)
            let r = s * (0.28 + Float(i) * 0.14)
            // Approximate arc as a few dots on the right side.
            let dots = 5
            for d in 0..<dots {
                let a = Float.pi * (-0.45 + 0.9 * Float(d) / Float(dots - 1))
                let px = cx + cos(a) * r + s * 0.08
                let py = cy + sin(a) * r
                list.circle(cx: px, cy: py, radius: on ? 1.4 : 1.0, color: ringColor)
            }
        }
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
