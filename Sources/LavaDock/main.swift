#if canImport(CxxCanvas) && canImport(LavaIDL)
import Foundation
import LavaClient
import LavaIDL
import LavaUI
import Observation

// The desktop's dock: what is open on this workspace, as icons, at the bottom
// of the screen.
//
//   terminal 1:  compositor/scripts/dev-run
//   terminal 2:  swift run LavaDock
//
// Like the panel next door it is an ordinary client with no privileges — it
// publishes draw lists into a shared arena and reads input off a stream. What
// makes a *shell* possible is not privilege but three calls the control plane
// grew for it:
//
//   * `SubscribeWindows` — which windows exist, and on which workspace. The
//     compositor is the only process that knows, and a dock is the first thing
//     that cannot be written without it.
//   * `ActivateWindow` — bring one forward. Also what finally makes `Minimize`
//     useful: before this, a hidden window was a window nothing could name.
//   * `SetInputRegion` — take clicks only where the icons are. A dock floats
//     over the desktop, and panels are hit-tested above windows, so without it
//     the empty half of the strip swallows every click aimed at what is under
//     it.
//
// Auto-hide falls out of the last one plus `PointerLeave`: hidden, the dock
// accepts input in a sliver along the screen's edge; the pointer entering it is
// the reveal, and the pointer leaving the dock is the hide.

/// One entry: an application, and the windows it has open.
///
/// Grouped by `appId` because that is what an application *is* to a dock — two
/// windows of one editor are one icon with two windows behind it, and clicking
/// it means "show me that application", not "show me its third window".
struct DockEntry: Identifiable {
    var id: String { appId }
    var appId: String
    var title: String
    var windows: [WindowInfo]

    var isFocused: Bool { windows.contains { $0.focused } }
    var isMinimized: Bool { windows.allSatisfy { $0.minimized } }

    /// Which window a click should raise: the focused one if this application
    /// already has it, else the first that is not hidden, else the first.
    /// Clicking an application should land somewhere predictable rather than
    /// wherever the compositor happened to list first.
    var primary: WindowInfo? {
        windows.first { $0.focused }
            ?? windows.first { !$0.minimized }
            ?? windows.first
    }
}

@Observable
final class DockModel {
    /// What the dock draws, in a stable order.
    var entries: [DockEntry] = []
    /// Whether the dock is out. Hidden, it is a sliver of input along the
    /// bottom edge and nothing on screen.
    var revealed = false

    @ObservationIgnored var editor: Editor?
    @ObservationIgnored private var icons: [String: UIImage?] = [:]

    /// The compositor's snapshot, filtered to this workspace and grouped.
    func apply(workspace: UInt32, windows: [WindowInfo]) {
        // Only what is open *here*. A dock showing another workspace's windows
        // is offering to switch the user somewhere they did not ask to go.
        let mine = windows.filter { $0.workspace == workspace }

        var order: [String] = []
        var grouped: [String: DockEntry] = [:]
        for window in mine {
            // A window with no app id still deserves an entry — it is open, and
            // the user can see it. Keyed by surface so two anonymous windows do
            // not collapse into one icon that means neither.
            let key = window.appId.isEmpty ? "window:\(window.surfaceId)" : window.appId
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = DockEntry(appId: key, title: window.title,
                                         windows: [window])
            } else {
                grouped[key]?.windows.append(window)
            }
        }
        entries = order.compactMap { grouped[$0] }
        // The dock is painted by a `Canvas` closure, which reads this model at
        // emit time rather than through a body — so observation has nothing to
        // notice and no frame would be drawn. Asking here is what makes a
        // window opening visible at all.
        ViewInvalidation.markNeedsRedraw()
    }

    /// The icon for an entry, loaded once. Nil means "draw its initial".
    func icon(for entry: DockEntry) -> UIImage? {
        if let cached = icons[entry.appId] { return cached }
        var image: UIImage? = nil
        // The raw app id, not the synthesised `window:` key — an anonymous
        // window has nothing to look up.
        if !entry.appId.hasPrefix("window:"),
           let path = IconLookup.iconPath(forAppId: entry.appId),
           let editor
        {
            // Rendered at the size the dock magnifies *to*, not the size it
            // rests at: an SVG costs the same either way and a raster icon
            // scaled up is the thing this avoids.
            image = editor.resources.registerImage(
                path: path, maxPixelSize: UInt32(Dock.magnifiedSize)
            )
        }
        icons[entry.appId] = image
        return image
    }
}

nonisolated(unsafe) let model = DockModel()

