#if canImport(CxxCanvas)
import Foundation
import LavaUI

// Two windows, one process, one GPU.
//
// This is the smallest program that actually exercises the device/window
// split: one `RenderDevice`, two `RenderWindow`s, two swapchains, two draw
// arenas, one event loop. Both windows draw text, which is the interesting
// part — the glyph atlas is created once on the device and sampled by both, so
// the second window rasterizes nothing the first already did.
//
// The two roots share one model. Clicking in either window mutates it and both
// repaint, which is the property a multi-window app is for and the one you
// cannot get from running the binary twice.

/// State both windows read and either can write.
final class Shared: @unchecked Sendable {
    var count = 0
    var lastTouched = "nothing yet"
    /// Set from B's own view. Acted on by the loop, not here: destroying a
    /// window from inside its own click handler would free the tree the
    /// handler is still running in.
    var closeRequested = false
}

nonisolated(unsafe) let shared = Shared()

nonisolated(unsafe) let editorOpt = LavaApp.open(
    title: "Window A · counter", width: 520, height: 380
)
guard let editor = editorOpt else {
    FileHandle.standardError.write(Data("failed to open the first window\n".utf8))
    exit(1)
}

nonisolated(unsafe) let windowBOpt = editor.openWindow(
    width: 520, height: 380, title: "Window B · mirror"
)
guard let windowB = windowBOpt else {
    FileHandle.standardError.write(Data("failed to open the second window\n".utf8))
    exit(1)
}

/// Everything one window needs to produce a frame. Two of these exist; nothing
/// is shared between them but the `Editor` they draw through.
final class WindowState: @unchecked Sendable {
    let id: WindowID
    let host = LayoutHost()
    let drawList: DrawList
    var width: Float = 520
    var height: Float = 380
    /// Set whenever this window's content might have changed. Both windows are
    /// marked when the shared model is touched, which is why a click in one
    /// updates the other.
    var dirty = true

    init(editor: Editor, id: WindowID) {
        self.id = id
        self.drawList = DrawList(editor: editor, window: id)
    }
}

nonisolated(unsafe) let a = WindowState(editor: editor, id: .main)
nonisolated(unsafe) let b = WindowState(editor: editor, id: windowB)
/// Whether B is still open. `windowCount` would do, but a flag says what
/// this loop means rather than what the engine happens to hold.
nonisolated(unsafe) var bOpen = true

func markAllDirty() {
    a.dirty = true
    b.dirty = true
}

// ─── Roots ───────────────────────────────────────────────────────────────────

struct WindowARoot: View {
    let shared: Shared
    var body: some View {
        VStack(padding: 14) {
            Text("Window A", color: .accent)
            Text("count = \(shared.count)", color: .primary)
            Text("Add one", color: .accent, onClick: {
                shared.count += 1
                shared.lastTouched = "A"
                markAllDirty()
            })
            Spacer()
            Text("Both windows render from one process,", color: .secondary)
            Text("one device, one glyph atlas.", color: .secondary)
        }
        .padding(16)
    }
}

struct WindowBRoot: View {
    let shared: Shared
    var body: some View {
        VStack(padding: 14) {
            Text("Window B", color: .accent)
            Text("count = \(shared.count)", color: .primary)
            Text("last touched by: \(shared.lastTouched)", color: .secondary)
            Text("Reset", color: .accent, onClick: {
                shared.count = 0
                shared.lastTouched = "B"
                markAllDirty()
            })
            Text("Close this window", color: .accent, onClick: {
                shared.closeRequested = true
            })
            Spacer()
            Text("Same atlas as A — this text cost", color: .secondary)
            Text("no new rasterization.", color: .secondary)
        }
        .padding(16)
    }
}

// ─── Frame ───────────────────────────────────────────────────────────────────

func renderWindow(_ w: WindowState, _ makeRoot: () -> some View) {
    let fb = editor.framebufferSize(window: w.id)
    if fb.w >= 1, fb.h >= 1 {
        w.width = fb.w
        w.height = fb.h
    }

    w.host.setRoot(makeRoot())
    _ = w.host.calculateLayout(width: w.width, height: w.height)
    guard let root = w.host.rootNode else { return }

    w.drawList.clear()
    w.drawList.rect(x: 0, y: 0, w: w.width, h: w.height, color: Theme.current.background)
    w.drawList.emitTree(
        root, originX: 0, originY: 0, viewportW: w.width, viewportH: w.height
    )
    editor.submitDrawList(w.drawList)
    editor.renderFrame(window: w.id)
    w.dirty = false
}

func handleInput(_ w: WindowState) {
    while let ev = editor.pollInputEvent(window: w.id) {
        switch ev.kind {
        case .mouseDown:
            if let action = w.host.hitTestClick(x: ev.x, y: ev.y, originX: 0, originY: 0, mods: ev.mods) {
                action()
            }
        case .mouseMove:
            HoverState.set(w.host.hitTestHover(x: ev.x, y: ev.y, originY: 0))
            w.dirty = true
        case .resize, .refresh:
            w.dirty = true
        default:
            break
        }
    }
}

// First frame before either window is shown, so neither presents an undefined
// swapchain image on the way up.
renderWindow(a) { WindowARoot(shared: shared) }
renderWindow(b) { WindowBRoot(shared: shared) }
editor.setVisible(true, window: .main)
editor.setVisible(true, window: windowB)

// One loop drives both. `pumpEvents` is process-wide (GLFW), so a single wait
// serves every window; the per-window work is polling its queue and, if
// anything changed, drawing it.
while editor.windowCount > 0 {
    editor.pumpEvents(timeout: -1)

    handleInput(a)
    if bOpen { handleInput(b) }

    // B asked to go away — from its own button, or from its titlebar. Dropping
    // it leaves the device and window A untouched, which is the whole point:
    // this is closing a window, not quitting the app.
    if bOpen, shared.closeRequested || editor.windowShouldClose(b.id) {
        FileHandle.standardError.write(Data("closing window B\n".utf8))
        editor.closeWindow(b.id)
        bOpen = false
        shared.closeRequested = false
        shared.lastTouched = "B (now closed)"
        a.dirty = true
    }

    // Closing the last window ends the loop.
    if editor.windowShouldClose(a.id) { break }

    if a.dirty { renderWindow(a) { WindowARoot(shared: shared) } }
    if bOpen, b.dirty { renderWindow(b) { WindowBRoot(shared: shared) } }
}

FileHandle.standardError.write(Data("two-window loop exited\n".utf8))
#else
print("TwoWindows needs the CxxCanvas engine.")
#endif
