import Foundation
import LavaClient
import LavaUI
import Observation

// A LavaUI app whose pixels are drawn by the wlroots compositor.
//
//   terminal 1:  compositor/scripts/dev-run
//   terminal 2:  swift run LavaSurface
//
// The tree below is an ordinary LavaUI view tree, and this process owns no
// GPU, no Vulkan device, no window and no swapchain. It owns a view tree and a
// page of shared memory. Two channels make that work and they are deliberately
// different shapes:
//
//   * the **arena** carries frames. A draw list is written once, into the
//     memory the renderer reads it from, and nothing is copied at either end.
//   * the **control plane** carries everything else — asking for a surface,
//     naming a font, saying a frame is ready, and input coming back. Small,
//     request/response shaped, and at human rates rather than vertex rates.
//
// `LavaClient.run` is all of it: the connect, the three installs a client
// needs, and the input stream fed back into the frame loop. What is left here
// is a view tree that does not know any of it is happening.
//
// Input is the difference this file exists to show. The compositor owns the
// window, so it owns the pointer and the keyboard; before the control plane a
// client could be *shown* and not *used*, and everything below that reacts to
// a click or a keystroke would have been dead.

/// Counts frames the client itself asked for, so a still window is visibly
/// different from a live one even before anything is clicked.
@Observable
final class Ticker {
    var frames = 0
}

nonisolated(unsafe) let ticker = Ticker()

struct SurfaceDemoView: View {
    @State private var clicks = 0
    @State private var typed = ""
    @State private var rows = 6

    var body: some View {
        VStack(padding: 20, spacing: 14) {
            Text("LavaUI · compositor client", color: Theme.current.accent)
            Text(
                "pid \(getpid()) · this tree lives in another process than its pixels",
                color: Theme.current.textMuted
            )

            // Everything below is driven by input the compositor forwards.
            // None of it worked before there was a control plane.
            HStack(padding: 0, spacing: 10) {
                Button("Click me") { clicks += 1 }
                Button("More rows") { rows += 2 }
                Button("Fewer rows") { rows = max(1, rows - 2) }
            }

            Text("clicked \(clicks) times · \(ticker.frames) ticks",
                 color: Theme.current.textPrimary)

            VStack(padding: 12, spacing: 6) {
                Text("Type here — keys arrive over the control plane:",
                     color: Theme.current.textMuted)
                EditorView(text: $typed)
                    .frame(height: .point(72))
            }
            .background(Theme.current.panel)
            .cornerRadius(10)

            VStack(padding: 10, spacing: 4) {
                ForEach(0..<rows, id: \.self) { i in
                    Text("row \(i + 1)", color: Theme.current.textMuted)
                }
            }
            .background(Theme.current.inset)
            .cornerRadius(8)
        }
        // No background of its own: the window's backdrop is the one thing
        // deciding how opaque this surface is, and a second opaque fill here
        // would quietly override it.
    }
}

// ─── Bring-up ───────────────────────────────────────────────────────────────

// Translucent on purpose, and set before the first frame. The compositor
// composites this surface rather than pasting it, so an alpha below 1 is a
// window you can see the desktop through — the whole difference between the
// ARGB surface this exports and the XRGB one it used to.
WindowBackdrop.current = .color(Theme.current.background.opacity(0.75))

guard let editor = LavaClient.open(
    title: "LavaSurface", width: 720, height: 560
) else { exit(1) }

// Nothing but a heartbeat, so an idle window still shows it is connected.
Thread.detachNewThread {
    while true {
        Thread.sleep(forTimeInterval: 1.0)
        MainQueue.async { ticker.frames += 1 }
    }
}

LavaClient.run(editor: editor) { SurfaceDemoView() }