/// The dock's geometry, in one place so the drawing and the input region
/// cannot drift.
enum Dock {
    /// Resting icon size, and what the pointer magnifies one to.
    static let iconSize: Float = 48
    static let magnifiedSize: Float = 76
    /// How far along the row the magnification reaches. Two icons either side
    /// is what reads as a lens rather than a jump.
    static let lensWidth: Float = 110
    static let spacing: Float = 12
    static let padding: Float = 10
    /// Height of the surface. Tall enough for a magnified icon plus its
    /// indicator and the shadow's worth of breathing room above the edge.
    static let height: Float = magnifiedSize + padding * 2 + 14
    /// How deep the strip is that reveals the dock when the pointer enters it.
    /// One pixel is enough to be *entered*, and too little to be aimed at.
    static let triggerHeight: Float = 3

    /// The dock's own rounded plate, centred on the surface.
    static func plate(entries: Int, surfaceWidth: Float) -> (x: Float, w: Float) {
        let count = Float(max(entries, 1))
        let width = count * iconSize + (count - 1) * spacing + padding * 2
        return ((surfaceWidth - width) * 0.5, width)
    }

    /// Where an icon rests, before magnification.
    static func restingCenter(index: Int, plateX: Float) -> Float {
        plateX + padding + iconSize * 0.5 + Float(index) * (iconSize + spacing)
    }

    /// How big an icon is with the pointer at `pointerX`.
    ///
    /// A raised cosine over the lens width: 1 at the edges of its reach and 0
    /// outside, so an icon grows and shrinks continuously as the pointer
    /// travels rather than popping at a threshold.
    static func size(center: Float, pointerX: Float?) -> Float {
        guard let pointerX else { return iconSize }
        let distance = abs(center - pointerX)
        guard distance < lensWidth else { return iconSize }
        let t = distance / lensWidth
        let falloff = 0.5 * (1 + cos(t * Float.pi))
        return iconSize + (magnifiedSize - iconSize) * falloff
    }
}

/// The region last handed to the compositor, so an unchanged one costs
/// nothing. Outside the view because a `View` is a value rebuilt every frame.
nonisolated(unsafe) var appliedRegion: (x: Float, y: Float, w: Float, h: Float) =
    (-1, -1, -1, -1)

struct DockView: View {
    var body: some View {
        // Read here, not only in `paint`: a paint closure runs at emit and is
        // invisible to observation, so a body that never mentions the model is
        // a view that never rebuilds when it changes.
        let revealed = model.revealed
        return Canvas(
            label: "Dock",
            flexGrow: 1,
            // Only while it is out, and then every frame: magnification tracks
            // the pointer continuously, and a pointer that merely *moves*
            // invalidates nothing on its own — there is no state change to
            // notice, just a new position to draw against. Hidden, the dock
            // draws nothing and asks for nothing.
            continuousRedraw: revealed,
            onGesture: { gesture in
                switch gesture.phase {
                case .began, .moved:
                    reveal()
                case .ended:
                    activate(atX: gesture.localX, frameWidth: gesture.frame.w)
                }
            },
            onHover: { inside in
                // The pointer arriving is the only thing a hidden dock ever
                // hears: its input region is a three-pixel strip along the
                // screen's edge, so being hovered at all *is* the approach.
                if inside { reveal() }
            },
            paint: { list, frame in paint(list, frame) }
        )
        .agentId("dock")
    }

    /// Brings the dock out. What it accepts input in follows on the next
    /// paint, from the geometry that paint uses — see `syncInputRegion`.
    private func reveal() {
        guard !model.revealed else { return }
        model.revealed = true
        ViewInvalidation.markNeedsRedraw()
    }

