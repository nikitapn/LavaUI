import Foundation
import LavaUI
import LavaViewCore

/// The buttons, centred along the bottom.
///
/// Grouped the way the old Windows viewer grouped them — the zoom pair, then
/// the fit toggle, then Previous / Stop / Next, then the rotates — because
/// that is where the muscle memory is. What is *not* copied is the delete
/// button, which sat one pixel from Next and deleted the photograph you were
/// looking at.
///
/// **Nothing variable is allowed in this row**, and that is the whole design.
/// Centring between two `Spacer`s only holds still if the thing being centred
/// is a constant width, so every control here states one — 52 for the
/// percentage (which is three characters at `44%` and four at `132%`), 44 for
/// a mode, 30 for an icon — and everything whose width depends on the picture
/// lives in `TitleBar` instead. Add a label here and the buttons start walking
/// again the moment the folder is stepped through.
struct ControlBar: View {
    @Bindable var session: ViewerSession

    static let height: Float = 44

    var body: some View {
        HStack(height: .pt(Self.height), padding: 8, alignment: .center, spacing: 6) {
            Spacer()
            zoomGroup
            separator
            modeGroup
            separator
            transportGroup
            separator
            rotateGroup
            Spacer()
        }
        .background(Theme.current.panel)
    }

    // MARK: - Groups

    private var zoomGroup: some View {
        HStack(alignment: .center, spacing: 2) {
            iconButton("−", hint: "Zoom out", id: "zoom-out") { session.stepZoom(-1) }
            // Clicking the percentage is the fastest way back to a known
            // number, and it is where everyone looks for it.
            // Centred, so the number grows symmetrically rather than
            // rightward from a fixed left edge as it goes 40% → 100% → 132%.
            // `.padding` *before* `.frame`, which is not a stylistic
            // preference. The other way round means "a 52pt box, and then 4pt
            // outside it", which one node cannot be — so a wrapper appears,
            // the hover fill lands on it at 60pt, and the clickable `Text`
            // keeps its own automatic hover fill at the width of the digits.
            // Two rounded rectangles, one inside the other, and only the inner
            // one clickable. Padding first is one node: 60pt to look at, to
            // hover and to click.
            Text("\(session.zoomPercent)%", color: Theme.current.textSecondary,
                 align: .center,
                 onClick: { session.setMode(.actual) })
                .padding(4)
                .frame(width: .pt(60))
                .hoverBackground(Theme.current.hover)
                .cornerRadius(4)
                .cursor(.pointer)
                .agentId("zoom-percent")
            iconButton("+", hint: "Zoom in", id: "zoom-in") { session.stepZoom(1) }
        }
    }

    /// The two modes the request was actually about. A pair of latching
    /// buttons rather than one toggle: a toggle shows the state you are *not*
    /// in, and every viewer that has tried it has confused someone.
    private var modeGroup: some View {
        HStack(alignment: .center, spacing: 2) {
            modeButton("Fit", mode: .fit, id: "mode-fit")
            modeButton("1:1", mode: .actual, id: "mode-actual")
        }
    }

    private var transportGroup: some View {
        HStack(alignment: .center, spacing: 2) {
            iconButton("◀", hint: "Previous", id: "previous", enabled: session.folder.count > 1) {
                session.step(-1)
            }
            iconButton("◼", hint: "Fit to window", id: "reset") {
                session.setMode(.fit)
            }
            iconButton("▶", hint: "Next", id: "next", enabled: session.folder.count > 1) {
                session.step(1)
            }
        }
    }

    private var rotateGroup: some View {
        HStack(alignment: .center, spacing: 2) {
            iconButton("↺", hint: "Rotate left", id: "rotate-left", enabled: canRotate) {
                session.rotateLeft()
            }
            iconButton("↻", hint: "Rotate right", id: "rotate-right", enabled: canRotate) {
                session.rotateRight()
            }
        }
    }

    private var canRotate: Bool { session.hasImage && !session.isBusy }

    private var separator: some View {
        Divider(.vertical)
            .frame(height: .pt(20))
    }

    // MARK: - Parts

    private func modeButton(_ title: String, mode: ZoomMode, id: String) -> some View {
        let theme = Theme.current
        let active = session.mode == mode
        return Text(
            title,
            color: active ? theme.textPrimary : theme.textSecondary,
            // `Text(align:)` and **not** `.frame(width:alignment:)`. The
            // frame's alignment centres by wrapping this in a box it does not
            // own — the width, the fill, the hover and the cursor all move out
            // to that box while `onClick` stays here, so the button ends up
            // 44pt wide to look at and 27pt wide to click. This moves the pen
            // inside the node that is already here and adds nothing.
            align: .center,
            onClick: { session.setMode(mode) }
        )
        .padding(6)
        .frame(width: .pt(44))
        // `selectionFill`, and specifically **not** `selected`.
        //
        // `selected` is a *foreground* colour in every palette — a bright
        // amber in `dark`, `graphite`, `ember` and `moss`, a bright pink in
        // `nebula` — meant for the text that marks where you are. Filling a
        // button with it and putting near-white `textPrimary` on top is
        // light-on-light, and the label all but disappears. `selectionFill` is
        // the token for a fill that text sits on (it is what a text selection
        // is painted with), and it is mid-dark in the dark palettes and light
        // in the light ones, so `textPrimary` reads against it either way.
        .background(active ? theme.selectionFill : theme.panel)
        // Hover stays distinguishable from active: `theme.hover` on the
        // inactive one would otherwise be the same look as the latched one,
        // which is exactly the state a pair of latching buttons must not blur.
        .hoverBackground(active ? theme.selectionFill : theme.hover)
        .cornerRadius(4)
        .cursor(.pointer)
        .agentId(id)
    }

    private func iconButton(
        _ glyph: String, hint: String, id: String,
        enabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        Text(
            glyph,
            color: enabled ? Theme.current.textSecondary : Theme.current.textDim,
            onClick: enabled ? action : nil
        )
        .padding(6)
        .frame(width: .pt(30))
        .hoverBackground(enabled ? Theme.current.hover : Theme.current.panel)
        .cornerRadius(4)
        .cursor(enabled ? .pointer : .arrow)
        .agentId(id)
    }
}
