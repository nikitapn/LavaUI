import Foundation
import LavaClient
import LavaIDL
import LavaShell
import LavaUI
import Observation

// The desktop's dock: what is open on this workspace, as icons, at the bottom
// of the screen — plus the applications the user pinned *here*, which stay
// even when they have no window. Pins are per workspace, so a work desk
// and a home desk keep different ones.
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
// accepts input in a sliver along the screen's edge; the pointer reaching the
// part of that sliver the dock is actually under is the reveal, and the pointer
// leaving the dock is the hide. Those two bounds differ on purpose — see
// `Dock.revealInset`.
//
// Reordering is a captured drag along the plate. The compositor already
// keeps the pointer on the surface that received the press, so motion
// after the icon leaves the plate still arrives. What cannot leave is
// *paint*: the dock is a 138pt strip, and a client cannot draw on the
// desktop above it. The dragged icon therefore slides on the plate (and
// lifts a little inside the strip). Dragging off the top of the plate
// unpins; a flying icon that followed the pointer up the screen would
// need `SetPanelThickness`, which is how the window preview next door
// gets its room — see `WindowPreview.swift`.

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
    var pinned: Bool
    /// The window of this stack that was in front last. Zero until one has
    /// been. Stamped on by the model — see `DockModel.lastActive`.
    var lastActiveSurface: UInt32 = 0

    var isRunning: Bool { !windows.isEmpty }
    var isFocused: Bool { windows.contains { $0.focused } }
    var isMinimized: Bool {
        !windows.isEmpty && windows.allSatisfy { $0.minimized }
    }
    var canPin: Bool { DockPins.canPin(appId) }

    /// Which window a click should raise: the focused one if this application
    /// already has it, else the one that was in front the last time it did,
    /// else the first that is not hidden, else the first.
    ///
    /// The remembered window comes before the first visible one on purpose.
    /// Coming back to an application means coming back to where you left it,
    /// and "where you left it" is a stack's second window as often as its
    /// first — which is all `windows.first` could ever offer.
    var primary: WindowInfo? {
        windows.first { $0.focused }
            ?? windows.first { $0.surfaceId == lastActiveSurface }
            ?? windows.first { !$0.minimized }
            ?? windows.first
    }
}

/// A press that might become a reorder, or already has.
struct DockDrag {
    var appId: String
    var fromIndex: Int
    /// Slot the hole is in, in the full row. Neighbours slide toward
    /// this rather than packing into a shorter plate.
    var dest: Int
    var startX: Float
    var startY: Float
    var pointerX: Float
    var pointerY: Float
    /// False until the pointer has moved past slop — a click must not
    /// shuffle the row.
    var active: Bool
}

/// Right-click menu, parked at the icon that opened it.
struct DockContextMenu {
    var appId: String
    var x: Float
}

@Observable
final class DockModel {
    /// What the dock draws, in a stable order: pins first, then the
    /// running applications that are not pinned.
    var entries: [DockEntry] = []
    /// Whether the dock is out. Hidden, it is a sliver of input along the
    /// bottom edge and nothing on screen.
    var revealed = false

    /// Whether a window is in the way of the dock's strip, as the compositor
    /// sees it — `SubscribePanelArea`.
    ///
    /// Auto-hide is the right behaviour when something is under the dock and
    /// the wrong one when the desktop below it is empty: there is nothing to
    /// get out of the way of, and a dock that hides from bare wallpaper is
    /// just a dock you have to go and fetch. False keeps it out.
    var covered = false

    /// Whether the pointer is on the dock. Tracked because "hidden" now has
    /// two possible reasons and only one of them is the pointer's.
    var pointerInside = false

    var drag: DockDrag?
    var menu: DockContextMenu?
    /// The window shelf that is up, if one is. See `WindowPreview.swift`.
    var preview: DockPreview?
    /// True while neighbour icons are still catching up to a hole.
    /// Drives `continuousRedraw` for the few hundred milliseconds a
    /// slide lasts — not while the dock is merely out.
    var sliding = false

    /// Out because nothing is in the way, rather than because the pointer is
    /// here. The distinction matters on the way back: the pointer leaving
    /// must not put away a dock that was never hiding.
    var showsBecauseClear: Bool { !covered && !entries.isEmpty }

    /// Per-icon X, so a dest change eases rather than jumps.
    @ObservationIgnored var iconSlide: [String: Animated<Float>] = [:]
    /// The pin/unpinned divider follows the same ease as the icons.
    @ObservationIgnored var separatorSlide: Animated<Float>?

    @ObservationIgnored var editor: Editor?
    @ObservationIgnored private var icons: [String: UIImage?] = [:]
    @ObservationIgnored var pins = DockPins()
    @ObservationIgnored var catalog: [String: DesktopEntry] = [:]
    @ObservationIgnored private var lastWindows: [WindowInfo] = []
    @ObservationIgnored private var lastWorkspace: UInt32 = 0

    /// Which window of each stack was in front last, by app id.
    ///
    /// The compositor knows what is focused *now*; nothing but the dock keeps
    /// what was focused in an application you have since left, and that is
    /// exactly what clicking its icon should go back to.
    @ObservationIgnored private var lastActive: [String: UInt32] = [:]
    /// Windows each stack has been told to minimize but has not yet been seen
    /// to, by app id.
    ///
    /// Minimizing hands focus to whatever is left, and for a stack of three
    /// that is twice another window of the same stack: the compositor drops
    /// focus, walks its history, and lands on this application's next window
    /// because that is genuinely what the user was in last. Those snapshots
    /// are true — the window really was in front for a moment — and recording
    /// them would replace the id the click just saved with the last one the
    /// stack happened to shed on the way down. So nothing is recorded for a
    /// stack until every window it was told to put away is away, which is the
    /// state the click asked for. Windows that closed meanwhile stop counting;
    /// windows that opened meanwhile were never named and never block.
    @ObservationIgnored private var minimizingAll: [String: Set<UInt32>] = [:]
    /// Last canvas width, so a wheel can resolve which icon it is over.
    @ObservationIgnored var lastFrameWidth: Float = 0
    @ObservationIgnored private var badgeFontCache: UIFont?

    // ─── Window preview ──────────────────────────────────────────────────
    //
    // Paint owns the geometry — see `Dock.previewLayout` — and hands the
    // last one back here, because everything that is not paint (the hit
    // test for a click, the question "is the pointer still on the shelf")
    // needs the same rectangles and must not compute a second set from a
    // frame it has not seen.

    /// The icon the pointer is resting on and since when. Cleared the moment
    /// it moves to another one, so the delay is per icon rather than per
    /// visit to the dock.
    @ObservationIgnored var hoverCandidate: (appId: String, since: Double)?
    /// Which app a shelf has been *asked* for. Opening grows the panel and
    /// talks to the compositor, so it happens after the frame rather than
    /// inside paint; this is what stops paint asking again every frame in
    /// the meantime.
    @ObservationIgnored var previewRequest: String?
    /// One `ImageSurface` name per window on the shelf. Not pixels: the
    /// compositor resolves these when it replays the draw list.
    @ObservationIgnored var previewPosters: [UInt32: UIImage] = [:]
    /// The shelf as it was last painted, for hit-testing.
    @ObservationIgnored var previewLayout: Dock.PreviewLayout?
    /// Top of the plate as paint last placed it. The band between it and the
    /// shelf is a bridge the pointer crosses, and letting go of the shelf
    /// halfway across it is the bug this avoids.
    @ObservationIgnored var plateTop: Float = 0
    /// Panel thickness the compositor currently has. The dock grows for a
    /// shelf and shrinks again after — see `setPanelHeight`.
    @ObservationIgnored var panelHeight: Float = Dock.height

