import Foundation
import LavaClient
import LavaIDL
import LavaShell
import LavaUI
import Observation

// The 3D app switcher: current window screenshots on a focused shelf, cycled
// with Ctrl+Tab (or Mod+Tab) and committed by releasing the hold key.
//
//   compositor binding  →  swift run LavaSwitcher
//
// Spawned per invocation, like the launcher. The compositor eats the first
// Tab to start this process; the overlay then owns the keyboard and every
// subsequent Tab while Control / Alt / Super is held. Release commits.
// Escape cancels. Clicking a card commits that window.
//
// Posters are `ImageSurface` / Scene3D surface textures: the card names the
// compositor surface id and the compositor imports that window's last
// dma-buf onto the canvas device. No PNG, no CPU readback on the launch
// path. A window with no size yet (never configured) shows its icon.

enum Switcher {
    static let appId = "LavaSwitcher"
    /// Longest encoded edge. First read is after `open(fillScreen:)`, so
    /// this sees the largest output. 1024 at 1920 looked sharp; scale that.
    /// Floor 384 keeps a nested 720p session readable; cap 1536 so a 4K
    /// capture does not own Alt+Tab. Always past the 256-px atlas cell so
    /// posters stay standalone and keep a mip chain.
    static let captureSide: Int32 = {
        let size = LavaClient.requestedSize
        let longest = Int(max(size.width, size.height).rounded())
        let side = posterSide(longestOutputEdge: longest)
        FileHandle.standardError.write(Data(
            "switcher: captureSide \(side) (output \(longest))\n".utf8
        ))
        return side
    }()

    /// 1024 at 1920 was the size that looked sharp; scale that, don't
    /// pick a second constant.
    static func posterSide(longestOutputEdge: Int) -> Int32 {
        guard longestOutputEdge > 0 else { return 1024 }
        let scaled = (Int64(longestOutputEdge) * 1024) / 1920
        return Int32(min(1536, max(384, scaled)))
    }
    /// Longer world-space edge of a card. The other edge follows the
    /// screenshot's aspect ratio so a terminal is tall and a browser is wide.
    static let cardMaxEdge: Float = 2.35
    static let cardDepth: Float = 0.018

    static func cardSize(for image: UIImage?) -> (w: Float, h: Float) {
        let raw: Float
        if let image, image.pixelHeight > 1, image.pixelWidth > 1 {
            raw = image.pixelWidth / image.pixelHeight
        } else {
            raw = 16 / 10
        }
        let aspect = min(max(raw, 0.45), 2.8)
        if aspect >= 1 {
            return (cardMaxEdge, cardMaxEdge / aspect)
        }
        return (cardMaxEdge * aspect, cardMaxEdge)
    }
}

@Observable
final class SwitcherModel {
    var windows: [WindowInfo] = []
    var selected = 0
    var shots: [UInt32: UIImage] = [:]
    var icons: [String: UIImage?] = [:]
    var committed = false
    /// Cards stay hidden until posters are bound. Surface posters bind
    /// immediately (no RPC); an empty workspace is ready at once.
    var ready = false

    @ObservationIgnored var editor: Editor?
    @ObservationIgnored var awaitingInitialSelection = true
    @ObservationIgnored private var capturedIds: [UInt32] = []

    var selectedWindow: WindowInfo? {
        windows.indices.contains(selected) ? windows[selected] : nil
    }

    func apply(workspace: UInt32, windows incoming: [WindowInfo]) {
        let mine = Self.ordered(
            incoming.filter {
                $0.workspace == workspace && $0.appId != Switcher.appId
            }
        )
        let previousId = selectedWindow?.surfaceId
        windows = mine
        if let previousId, let idx = windows.firstIndex(where: {
            $0.surfaceId == previousId
        }) {
            selected = idx
        } else if !windows.isEmpty {
            selected = min(selected, windows.count - 1)
        } else {
            selected = 0
        }
        FileHandle.standardError.write(Data(
            "switcher: workspace \(workspace), \(mine.count)/\(incoming.count) windows\n".utf8
        ))
        if awaitingInitialSelection {
            awaitingInitialSelection = false
            adoptInitialSelection(backwards: CommandLine.arguments.contains("--back"))
        }
        // The list is view structure, not a paint-time read. Redraw alone
        // would keep the Scene3D that mounted with no windows.
        ViewInvalidation.markNeedsBody()
        let ids = mine.map(\.surfaceId)
        if ids != capturedIds {
            capturedIds = ids
            bindPosters(mine)
        }
    }

    /// Window list + posters, on this thread, before the surface exists.
    ///
    /// The overlay must not map until this returns: CreateSurface puts a
    /// window on screen, and a first frame without cards is the blink.
    /// Surface posters do not wait on the compositor — they are names,
    /// resolved when the first frame is drawn.
    func loadInitially(workspace: UInt32, incoming: [WindowInfo]) {
        let mine = Self.ordered(
            incoming.filter {
                $0.workspace == workspace && $0.appId != Switcher.appId
            }
        )
        windows = mine
        awaitingInitialSelection = false
        adoptInitialSelection(
            backwards: CommandLine.arguments.contains("--back")
        )
        capturedIds = mine.map(\.surfaceId)
        FileHandle.standardError.write(Data(
            "switcher: workspace \(workspace), \(mine.count)/\(incoming.count) windows\n".utf8
        ))
        bindPosters(mine)
    }