    private func paint(_ list: DrawList, _ frame: CanvasFrame) {
        let entries = model.entries
        let plate = Dock.plate(entries: max(entries.count, 1),
                               surfaceWidth: frame.w)
        // Where the dock takes clicks is decided *here*, from the geometry it
        // is about to draw with. The two were computed separately once — the
        // plate from the canvas's real width, the region from a width polled
        // into a variable — and they disagreed by the difference between the
        // requested size and the one the compositor gave, which put the
        // clickable strip a few hundred pixels from the icons.
        syncInputRegion(plate: plate, frame: frame, hasEntries: !entries.isEmpty)

        guard model.revealed, !entries.isEmpty else { return }

        let theme = Theme.current
        // Sits on the bottom edge with its own padding, the way a dock does —
        // flush against the screen looks like a strip rather than a thing
        // resting on it.
        let plateH = Dock.iconSize + Dock.padding * 2
        let plateY = frame.y + frame.h - plateH - 6
        let radius = max(WindowBridge.desktopCornerRadius, 12)

        list.roundedRect(
            x: frame.x + plate.x, y: plateY, w: plate.w, h: plateH,
            color: Color(r: theme.panel.r, g: theme.panel.g, b: theme.panel.b,
                         a: 0.88),
            radius: radius
        )

        // The pointer's own position, read at paint time. A `Canvas` hears
        // about motion only inside a press, and a dock magnifies under a
        // pointer that is merely passing.
        let pointer: Float? = PointerState.window.x

        for (index, entry) in entries.enumerated() {
            let center = frame.x + Dock.restingCenter(index: index, plateX: plate.x)
            let size = Dock.size(center: center, pointerX: pointer)
            // Magnified icons grow *upwards* out of the plate, which is what
            // keeps their feet on one line and the row from looking loose.
            let bottom = plateY + plateH - Dock.padding
            let rect = (x: center - size * 0.5, y: bottom - size, w: size, h: size)

            if let icon = model.icon(for: entry) {
                list.image(textureId: icon.textureId, x: rect.x, y: rect.y,
                           w: rect.w, h: rect.h)
            } else {
                // No icon anywhere on the system for this application. Its
                // initial in a tile reads as deliberate, where a blank square
                // reads as broken.
                list.roundedRect(x: rect.x, y: rect.y, w: rect.w, h: rect.h,
                                 color: theme.accent, radius: size * 0.22)
                let letter = String(entry.title.prefix(1)).uppercased()
                list.text(letter, x: rect.x + size * 0.32,
                          y: rect.y + size * 0.24, w: size, h: size,
                          color: theme.background)
            }

            if entry.isMinimized {
                // Hidden windows are still open, and a dock that showed them
                // exactly like visible ones would be lying about the desktop.
                list.roundedRect(x: rect.x, y: rect.y, w: rect.w, h: rect.h,
                                 color: Color(r: theme.background.r,
                                              g: theme.background.g,
                                              b: theme.background.b, a: 0.45),
                                 radius: size * 0.22)
            }

            // The running indicator: one dot, brighter for the focused
            // application. Under the icon rather than on it, so it survives
            // whatever the icon happens to look like.
            let dotY = plateY + plateH + 3
            list.circle(cx: center, cy: dotY, radius: entry.isFocused ? 3 : 2,
                        color: entry.isFocused ? theme.accent : theme.textDim)
        }
    }

    /// Keeps the compositor's idea of where this dock is clickable in step
    /// with where it draws.
    ///
    /// Hidden, that is a sliver along the screen's edge — the strip the pointer
    /// has to reach to bring the dock out, and nothing else, so a click aimed
    /// at a window near the bottom of the screen is not eaten by an invisible
    /// panel. Revealed, it is the plate.
    private func syncInputRegion(plate: (x: Float, w: Float), frame: CanvasFrame,
                                 hasEntries: Bool) {
        let region: (x: Float, y: Float, w: Float, h: Float) =
            model.revealed && hasEntries
                ? (plate.x, 0, plate.w, frame.h)
                : (0, frame.h - Dock.triggerHeight, frame.w, Dock.triggerHeight)
        guard region != appliedRegion else { return }
        appliedRegion = region
        LavaClient.setInputRegion(x: region.x, y: region.y,
                                  width: region.w, height: region.h)
    }

    /// Which entry is under `x`, and what clicking it means.
    private func activate(atX x: Float, frameWidth: Float) {
        let entries = model.entries
        guard model.revealed, !entries.isEmpty else { return }
        let plate = Dock.plate(entries: entries.count, surfaceWidth: frameWidth)
        for (index, entry) in entries.enumerated() {
            let center = Dock.restingCenter(index: index, plateX: plate.x)
            let size = Dock.size(center: center, pointerX: x)
            guard abs(center - x) <= size * 0.5 else { continue }
            guard let window = entry.primary else { return }
            // Clicking the application you are already in puts it away, which
            // is the gesture every dock has: the icon is a toggle, not a
            // one-way trip.
            if window.focused && !window.minimized {
                LavaClient.minimizeWindow(window.surfaceId)
            } else {
                LavaClient.activateWindow(window.surfaceId)
            }
            return
        }
    }
}

// ─── Bring-up ───────────────────────────────────────────────────────────────

// Nothing behind the dock but what it draws: the surface is a full-width strip
// and the plate is a fraction of it, so a background fill would be a grey band
// across the desktop.
WindowBackdrop.current = .none

guard let editor = LavaClient.openPanel(
    title: "Lava Dock", edge: .bottom, thickness: Dock.height, reserve: false
) else { exit(1) }

model.editor = editor

LavaClient.onWindowList { workspace, windows in
    model.apply(workspace: workspace, windows: windows)
}

// The pointer leaving is the only way a dock learns to put itself away: it
// hears about the pointer while it is inside and nothing at all afterwards.
PointerState.onLeave = {
    MainQueue.async {
        guard model.revealed else { return }
        model.revealed = false
        ViewInvalidation.markNeedsRedraw()
    }
}

LavaClient.run(editor: editor) { DockView() }
#else
print("LavaDock needs CxxCanvas and the NPRPC control plane (Linux).")
#endif