    func loadCatalog() {
        let installed = DesktopEntry.installed()
        IconLookup.useEntries(installed)
        var map: [String: DesktopEntry] = [:]
        for entry in installed {
            map[entry.id] = entry
            map[entry.id.lowercased()] = entry
            if !entry.startupWMClass.isEmpty {
                map[entry.startupWMClass] = entry
                map[entry.startupWMClass.lowercased()] = entry
            }
        }
        catalog = map
    }

    func entryInfo(for appId: String) -> DesktopEntry? {
        catalog[appId] ?? catalog[appId.lowercased()]
    }

    /// The compositor's snapshot, filtered to this workspace and grouped,
    /// then prefixed with whatever the user pinned.
    func apply(workspace: UInt32, windows: [WindowInfo]) {
        if workspace != lastWorkspace {
            // A drag belongs to the workspace it started on. Committing it
            // after a switch would write the other desk's pins.
            drag = nil
            menu = nil
        }
        lastWorkspace = workspace
        lastWindows = windows
        rebuildEntries()
        // A shelf about windows that are no longer a stack is a shelf about
        // nothing — and closing it is also what shrinks the panel back, which
        // a workspace switch would otherwise leave grown.
        syncPreview()
        // The dock is painted by a `Canvas` closure, which reads this model at
        // emit time rather than through a body — so observation has nothing to
        // notice and no frame would be drawn. Asking here is what makes a
        // window opening visible at all.
        ViewInvalidation.markNeedsRedraw()
    }