    /// Focused window is leftmost (index 0) and starts selected. Shift+Tab
    /// on the opening chord lands on the rightmost instead.
    func adoptInitialSelection(backwards: Bool) {
        guard !windows.isEmpty else { return }
        selected = backwards ? windows.count - 1 : 0
        ViewInvalidation.markNeedsRedraw()
    }

    /// Focused first so it sits on the left of the shelf; the rest keep the
    /// compositor's stacking order.
    static func ordered(_ windows: [WindowInfo]) -> [WindowInfo] {
        var focused: [WindowInfo] = []
        var rest: [WindowInfo] = []
        for window in windows {
            if window.focused { focused.append(window) } else { rest.append(window) }
        }
        return focused + rest
    }

    func cycle(backwards: Bool) {
        guard !windows.isEmpty else { return }
        if backwards {
            selected = selected == 0 ? windows.count - 1 : selected - 1
        } else {
            selected = (selected + 1) % windows.count
        }
        ViewInvalidation.markNeedsBody()
    }

    func select(surfaceId: UInt32) {
        guard let idx = windows.firstIndex(where: { $0.surfaceId == surfaceId })
        else { return }
        selected = idx
        ViewInvalidation.markNeedsBody()
    }

    func preview(for window: WindowInfo) -> UIImage? {
        shots[window.surfaceId] ?? icon(for: window)
    }

    func icon(for window: WindowInfo) -> UIImage? {
        let key = window.appId.isEmpty ? "window:\(window.surfaceId)" : window.appId
        if let cached = icons[key] { return cached }
        var image: UIImage?
        if !window.appId.isEmpty,
           let path = IconLookup.iconPath(forAppId: window.appId),
           let editor
        {
            image = editor.resources.registerImage(path: path, maxPixelSize: 192)
        }
        icons[key] = image
        return image
    }

    func bindPosters(_ targets: [WindowInfo]) {
        var next: [UInt32: UIImage] = [:]
        for window in targets {
            if let poster = Self.surfacePoster(for: window) {
                next[window.surfaceId] = poster
            }
        }
        shots = next
        ready = true
        ViewInvalidation.markNeedsBody()
    }

    static func surfacePoster(for window: WindowInfo) -> UIImage? {
        guard window.width > 0, window.height > 0 else { return nil }
        return UIImage.surfacePoster(
            surfaceId: window.surfaceId,
            pixelWidth: Float(window.width),
            pixelHeight: Float(window.height),
            maxSide: UInt32(Switcher.captureSide)
        )
    }

    func commit() {
        guard !committed else { return }
        committed = true
        LavaClient.quit(activating: selectedWindow?.surfaceId)
    }

    func cancel() {
        guard !committed else { return }
        committed = true
        LavaClient.quit()
    }
}

nonisolated(unsafe) let model = SwitcherModel()

/// Wheel / trackpad: down or right advances, up or left goes back.
/// Dominant axis wins so a mostly-vertical notch is not also a tiny x step.
func handleSwitcherWheel(dx: Float, dy: Float) {
    let axis = abs(dx) >= abs(dy) ? dx : -dy
    guard abs(axis) > 0.05 else { return }
    model.cycle(backwards: axis < 0)
}

func handleKey(_ event: LavaUI.InputEvent) -> Bool {
    guard event.kind == .key else { return false }

    if event.keyAction == KeyAction.release,
       KeyCode.isHoldModifier(event.keyCode)
    {
        // Do not ask `keyMods`: on release they often still include the key
        // that just came up, which left the overlay open after Ctrl+Tab.
        model.commit()
        return true
    }

    guard KeyAction.isDown(event.keyAction) else { return false }

    switch event.keyCode {
    case KeyCode.escape:
        model.cancel()
        return true
    case KeyCode.enter:
        model.commit()
        return true
    case KeyCode.tab:
        model.cycle(backwards: KeyMods.contains(event.keyMods, KeyMods.shift))
        return true
    case KeyCode.right:
        model.cycle(backwards: false)
        return true
    case KeyCode.left:
        model.cycle(backwards: true)
        return true
    default:
        return false
    }
}

// ─── Bring-up ───────────────────────────────────────────────────────────────

WindowBackdrop.current = .blur(radius: 12)

guard let editor = LavaClient.open(
    title: "Switcher", frame: .client, fillScreen: true
) else { exit(1) }

model.editor = editor

// Surface is created in `run`. Bind posters (names, not pixels) first so
// the first frame is the real shelf, and the compositor keeps the window
// invisible until that frame is presented.
if let snapshot = LavaClient.currentWindowList() {
    model.loadInitially(workspace: snapshot.0, incoming: snapshot.1)
}

LavaClient.onWindowList { workspace, windows in
    model.apply(workspace: workspace, windows: windows)
}

LavaClient.run(editor: editor, onRawKey: handleKey) { SwitcherView() }
