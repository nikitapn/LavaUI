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
// Screenshots come from `CaptureSurface` on each window in the list — Lava
// surfaces from their canvas framebuffer, foreign windows from the buffer
// they last committed. A window that cannot be read back shows its icon.

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
        if let image, image.pixelHeight > 1 {
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
    /// Cards stay hidden until every capture has been attempted. Showing an
    /// icon and then swapping in the PNG is the blink this exists to kill.
    var ready = false

    @ObservationIgnored var editor: Editor?
    @ObservationIgnored var captureGeneration = 0
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
            startCaptures(revealImmediately: ready)
        }
    }

    /// Window list + posters, on this thread, before the surface exists.
    ///
    /// The overlay must not map until this returns: CreateSurface puts a
    /// window on screen, and a first frame without cards is the blink.
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
        captureGeneration += 1
        FileHandle.standardError.write(Data(
            "switcher: workspace \(workspace), \(mine.count)/\(incoming.count) windows\n".utf8
        ))
        if mine.isEmpty {
            ready = true
            return
        }
        let pngs = Self.capturePNGs(mine, generation: captureGeneration)
        var next: [UInt32: UIImage] = [:]
        if let editor {
            for (id, bytes) in pngs {
                if let image = editor.resources.registerImage(
                    data: bytes, maxPixelSize: UInt32(Switcher.captureSide)
                ) {
                    next[id] = image
                }
            }
        }
        shots = next
        ready = true
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

    func startCaptures(revealImmediately: Bool) {
        captureGeneration += 1
        let generation = captureGeneration
        let targets = windows
        if targets.isEmpty {
            shots = [:]
            ready = true
            ViewInvalidation.markNeedsBody()
            return
        }
        if !revealImmediately {
            ready = false
            ViewInvalidation.markNeedsBody()
        }
        guard let editor else { return }

        Thread.detachNewThread {
            let pngs = SwitcherModel.capturePNGs(targets, generation: generation)
            MainQueue.async {
                guard generation == model.captureGeneration else { return }
                var next: [UInt32: UIImage] = [:]
                for (id, bytes) in pngs {
                    if let image = editor.resources.registerImage(
                        data: bytes, maxPixelSize: UInt32(Switcher.captureSide)
                    ) {
                        next[id] = image
                    }
                }
                model.shots = next
                model.ready = true
                ViewInvalidation.markNeedsBody()
            }
        }
    }

    /// Fan the RPCs out. The compositor still *encodes* one at a time —
    /// `CaptureSurface` hops onto the Wayland loop for the GPU read-back
    /// *and* the PNG — so wall time is the sum of encodes, not the max.
    static func capturePNGs(
        _ targets: [WindowInfo], generation: Int
    ) -> [UInt32: [UInt8]] {
        let bag = CaptureBag()
        let group = DispatchGroup()
        for window in targets {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                guard generation == model.captureGeneration else { return }
                guard let bytes = LavaClient.captureWindow(
                    window.surfaceId, maxSide: Switcher.captureSide
                ) else { return }
                bag.store(window.surfaceId, bytes)
            }
        }
        group.wait()
        return bag.snapshot()
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

/// PNG bytes gathered off the frame loop. A class so concurrent captures
/// share one bag without the compiler seeing a captured `var` dictionary.
private final class CaptureBag: @unchecked Sendable {
    private let lock = NSLock()
    private var pngs: [UInt32: [UInt8]] = [:]

    func store(_ id: UInt32, _ bytes: [UInt8]) {
        lock.lock()
        pngs[id] = bytes
        lock.unlock()
    }

    func snapshot() -> [UInt32: [UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return pngs
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

WindowBackdrop.current = .none
Theme.current = .nebula

guard let editor = LavaClient.open(
    title: "Switcher", frame: .client, fillScreen: true
) else { exit(1) }

model.editor = editor

// Surface is created in `run`. Finish the posters first so the first
// frame is the real shelf, and the compositor keeps the window invisible
// until that frame is presented.
if let snapshot = LavaClient.currentWindowList() {
    model.loadInitially(workspace: snapshot.0, incoming: snapshot.1)
}

LavaClient.onWindowList { workspace, windows in
    model.apply(workspace: workspace, windows: windows)
}

LavaClient.run(editor: editor, onRawKey: handleKey) { SwitcherView() }
