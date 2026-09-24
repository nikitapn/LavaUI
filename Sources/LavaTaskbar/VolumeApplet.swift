import Foundation
import LavaUI

/// Panel sound control: speaker glyph, scroll to change volume, click for a
/// window with slider + mute. Talks to PulseAudio via `PulseSession`.
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
        .hoverBackground(TaskbarChrome.style.titleHover)
        .cornerRadius(6)
        .agentId("applet.volume")
    }
}

/// The sound window. Same process as the panel, so it reads `PulseSession`
/// directly — a second process would have to be told the level on every tick.
///
/// The wash is the frosted menu's, not an opaque fill. The compositor
/// frosts the desktop behind this surface; a solid background would hide
/// that plate completely. `WindowBackdrop` cannot say so per window — the
/// panel is `.none` and that setting is the whole process.
struct VolumeWindow: View {
    var pulse: PulseSession

    var body: some View {
        let theme = Theme.current
        VStack(flexGrow: 1, padding: 16, spacing: 10) {
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

            Spacer()
        }
        .background(TaskbarChrome.popupWash)
        .agentId("volume.window")
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