    func rebuildEntries() {
        let mine = lastWindows.filter { $0.workspace == lastWorkspace }

        var order: [String] = []
        var grouped: [String: DockEntry] = [:]
        for window in mine {
            // A window with no app id still deserves an entry — it is open, and
            // the user can see it. Keyed by surface so two anonymous windows do
            // not collapse into one icon that means neither.
            let key = window.appId.isEmpty
                ? "window:\(window.surfaceId)" : window.appId
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = DockEntry(
                    appId: key, title: window.title,
                    windows: [window],
                    pinned: pins.contains(key, on: lastWorkspace)
                )
            } else {
                grouped[key]?.windows.append(window)
            }
        }
        // Window order inside an icon is ours. Activate restacks the
        // compositor list, and a wheel-cycle that followed that would
        // shuffle under the pointer. Keep whoever was already here;
        // a new window of the same app appends.
        let previousWindows = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.appId, $0.windows) }
        )
        for key in grouped.keys {
            guard let incoming = grouped[key]?.windows,
                  let old = previousWindows[key]
            else { continue }
            grouped[key]?.windows = Self.stableWindowOrder(
                incoming, previous: old
            )
        }

        var next: [DockEntry] = []
        var seen = Set<String>()
        for id in pins.ids(on: lastWorkspace) {
            seen.insert(id)
            if var existing = grouped[id] {
                existing.pinned = true
                next.append(existing)
            } else {
                let named = entryInfo(for: id)
                next.append(DockEntry(
                    appId: id,
                    title: named?.name ?? id,
                    windows: [],
                    pinned: true
                ))
            }
        }
        // Unpinned order is *ours*, not the compositor's. A click focuses
        // the window and SubscribeWindows sends the list again — usually
        // with the focused app first — which used to yank that icon to
        // the left of the unpinned group. Keep whoever was already here
        // in their old places; only a new window appends.
        let stillOpen = Set(order.filter { !seen.contains($0) })
        var unpinned: [String] = []
        for entry in entries where !seen.contains(entry.appId) {
            if stillOpen.contains(entry.appId) {
                unpinned.append(entry.appId)
                seen.insert(entry.appId)
            }
        }
        for key in order where !seen.contains(key) {
            unpinned.append(key)
            seen.insert(key)
        }
        for key in unpinned {
            if var extra = grouped[key] {
                extra.pinned = false
                next.append(extra)
            }
        }
        trackActiveWindows(&next)
        entries = next
        if let drag, !next.contains(where: { $0.appId == drag.appId }) {
            self.drag = nil
        }
    }

    /// Notes which window is in front of each stack, and stamps what is
    /// remembered onto the entries so a click can read it off one.
    private func trackActiveWindows(_ list: inout [DockEntry]) {
        for entry in list {
            if let pending = minimizingAll[entry.appId] {
                let away = entry.windows
                    .filter { pending.contains($0.surfaceId) }
                    .allSatisfy(\.minimized)
                guard away else { continue }
                minimizingAll[entry.appId] = nil
            }
            if let front = entry.windows.first(where: { $0.focused && !$0.minimized }) {
                lastActive[entry.appId] = front.surfaceId
            }
        }
        // An application that closed takes its memory with it: the next
        // window it opens is a new one, and reviving a dead surface id would
        // send a click nowhere. Pinned icons with nothing open count as gone.
        let open = Set(list.filter(\.isRunning).map(\.appId))
        lastActive = lastActive.filter { open.contains($0.key) }
        minimizingAll = minimizingAll.filter { open.contains($0.key) }
        for index in list.indices {
            list[index].lastActiveSurface = lastActive[list[index].appId] ?? 0
        }
    }

    /// Raises one window and treats it as its stack's front from here on.
    ///
    /// The compositor will say so too, a frame later; writing it now is what
    /// keeps a click that lands mid-minimize from reading the older answer.
    func activateWindow(_ surfaceId: UInt32, of appId: String) {
        minimizingAll[appId] = nil
        lastActive[appId] = surfaceId
        if let index = entries.firstIndex(where: { $0.appId == appId }) {
            entries[index].lastActiveSurface = surfaceId
        }
        LavaClient.activateWindow(surfaceId)
    }

    /// Puts a whole stack away, remembering which of it was in front.
    ///
    /// Minimizing only the focused window would leave the rest of the
    /// application on screen, which is not what clicking its icon means: the
    /// gesture is "put this application away", and the one it comes back to
    /// is the one it went away from.
    func minimizeStack(_ entry: DockEntry) {
        guard let front = entry.windows.first(where: { $0.focused && !$0.minimized })
        else { return }
        lastActive[entry.appId] = front.surfaceId
        if let index = entries.firstIndex(where: { $0.appId == entry.appId }) {
            entries[index].lastActiveSurface = front.surfaceId
        }
        let going = entry.windows.filter { !$0.minimized }
        minimizingAll[entry.appId] = Set(going.map(\.surfaceId))
        for window in going {
            LavaClient.minimizeWindow(window.surfaceId)
        }
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

    /// Incoming windows in the order we already had them, new ones at the
    /// end. The compositor's list is z-order and changes on every focus.
    static func stableWindowOrder(
        _ incoming: [WindowInfo], previous: [WindowInfo]
    ) -> [WindowInfo] {
        let byId = Dictionary(
            incoming.map { ($0.surfaceId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<UInt32>()
        var out: [WindowInfo] = []
        for old in previous {
            if let window = byId[old.surfaceId],
               seen.insert(window.surfaceId).inserted
            {
                out.append(window)
            }
        }
        for window in incoming where seen.insert(window.surfaceId).inserted {
            out.append(window)
        }
        return out
    }

    func pin(_ id: String, at index: Int? = nil) {
        guard DockPins.canPin(id) else { return }
        pins.pin(id, on: lastWorkspace, at: index)
        pins.save()
        rebuildEntries()
        ViewInvalidation.markNeedsRedraw()
    }

    func unpin(_ id: String) {
        pins.unpin(id, on: lastWorkspace)
        pins.save()
        rebuildEntries()
        ViewInvalidation.markNeedsRedraw()
    }

    /// After a drop: `order` is the new left-to-right app ids, `pinnedIds`
    /// is who stays on the dock when they have no window.
    func commitOrder(_ order: [String], pinnedIds: [String]) {
        pins.setIds(pinnedIds, on: lastWorkspace)
        pins.save()
        // Seed `entries` with the drop order so rebuildEntries keeps
        // unpinned icons where the user put them, not where the
        // compositor lists them.
        let pinIds = pins.ids(on: lastWorkspace)
        let pinSet = Set(pinIds)
        let extras = order.filter { !pinSet.contains($0) }
        let byId = Dictionary(uniqueKeysWithValues: entries.map { ($0.appId, $0) })
        entries = pinIds.compactMap { byId[$0] } + extras.compactMap { byId[$0] }
        rebuildEntries()
        ViewInvalidation.markNeedsRedraw()
    }

    /// Next or previous window of this application. `step` is in notches
    /// after the sign flip: positive is the next in our stable order.
    func cycleWindows(of appId: String, step: Int) {
        guard step != 0,
              let entry = entries.first(where: { $0.appId == appId }),
              entry.windows.count > 1
        else { return }
        let current = entry.windows.firstIndex(where: { $0.focused }) ?? 0
        let count = entry.windows.count
        let next = ((current + step) % count + count) % count
        activateWindow(entry.windows[next].surfaceId, of: appId)
    }

    /// Small face for the instance count. Registered the first time we
    /// paint a badge, when the editor is already there.
    func badgeFont() -> UIFont? {
        if let badgeFontCache { return badgeFontCache }
        guard let base = FontStore.default else { return nil }
        guard let font = UIFont(
            path: base.path, pixelSize: 10, faceIndex: base.faceIndex
        ) else {
            return base
        }
        if let editor { _ = font.registerWithEngine(editor) }
        badgeFontCache = font
        return font
    }

    // ─── Window preview ──────────────────────────────────────────────────

    /// Puts the shelf up for `appId`, growing the panel to make room.
    ///
    /// Called after a frame is on screen, never from inside paint: it makes
    /// two blocking control-plane calls and changes the size the next layout
    /// runs at, and paint is in the middle of emitting a draw list against
    /// the old one.
    func openPreview(_ appId: String) {
        previewRequest = appId
        guard let entry = entries.first(where: { $0.appId == appId }),
              entry.windows.count > 1
        else { return closePreview() }
        guard preview?.appId != appId else { return }

        menu = nil
        hoverCandidate = nil
        setPanelHeight(Dock.openHeight)
        bindPosters(of: entry)
        preview = DockPreview(appId: appId)
        ViewInvalidation.markNeedsRedraw()
    }

    /// Names this application's windows as `ImageSurface` posters, and tells
    /// the compositor to take each one's picture again first.
    ///
    /// A poster is a name, not pixels — `UIImage.surfacePoster` costs
    /// nothing and the compositor imports the window's last dma-buf when it
    /// replays the draw list. `ForgetWindowPoster` is what makes the picture
    /// current: the compositor caches one per (window, size) so a shelf is
    /// one import rather than one per frame, and a dock that lives all
    /// session would otherwise show, every time, whatever the window looked
    /// like the first time it was hovered.
    ///
    /// Once per open, not per frame. Per frame would be a capture of the
    /// whole shelf at 60 Hz.
    private func bindPosters(of entry: DockEntry) {
        var posters: [UInt32: UIImage] = [:]
        for window in entry.windows where window.width > 0 && window.height > 0 {
            LavaClient.forgetWindowPoster(window.surfaceId)
            posters[window.surfaceId] = UIImage.surfacePoster(
                surfaceId: window.surfaceId,
                pixelWidth: Float(window.width),
                pixelHeight: Float(window.height),
                maxSide: Dock.previewPosterSide
            )
        }
        previewPosters = posters
    }

    /// The window set changed under an open shelf.
    ///
    /// A window that opened has no poster yet and would draw as its
    /// application's icon forever; one that closed leaves a name the
    /// compositor can no longer resolve. Only when the *set* moved — a
    /// window merely taking focus must not recapture the shelf.
    private func syncPreview() {
        guard let open = preview else { return }
        guard let entry = entries.first(where: { $0.appId == open.appId }),
              entry.windows.count > 1
        else { return closePreview() }
        let shown = Set(previewPosters.keys)
        let live = Set(
            entry.windows.filter { $0.width > 0 && $0.height > 0 }
                .map(\.surfaceId)
        )
        if shown != live { bindPosters(of: entry) }
    }

    func closePreview() {
        previewRequest = nil
        hoverCandidate = nil
        guard preview != nil else { return }
        preview = nil
        previewPosters = [:]
        previewLayout = nil
        setPanelHeight(Dock.height)
        ViewInvalidation.markNeedsRedraw()
    }

    /// Grows or shrinks the surface the dock draws into.
    ///
    /// Grown and left grown — the way the taskbar does it for its menus —
    /// would be wrong here. The taskbar reserves its strip, so the compositor
    /// knows which part of its tall surface is the panel; a dock reserves
    /// nothing, and `panelCovered` reads the whole surface of a panel that
    /// reserves nothing as its strip. A dock left 250pt tall would decide it
    /// was covered by any window in the bottom quarter of the screen and
    /// auto-hide from it.
    ///
    /// The plate does not move: a bottom panel's origin is `output -
    /// thickness`, and everything paint draws is measured from the bottom of
    /// the surface, so the height all appears above the dock.
    private func setPanelHeight(_ height: Float) {
        guard panelHeight != height else { return }
        let grew = height - panelHeight
        panelHeight = height
        LavaClient.setPanelThickness(height)
        // A bottom panel grows upward, so the surface's top edge moved and
        // every y the client holds is now short by exactly that much. The
        // pointer has not moved and will send nothing until it does, so
        // nothing else will correct the last position we were told — and the
        // very next frame asks whether the pointer is still on the icon that
        // opened this. Without this it is not: it is 116 points above it, on
        // a shelf that has not been drawn yet, and the shelf closes on the
        // frame it opened.
        let pointer = PointerState.window
        PointerState.set(x: pointer.x, y: pointer.y + grew)
        // Locally too, so the first frame at the new height is drawn at it
        // rather than waiting for the `Resize` the compositor has queued.
        if let editor {
            let width = editor.framebufferSize().w
            editor.setClientSize(
                width: width > 1 ? width : max(lastFrameWidth, 1920),
                height: height
            )
        }
    }

    func launch(_ id: String) {
        if let entry = entryInfo(for: id) {
            if !entry.launch() {
                FileHandle.standardError.write(
                    Data("dock: launch failed for \(id)\n".utf8)
                )
            }
            return
        }
        launchSibling(id)
    }
}

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
    /// Extra space between the last pin and the first running-only icon.
    static let groupGap: Float = 18
    static let padding: Float = 10
    /// The plate itself: an icon at rest, with its padding, floating a little
    /// off the screen's edge rather than sitting flush against it.
    ///
    /// Named because the window preview hangs off the top of it, and the
    /// shelf and the paint that draws the plate must not each have their own
    /// idea of where that is — see `Dock.previewLayout`.
    static var plateHeight: Float { iconSize + padding * 2 }
    static let plateInset: Float = 6
    /// Room above a magnified icon for the name tooltip.
    static let tooltipRoom: Float = 28
    /// Height of the surface. Tall enough for a magnified icon, its
    /// name, the indicator, and a little air above the edge.
    static let height: Float = magnifiedSize + padding * 2 + 14 + tooltipRoom
    /// How deep the strip is that reveals the dock when the pointer enters it.
    /// One pixel is enough to be *entered*, and too little to be aimed at.
    static let triggerHeight: Float = 3
    /// How far past the end of the plate the pointer must reach before a
    /// hidden dock comes out.
    ///
    /// The dead zone, and the reason the dock stops flickering along the
    /// bottom corners of the screen. Hidden, the strip that hears the pointer
    /// runs the full width; revealed, the region shrinks to the plate. So a
    /// pointer that triggered a reveal from beyond the plate's ends was
    /// outside the new region the same instant, was told it had left, and
    /// hid the dock — which widened the strip, which revealed it again, once
    /// per motion event for as long as the pointer rested down there.
    ///
    /// Coming out on a stricter bound than the one that puts it away is what
    /// breaks that loop: crossing in costs a real movement, and crossing back
    /// out costs another.
    static let revealInset: Float = 16

    /// Whether a pointer at `x` is far enough into the plate to bring the dock
    /// out. `plate` is the span it will take input in once it is out.
    ///
    /// `inset` is 0 for a press, which is its own evidence of intent and
    /// cannot start the loop above: the compositor keeps the pointer on the
    /// surface that took the press, so the region cannot move out from under
    /// it mid-gesture.
    static func approaching(
        x: Float, plate: (x: Float, w: Float), inset: Float = revealInset
    ) -> Bool {
        // A plate narrower than two insets would have no live zone at all.
        let inset = min(inset, max(0, plate.w * 0.5 - 1))
        return x >= plate.x + inset && x <= plate.x + plate.w - inset
    }
    /// Lift the icon this far (in surface Y, up is smaller) and a drop unpins.
    static let unpinLift: Float = 28
    /// How long neighbours take to make room. Short enough to track the
    /// pointer, long enough to read as a slide rather than a jump.
    static let slideDuration: Double = 0.2

    /// Where the row would sit if `from` were dropped at `dest`.
    ///
    /// Two groups, not one list. `dest` left of the separator is the
    /// pin side (an unpinned app joining makes the divider shift
    /// right); `dest` on the right unpins (divider shifts left). A
    /// pin dragged into the running-only half lands there, it does
    /// not stick to the last pin slot.
    struct Preview {
        var items: [DockEntry]
        var hole: Int
        var split: Int
    }

    static func preview(
        entries: [DockEntry], from: Int, dest rawDest: Int
    ) -> Preview {
        let count = entries.count
        let pinCount = entries.prefix { $0.pinned }.count
        guard count > 0, from >= 0, from < count else {
            return Preview(items: entries, hole: 0, split: pinCount)
        }
        let item = entries[from]
        // `count` is a real dest: past the last icon, "append".
        let dest = min(max(0, rawDest), count)
        var pins = Array(entries.prefix(pinCount))
        var rest = Array(entries.dropFirst(pinCount))
        pins.removeAll { $0.appId == item.appId }
        rest.removeAll { $0.appId == item.appId }

        let inPins = item.pinned
            ? dest < pinCount
            : item.canPin && dest < pinCount
        if inPins {
            let insert = min(dest, pins.count)
            pins.insert(item, at: insert)
            return Preview(items: pins + rest, hole: insert, split: pins.count)
        }
        let destU = dest - pinCount
        let insert = min(max(0, destU), rest.count)
        rest.insert(item, at: insert)
        return Preview(items: pins + rest, hole: pins.count + insert, split: pins.count)
    }

    static func separatorX(plateX: Float, split: Int, count: Int) -> Float? {
        guard split > 0, split < count else { return nil }
        let left = restingCenter(
            index: split - 1, plateX: plateX, splitAfter: split, count: count
        ) + iconSize * 0.5
        let right = restingCenter(
            index: split, plateX: plateX, splitAfter: split, count: count
        ) - iconSize * 0.5
        return (left + right) * 0.5
    }

    /// The dock's own rounded plate, centred on the surface.
    ///
    /// `splitAfter` is how many icons sit in the pinned group. A gap is
    /// inserted after that many so pins and running-only apps read as two
    /// rows sharing a plate, not one bag.
    static func plate(
        entries: Int, splitAfter: Int, surfaceWidth: Float
    ) -> (x: Float, w: Float) {
        let count = max(entries, 1)
        var width = Float(count) * iconSize
            + Float(max(count - 1, 0)) * spacing
            + padding * 2
        if splitAfter > 0 && splitAfter < count { width += groupGap }
        return ((surfaceWidth - width) * 0.5, width)
    }

    /// Where an icon rests, before magnification.
    static func restingCenter(
        index: Int, plateX: Float, splitAfter: Int, count: Int
    ) -> Float {
        var x = plateX + padding + iconSize * 0.5
            + Float(index) * (iconSize + spacing)
        if splitAfter > 0 && splitAfter < count && index >= splitAfter {
            x += groupGap
        }
        return x
    }

    /// Slot the pointer is over, 0 ... count. `count` means past the
    /// last icon — append, and the way a pin lands after the last
    /// unpinned app (or after the last pin when the right half is empty).
    static func slot(
        atX x: Float, plateX: Float, splitAfter: Int, count: Int
    ) -> Int {
        guard count > 0 else { return 0 }
        var best = 0
        var bestDist = Float.greatestFiniteMagnitude
        for i in 0..<count {
            let c = restingCenter(
                index: i, plateX: plateX, splitAfter: splitAfter, count: count
            )
            let d = abs(c - x)
            if d < bestDist {
                bestDist = d
                best = i
            }
        }
        let last = restingCenter(
            index: count - 1, plateX: plateX, splitAfter: splitAfter, count: count
        )
        if x >= last + iconSize * 0.5 { return count }
        return best
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

nonisolated(unsafe) let model = DockModel()

struct DockView: View {
    var body: some View {
        // Read here, not only in `paint`: a paint closure runs at emit and is
        // invisible to observation, so a body that never mentions the model is
        // a view that never rebuilds when it changes.
        _ = model.revealed
        _ = model.menu
        _ = model.entries.count
        _ = model.drag?.active
        _ = model.sliding
        _ = model.preview?.appId
        return Canvas(
            label: "Dock",
            flexGrow: 1,
            // Magnification reads the pointer at paint time. A move already
            // wakes a client frame (`LavaClient` marks redraw on every input
            // that is not a renderer-owned hover/scroll), so asking the
            // animation driver for 60 fps while the dock is merely *out*
            // would paint the same plate every vsync for nothing. A drag
            // that opened a hole is the exception: neighbours have to
            // keep sliding after the pointer stops.
            continuousRedraw: model.drag?.active == true || model.sliding,
            onGesture: { gesture in handle(gesture) },
            onWheel: { dx, dy, localX, _ in
                handleWheel(dx: dx, dy: dy, atX: localX)
            },
            onHover: { inside in
                // Arriving is necessary but no longer sufficient: the strip
                // runs the whole width of the screen and the dock only
                // occupies the middle of it. Whether this counts as an
                // approach is decided in `paint`, which is the one place that
                // knows both where the pointer is and where the plate ends.
                model.pointerInside = inside
            },
            paint: { list, frame in paint(list, frame) }
        )
        .agentId("dock")
        .overlay(
            isPresented: menuBinding,
            placement: menuPlacement,
            style: {
                var s = MenuBarStyle.panel().overlayStyle
                s.padding = 4
                s.minWidth = 120
                return s
            }()
        ) {
            contextMenu
        }
    }

    private var menuBinding: Binding<Bool> {
        Binding(
            get: { model.menu != nil },
            set: { open in
                if !open { model.menu = nil }
            }
        )
    }

    private var menuPlacement: OverlayPlacement {
        OverlayPlacement { context in
            let w = max(context.idealSize.width, 120)
            let h = context.idealSize.height
            let anchor = model.menu?.x ?? context.anchor.x
            let x = min(
                max(8, anchor - 8),
                max(8, context.viewport.width - w - 8)
            )
            let y = max(4, context.viewport.height - h - Dock.iconSize - 22)
            return OverlayFrame(x: x, y: y, width: w, height: h)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        let appId = model.menu?.appId ?? ""
        MenuDropdownPanel(
            entries: menuEntries(for: appId),
            onActivate: { id in
                switch id.raw {
                case "dock.open":
                    model.launch(appId)
                case "dock.pin":
                    model.pin(appId)
                case "dock.unpin":
                    model.unpin(appId)
                default:
                    break
                }
                model.menu = nil
            },
            style: .panel()
        )
    }

    private func menuEntries(for appId: String) -> [MenuEntry] {
        let entry = model.entries.first { $0.appId == appId }
        let pinned = entry?.pinned ?? false
        let running = entry?.isRunning ?? false
        var items: [MenuEntry] = []
        if !running {
            items.append(.item(MenuItemModel(
                id: MenuID("dock.open"), title: "Open"
            )))
        }
        if DockPins.canPin(appId) {
            if !items.isEmpty { items.append(.separator) }
            items.append(.item(MenuItemModel(
                id: MenuID(pinned ? "dock.unpin" : "dock.pin"),
                title: pinned ? "Unpin" : "Pin"
            )))
        }
        return items
    }

    /// Brings the dock out. What it accepts input in follows on the next
    /// paint, from the geometry that paint uses — see `syncInputRegion`.
    private func reveal() {
        guard !model.revealed else { return }
        model.revealed = true
        ViewInvalidation.markNeedsRedraw()
    }

    /// Scroll down (negative dy) is the next window; up is the previous.
    /// Same sign VolumeApplet uses: positive dy is scroll up.
    private func handleWheel(dx: Float, dy: Float, atX x: Float) {
        guard model.revealed, model.drag == nil, model.menu == nil else { return }
        let along = abs(dy) >= abs(dx) ? dy : dx
        let step = Int(along.rounded())
        guard step != 0 else { return }
        let width = model.lastFrameWidth
        guard width > 0,
              let index = entryIndex(atX: x, frameWidth: width)
        else { return }
        model.cycleWindows(of: model.entries[index].appId, step: -step)
    }

    private func handle(_ gesture: CanvasGesture) {
        switch gesture.phase {
        case .began:
            // The shelf is above the plate and owns every press that lands on
            // it — including the ones that miss a card, which are how it is
            // dismissed. Below the plate's top the dock's own handling
            // continues, so the icon under the shelf still clicks.
            if model.preview != nil, gesture.localY < model.plateTop {
                if gesture.button == PointerButton.left,
                   let appId = model.preview?.appId,
                   let card = model.previewLayout?.card(
                       atX: gesture.localX, y: gesture.localY
                   )
                {
                    model.activateWindow(card.surfaceId, of: appId)
                }
                model.closePreview()
                return
            }
            if Dock.approaching(
                x: gesture.localX,
                plate: rowLayout(
                    entries: model.entries, drag: model.drag,
                    surfaceWidth: gesture.frame.w
                ).plate,
                inset: 0
            ) {
                reveal()
            }
            if gesture.button == PointerButton.right {
                openMenu(atX: gesture.localX, frameWidth: gesture.frame.w)
            } else if gesture.button == PointerButton.left {
                beginPress(atX: gesture.localX, y: gesture.localY,
                           frameWidth: gesture.frame.w)
            }
        case .moved:
            updateDrag(atX: gesture.localX, y: gesture.localY,
                       frameWidth: gesture.frame.w)
        case .ended:
            endPress(atX: gesture.localX, y: gesture.localY,
                     frameWidth: gesture.frame.w)
        }
    }

    private func entryIndex(atX x: Float, frameWidth: Float) -> Int? {
        let entries = model.entries
        guard !entries.isEmpty else { return nil }
        let split = entries.prefix { $0.pinned }.count
        let plate = Dock.plate(
            entries: entries.count, splitAfter: split, surfaceWidth: frameWidth
        )
        for (index, _) in entries.enumerated() {
            let center = Dock.restingCenter(
                index: index, plateX: plate.x,
                splitAfter: split, count: entries.count
            )
            let size = Dock.size(center: center, pointerX: x)
            if abs(center - x) <= size * 0.5 { return index }
        }
        return nil
    }

    private func openMenu(atX x: Float, frameWidth: Float) {
        guard let index = entryIndex(atX: x, frameWidth: frameWidth) else {
            return
        }
        let entry = model.entries[index]
        // Nothing to offer: an anonymous window cannot be pinned, and it
        // is already running.
        guard entry.canPin || !entry.isRunning else { return }
        model.drag = nil
        model.closePreview()
        model.menu = DockContextMenu(appId: entry.appId, x: x)
        ViewInvalidation.markNeedsRedraw()
    }

    private func beginPress(atX x: Float, y: Float, frameWidth: Float) {
        model.menu = nil
        // A press is a decision; the shelf was an offer.
        model.closePreview()
        guard let index = entryIndex(atX: x, frameWidth: frameWidth) else {
            model.drag = nil
            return
        }
        let entry = model.entries[index]
        model.drag = DockDrag(
            appId: entry.appId, fromIndex: index, dest: index,
            startX: x, startY: y, pointerX: x, pointerY: y,
            active: false
        )
    }

    private func updateDrag(atX x: Float, y: Float, frameWidth: Float) {
        guard var drag = model.drag else { return }
        drag.pointerX = x
        drag.pointerY = y
        if let dest = dropSlot(atX: x, frameWidth: frameWidth) {
            if !drag.active {
                // Pixel slop is the wrong test: a magnified icon is wider than
                // its rest slot, so a click on the right half already sits
                // closer to the neighbour. Only a *different slot* (or a lift
                // toward unpin) is a drag.
                let lifted = drag.startY - y
                if dest != drag.fromIndex || lifted >= Dock.unpinLift * 0.5 {
                    drag.active = true
                    model.sliding = true
                }
            }
            if drag.active { drag.dest = dest }
        }
        model.drag = drag
        ViewInvalidation.markNeedsRedraw()
    }

    private func endPress(atX x: Float, y: Float, frameWidth: Float) {
        let drag = model.drag
        model.drag = nil
        guard let drag else { return }
        let dest = dropSlot(atX: x, frameWidth: frameWidth) ?? drag.dest
        let lifted = drag.startY - y
        let from = model.entries.firstIndex(where: { $0.appId == drag.appId })
            ?? drag.fromIndex
        let preview = Dock.preview(
            entries: model.entries, from: from, dest: dest
        )
        let split = model.entries.prefix { $0.pinned }.count
        let moved = preview.hole != from || preview.split != split
        if !drag.active {
            activate(atX: drag.startX, frameWidth: frameWidth)
        } else if lifted >= Dock.unpinLift || moved {
            commitDrag(drag, atX: x, y: y, frameWidth: frameWidth)
        }
        ViewInvalidation.markNeedsRedraw()
    }

    private func dropSlot(atX x: Float, frameWidth: Float) -> Int? {
        let entries = model.entries
        guard !entries.isEmpty else { return nil }
        let split = entries.prefix { $0.pinned }.count
        let plate = Dock.plate(
            entries: entries.count, splitAfter: split, surfaceWidth: frameWidth
        )
        return Dock.slot(
            atX: x, plateX: plate.x, splitAfter: split, count: entries.count
        )
    }

    private func commitDrag(
        _ drag: DockDrag, atX x: Float, y: Float, frameWidth: Float
    ) {
        let entries = model.entries
        guard let from = entries.firstIndex(where: { $0.appId == drag.appId })
        else { return }
        let dest = dropSlot(atX: x, frameWidth: frameWidth) ?? drag.dest
        let lifted = drag.startY - y
        let item = entries[from]

        if lifted >= Dock.unpinLift, item.pinned {
            model.unpin(item.appId)
            return
        }

        let preview = Dock.preview(entries: entries, from: from, dest: dest)
        let order = preview.items.map(\.appId)
        // The prefix *is* the pin group after this drop. Crossing the
        // separator either way is how pin/unpin happens on a drag.
        let pinnedIds = preview.items.prefix(preview.split).map(\.appId)
        model.commitOrder(order, pinnedIds: Array(pinnedIds))
    }

    private func paint(_ list: DrawList, _ frame: CanvasFrame) {
        let entries = model.entries
        let drag = model.drag
        let dragging = drag?.active == true
        model.lastFrameWidth = frame.w
        let layout = rowLayout(
            entries: entries, drag: drag, surfaceWidth: frame.w
        )
        let plate = layout.plate
        // Motion over the strip wakes a client frame, so this runs on every
        // move the dock hears while it is away — which is how a pointer that
        // arrived outside the plate still reveals it after sliding along the
        // edge into range.
        if !entries.isEmpty, model.pointerInside, !model.revealed,
           Dock.approaching(x: PointerState.window.x, plate: plate)
        {
            reveal()
        }
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
        let plateH = Dock.plateHeight
        let plateY = frame.y + frame.h - plateH - Dock.plateInset
        // Where the shelf hangs from, and the bottom of the band the pointer
        // crosses to reach it — see `previewHoldsPointer`.
        model.plateTop = plateY
        let radius = max(WindowBridge.desktopCornerRadius, 12)

        list.roundedRect(
            x: frame.x + plate.x, y: plateY, w: plate.w, h: plateH,
            color: Color(r: theme.panel.r, g: theme.panel.g, b: theme.panel.b,
                         a: 0.88),
            radius: radius
        )

        // The pointer's own position, read at paint time. A `Canvas` hears
        // about motion only inside a press, and a dock magnifies under a
        // pointer that is merely passing. A drag owns the lens.
        let pointer: Float? = dragging ? nil : PointerState.window.x
        let now = FrameScheduler.now()
        var live: [String: Animated<Float>] = [:]
        var anySliding = false

        var hovered: (entry: DockEntry, center: Float, size: Float, top: Float)?
        for entry in entries {
            guard let target = layout.centers[entry.appId] else { continue }
            var anim = model.iconSlide[entry.appId] ?? Animated(target)
            if abs(anim.target - target) > 0.25 {
                anim.animate(
                    to: target, duration: Dock.slideDuration, curve: .easeOut
                )
            }
            if anim.step(now) { anySliding = true }
            live[entry.appId] = anim
            let center = frame.x + anim.current
            let size = Dock.size(center: center, pointerX: pointer)
            paintIcon(
                list, entry: entry, center: center, size: size,
                plateY: plateY, plateH: plateH, theme: theme
            )
            if let pointer, abs(center - pointer) <= size * 0.55 {
                let top = (plateY + plateH - Dock.padding) - size
                if hovered == nil
                    || abs(center - pointer) < abs(hovered!.center - pointer)
                {
                    hovered = (entry, center, size, top)
                }
            }
        }
        model.iconSlide = live

        if dragging, let drag, let entry = entries.first(where: { $0.appId == drag.appId }) {
            let lift = max(0, min(Dock.unpinLift + 8, drag.startY - drag.pointerY))
            let size = Dock.magnifiedSize
            let center = frame.x + drag.pointerX
            let bottom = plateY + plateH - Dock.padding - lift
            paintIcon(
                list, entry: entry, center: center, size: size,
                plateY: plateY, plateH: plateH, theme: theme,
                bottom: bottom
            )
        }

        if let target = layout.separatorX {
            var anim = model.separatorSlide ?? Animated(target)
            if abs(anim.target - target) > 0.25 {
                anim.animate(
                    to: target, duration: Dock.slideDuration, curve: .easeOut
                )
            }
            if anim.step(now) { anySliding = true }
            model.separatorSlide = anim
            let mid = frame.x + anim.current
            list.roundedRect(
                x: mid - 1, y: plateY + plateH * 0.28,
                w: 2, h: plateH * 0.44,
                color: theme.border.opacity(0.85),
                radius: 1
            )
        } else {
            model.separatorSlide = nil
        }

        if anySliding { FrameScheduler.requestWake(in: 1.0 / 60.0) }
        if model.sliding != anySliding { model.sliding = anySliding }

        // Where the shelf is comes first, because deciding whether it stays
        // up is a question about *its* rectangle. Derived here rather than
        // remembered from the last frame: the frame it opens on has no last
        // frame to remember, and that is the one where "is the pointer still
        // on the shelf" gets asked first.
        let shelf: Dock.PreviewLayout? = {
            guard let open = model.preview,
                  let entry = entries.first(where: { $0.appId == open.appId }),
                  let anchor = layout.centers[entry.appId]
            else { return nil }
            return Dock.previewLayout(
                windows: entry.windows, anchorX: frame.x + anchor, frame: frame
            )
        }()
        model.previewLayout = shelf

        // The pointer's x already picked `hovered`; the shelf also cares
        // about its y, because the pointer standing *on the shelf* shares a
        // column with whatever icon is under it and that must not read as
        // hovering a different application. The band is the icons' own reach
        // — a magnified icon rises this far and no further, which is what
        // `previewGap` was sized to clear.
        let pointerY = PointerState.window.y
        let onPlate = pointer != nil
            && pointerY >= plateY + plateH - Dock.padding - Dock.magnifiedSize
            && pointerY <= plateY + plateH
        updatePreviewHover(over: onPlate ? hovered?.entry : nil, dragging: dragging)

        if let shelf, let open = model.preview,
           let entry = entries.first(where: { $0.appId == open.appId })
        {
            paintPreview(
                list, entry: entry, layout: shelf, theme: theme,
                pointer: PointerState.window
            )
        } else if !dragging, model.menu == nil, let hovered {
            // The names on the shelf are the titles a tooltip would have
            // said, so the two never show at once.
            paintTooltip(
                list, title: hovered.entry.title,
                center: hovered.center, iconTop: hovered.top,
                frame: frame, theme: theme
            )
        }
    }

    /// Decides whether a shelf should be up, and for whom.
    ///
    /// Runs at paint because that is where the pointer's position and the
    /// row's geometry are both known — but it never opens or closes anything
    /// itself. Both of those grow or shrink the panel and make blocking
    /// control-plane calls, so they are queued for after this frame is on
    /// screen; `previewRequest` is what keeps paint from asking again on
    /// every frame in between.
    private func updatePreviewHover(over entry: DockEntry?, dragging: Bool) {
        guard model.revealed, !dragging, model.drag == nil, model.menu == nil
        else { return requestPreview(nil) }

        if let open = model.preview {
            if let entry, entry.appId != open.appId {
                // Sliding along the dock to the next stacked icon switches at
                // once: the pointer already waited out the delay to get the
                // first shelf, and paying it again per icon reads as lag.
                requestPreview(entry.windows.count > 1 ? entry.appId : nil)
            } else if entry == nil, !previewHoldsPointer() {
                requestPreview(nil)
            }
            return
        }

        guard let entry, entry.windows.count > 1 else {
            model.hoverCandidate = nil
            return
        }
        let now = FrameScheduler.now()
        if model.hoverCandidate?.appId != entry.appId {
            model.hoverCandidate = (entry.appId, now)
        }
        let waited = now - (model.hoverCandidate?.since ?? now)
        if waited >= Dock.previewDelay {
            requestPreview(entry.appId)
        } else {
            // Nothing else would wake the client: the pointer has stopped,
            // and a dock at rest draws no frames.
            FrameScheduler.requestWake(in: Dock.previewDelay - waited)
        }
    }

    /// Queues "show this application's windows", or nil for "take it down".
    private func requestPreview(_ appId: String?) {
        guard model.previewRequest != appId else { return }
        model.previewRequest = appId
        FrameTasks.after {
            if let appId { model.openPreview(appId) } else { model.closePreview() }
        }
    }

    /// Whether the pointer is still on the shelf, or on the gap between it
    /// and the plate.
    ///
    /// The gap is part of it on purpose. It is a real 24pt of empty surface
    /// the pointer has to cross to reach a thumbnail, and a shelf that let go
    /// halfway across would be a shelf that cannot be clicked.
    private func previewHoldsPointer() -> Bool {
        guard let strip = model.previewLayout?.strip else { return false }
        let pointer = PointerState.window
        return pointer.x >= strip.x - 8 && pointer.x <= strip.x + strip.w + 8
            && pointer.y >= strip.y - 8 && pointer.y <= model.plateTop
    }

    /// Resting centres for every icon that stays on the plate.
    ///
    /// A live drag keeps the plate at full width and leaves a hole at
    /// the preview dest so neighbours have somewhere to slide into.
    /// The pin/unpinned split is the preview's, so the separator
    /// travels with the hole instead of sitting on the old boundary.
    /// Lifting a pin far enough closes the hole: the row is about
    /// to lose that icon.
    private func rowLayout(
        entries: [DockEntry], drag: DockDrag?, surfaceWidth: Float
    ) -> (
        plate: (x: Float, w: Float), split: Int, count: Int,
        centers: [String: Float], separatorX: Float?
    ) {
        let dragging = drag?.active == true
        let unpinning: Bool = {
            guard dragging, let drag,
                  let item = entries.first(where: { $0.appId == drag.appId })
            else { return false }
            return item.pinned && (drag.startY - drag.pointerY) >= Dock.unpinLift
        }()

        let items: [DockEntry]
        let split: Int
        let hole: Int?

        if dragging, let drag, unpinning {
            items = entries.filter { $0.appId != drag.appId }
            split = items.prefix { $0.pinned }.count
            hole = nil
        } else if dragging, let drag,
                  let from = entries.firstIndex(where: { $0.appId == drag.appId })
        {
            let preview = Dock.preview(
                entries: entries, from: from, dest: drag.dest
            )
            items = preview.items
            split = preview.split
            hole = preview.hole
        } else {
            items = entries
            split = entries.prefix { $0.pinned }.count
            hole = nil
        }

        let plate = Dock.plate(
            entries: max(items.count, 1),
            splitAfter: split,
            surfaceWidth: surfaceWidth
        )
        var centers: [String: Float] = [:]
        for (index, entry) in items.enumerated() {
            if hole == index { continue }
            centers[entry.appId] = Dock.restingCenter(
                index: index, plateX: plate.x,
                splitAfter: split, count: items.count
            )
        }
        return (
            plate, split, items.count, centers,
            Dock.separatorX(plateX: plate.x, split: split, count: items.count)
        )
    }

    private func paintIcon(
        _ list: DrawList, entry: DockEntry, center: Float, size: Float,
        plateY: Float, plateH: Float, theme: Theme,
        bottom: Float? = nil
    ) {
        let iconBottom = bottom ?? (plateY + plateH - Dock.padding)
        let rect = (x: center - size * 0.5, y: iconBottom - size, w: size, h: size)

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

        if !entry.isRunning, entry.pinned {
            // No running indicator. The missing dot *is* the fact.
        } else if entry.isRunning {
            // Just under the icon, still inside the plate. It used to sit
            // three pixels *below* the bar, which read as a second row.
            let dotY = iconBottom + 5
            list.circle(cx: center, cy: dotY, radius: entry.isFocused ? 3 : 2,
                        color: entry.isFocused ? theme.accent : theme.textDim)
        }

        if entry.windows.count > 1 {
            paintCountBadge(
                list, count: entry.windows.count,
                icon: rect, theme: theme
            )
        }
    }

    /// Instance count, hung on the icon's top-right. One window is the
    /// ordinary case and needs no number.
    private func paintCountBadge(
        _ list: DrawList, count: Int, icon: (x: Float, y: Float, w: Float, h: Float),
        theme: Theme
    ) {
        guard let font = model.badgeFont() else { return }
        let label = count > 99 ? "99+" : "\(count)"
        let textW = font.measure(label).width
        let pad: Float = 4
        let h = max(14, font.lineHeight + 2)
        let w = max(h, textW + pad * 2)
        let x = icon.x + icon.w - w + 3
        let y = icon.y - 2
        list.roundedRect(
            x: x, y: y, w: w, h: h,
            color: theme.accent,
            radius: h * 0.5
        )
        // `text` insets the pen 4px; pull back so the digit sits in the pill.
        list.text(
            label, x: x + pad - 4, y: y + (h - font.lineHeight) * 0.5,
            w: textW + 8, h: font.lineHeight,
            color: theme.background, font: font
        )
    }

    /// Name of the icon under the pointer, parked above the magnified tile.
    private func paintTooltip(
        _ list: DrawList, title: String, center: Float, iconTop: Float,
        frame: CanvasFrame, theme: Theme
    ) {
        let name = title.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let font = FontStore.default else { return }
        let textW = font.measure(name).width
        let padX: Float = 10
        let padY: Float = 4
        let pillW = textW + padX * 2
        let pillH = font.lineHeight + padY * 2
        var x = center - pillW * 0.5
        x = min(max(frame.x + 6, x), frame.x + frame.w - pillW - 6)
        let y = max(frame.y + 4, iconTop - pillH - 6)
        list.roundedRect(
            x: x, y: y, w: pillW, h: pillH,
            color: Color(r: theme.panel.r, g: theme.panel.g, b: theme.panel.b,
                         a: 0.96),
            radius: pillH * 0.5
        )
        list.text(
            name, x: x + padX - 4, y: y + padY,
            w: textW + 8, h: font.lineHeight,
            color: theme.textPrimary, font: font
        )
    }

    /// Keeps the compositor's idea of where this dock is clickable in step
    /// with where it draws.
    ///
    /// Hidden, that is a sliver along the screen's edge — the strip the pointer
    /// has to reach to bring the dock out, and nothing else, so a click aimed
    /// at a window near the bottom of the screen is not eaten by an invisible
    /// panel. Revealed, it is the plate. A drag or a menu takes the whole
    /// strip so the pointer is not clipped to the icons it started on.
    private func syncInputRegion(plate: (x: Float, w: Float), frame: CanvasFrame,
                                 hasEntries: Bool) {
        // A shelf claims the whole surface for the same reason a menu does:
        // the click that dismisses it is the one that lands outside it, so
        // the panel has to be what receives that click.
        let grabbing = model.drag?.active == true || model.menu != nil
            || model.preview != nil
        let region: (x: Float, y: Float, w: Float, h: Float)
        if grabbing {
            region = (0, 0, frame.w, frame.h)
        } else if model.revealed && hasEntries {
            region = (plate.x, 0, plate.w, frame.h)
        } else {
            region = (0, frame.h - Dock.triggerHeight, frame.w, Dock.triggerHeight)
        }
        guard region != appliedRegion else { return }
        appliedRegion = region
        LavaClient.setInputRegion(x: region.x, y: region.y,
                                  width: region.w, height: region.h)
    }

    /// Which entry is under `x`, and what clicking it means.
    private func activate(atX x: Float, frameWidth: Float) {
        guard model.revealed else { return }
        guard let index = entryIndex(atX: x, frameWidth: frameWidth) else {
            return
        }
        let entry = model.entries[index]
        if let window = entry.primary {
            // Clicking the application you are already in puts it away, which
            // is the gesture every dock has: the icon is a toggle, not a
            // one-way trip. The whole stack goes, not just the window on top —
            // and comes back one window at a time, the one that was in front.
            if window.focused && !window.minimized {
                model.minimizeStack(entry)
            } else {
                model.activateWindow(window.surfaceId, of: entry.appId)
            }
            return
        }
        model.launch(entry.appId)
    }
}

// ─── Desktop actions ─────────────────────────────────────────────────────────

/// Starts a sibling desktop program when there is no `.desktop` file —
/// LavaTerm, LavaSettings — the same lookup the panel uses.
func launchSibling(_ name: String) {
    let candidates: [String] = {
        var paths: [String] = []
        if let selfPath = CommandLine.arguments.first {
            let dir = URL(fileURLWithPath: selfPath).deletingLastPathComponent()
            paths.append(dir.appendingPathComponent(name).path)
            paths.append(dir.appendingPathComponent("../debug/\(name)").path)
            paths.append(dir.appendingPathComponent("../release/\(name)").path)
        }
        paths.append(name)
        return paths
    }()

    for path in candidates {
        let process = Process()
        if path.contains("/") {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                continue
            }
            process.executableURL = url
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [path]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return
        } catch {
            continue
        }
    }
    FileHandle.standardError.write(
        Data("dock: could not launch \(name)\n".utf8)
    )
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
model.loadCatalog()
model.pins = DockPins.load()
model.rebuildEntries()

LavaClient.onWindowList { workspace, windows in
    model.apply(workspace: workspace, windows: windows)
    // Entries changing can change the answer without any window moving: the
    // last window on this workspace closing leaves the desktop clear, and the
    // dock having no entries at all is not a dock worth showing.
    model.revealed = model.showsBecauseClear || model.revealed
    ViewInvalidation.markNeedsRedraw()
}

// Out when nothing is in the way, hidden when something is. The compositor is
// the only one that can see the difference — see `SubscribePanelArea`.
LavaClient.onPanelArea { covered in
    guard model.covered != covered else { return }
    model.covered = covered
    // Uncovered brings it out. Covered puts it away again *unless* the
    // pointer is on it, which is the ordinary reveal and belongs to the
    // pointer.
    if model.showsBecauseClear {
        model.revealed = true
    } else if !model.pointerInside, model.drag == nil, model.menu == nil,
              model.preview == nil
    {
        // A grown panel is a taller panel, and a dock reserves nothing — so
        // while a shelf is up the compositor reads any window in the bottom
        // quarter of the screen as covering the dock. It does not; the plate
        // is where it always was.
        model.revealed = false
    }
    ViewInvalidation.markNeedsRedraw()
}

// The pointer leaving is the only way a dock learns to put itself away: it
// hears about the pointer while it is inside and nothing at all afterwards.
PointerState.onLeave = {
    MainQueue.async {
        // A captured drag still owns the pointer even after the cursor
        // walks off the strip; do not hide under it.
        if model.drag != nil { return }
        model.pointerInside = false
        // The pointer is gone, and a shelf is only ever up because it is
        // here. This is also what shrinks the panel back.
        model.closePreview()
        guard model.revealed else { return }
        // Nothing to hide behind: the dock is out because the desktop under it
        // is clear, and the pointer wandering off is not a reason to put it
        // away.
        guard !model.showsBecauseClear else { return }
        if model.menu != nil { return }
        model.revealed = false
        ViewInvalidation.markNeedsRedraw()
    }
}

LavaClient.run(editor: editor) { DockView() }
