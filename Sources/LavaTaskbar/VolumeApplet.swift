import Foundation
import LavaUI

/// Panel sound control: speaker glyph, scroll to change volume, click for a
/// popover with slider + mute. Talks to PulseAudio via `PulseSession`.
///
/// `isOpen` is owned by the panel (not local `@State`) so opening the popover
/// deepens the compositor input region — otherwise the panel only receives
/// hits on the 32pt strip and the dropdown paints into dead space.
struct VolumeApplet: View {
    var pulse: PulseSession
    var isOpen: Binding<Bool>

    var body: some View {
        // Read on the body path so Observation invalidates when Pulse posts
        // a new level (the paint closure alone is not tracked).
        let volume = pulse.volume
        let muted = pulse.muted
        let theme = Theme.current
        let open = isOpen

        // Presenter height must reach the strip bottom. A short 22pt canvas is
        // centred in the 32pt bar, so "overlay below" started mid-strip and the
        // popover sat a few pixels into the taskbar (calendar is fine — padded
        // text already fills the cross-axis). Match that with padding + a full
        // strip-tall hit box; the glyph still paints inside the canvas.
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
                        open.wrappedValue.toggle()
                    }
                },
                onWheel: { _, dy, _, _ in
                    // Positive dy = scroll up = louder. One notch ≈ 5%.
                    let step: Float = dy > 0 ? 0.05 : -0.05
                    pulse.adjustVolume(by: step)
                    if pulse.muted && step > 0 { pulse.setMuted(false) }
                },
                paint: { list, frame in
                    VolumeGlyph.paint(
                        list: list, frame: frame,
                        volume: volume, muted: muted,
                        color: muted ? theme.textDim : theme.textPrimary,
                        accent: theme.accent
                    )
                }
            )
        }
        .padding(2)
        .hoverBackground(MenuBarStyle.panel().titleHover)
        .cornerRadius(6)
        .agentId("applet.volume")
        .overlay(
            isPresented: isOpen,
            alignment: .below,
            style: {
                var s = MenuBarStyle.panel().overlayStyle
                s.padding = 10
                s.minWidth = 200
                return s
            }()
        ) {
            volumePopover
        }
    }

    @ViewBuilder
    private var volumePopover: some View {
        let theme = Theme.current
        VStack(padding: 4, spacing: 10) {
            HStack(padding: 0, alignment: .center, spacing: 8) {
                Text(
                    pulse.muted ? "Muted" : "Volume",
                    color: theme.textPrimary
                )
                Spacer()
                Text(
                    pulse.percentLabel,
                    color: pulse.muted ? theme.textDim : theme.accent
                )
            }

            Slider(
                value: pulse.volumeBinding,
                in: 0...1.5,
                step: 0.01,
                format: { "\(Int(($0 * 100).rounded()))%" }
            )

            // Mute is a full-width control: the toggle's label is part of the
            // hit target, which is what you want when the glyph is tiny.
            Toggle("Mute", isOn: pulse.mutedBinding)

            if !pulse.sinkName.isEmpty {
                Text(pulse.sinkName, color: theme.textDim)
                    .padding(2)
            }

            if !pulse.isReady {
                Text("Connecting to PulseAudio…", color: theme.textDim)
            }
        }
    }
}

/// Vector speaker + level arcs drawn into a `DrawList`.
enum VolumeGlyph {
    static func paint(
        list: DrawList, frame: CanvasFrame,
        volume: Float, muted: Bool,
        color: Color, accent: Color
    ) {
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
}
