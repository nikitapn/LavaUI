#if canImport(CxxCanvas) && canImport(LavaIDL)
import CxxCanvas
import Foundation
import LavaClient
import LavaIDL
import LavaUI
import NPRPC

// A real LavaUI app running as a client of the compositor.
//
// `runProducer` next door hand-writes draw commands to show what the arena
// carries; this shows that a *framework* fits through it. The view tree, the
// layout, the invalidation and the frame loop are the ones every windowed
// LavaUI app uses — `LavaApp.run` is called here unmodified — and the whole
// difference is three installs before it:
//
//   1. `openClient` instead of `open`      — no window, no GPU
//   2. `editor.resources = compositor`     — ids come from whoever draws
//   3. `editor.publishFrames(to: arena)`   — frames go to shared memory
//
// The payoff is worth stating plainly, because it is the reason for all of
// it: `kill -STOP` this process and the list still scrolls. The renderer owns
// the scroll offset against a scene node id, and moving a subtree it already
// has needs nothing from the process that published it.

/// What the client draws. Deliberately ordinary — the point is that nothing
/// here knows it is running in a different process from its pixels.
struct ClientDemoView: View {
    @State private var rows = 60

    var body: some View {
        VStack(padding: 12) {
            Text("LavaUI · compositor client", color: Theme.current.accent)
            Text(
                "pid \(getpid()) · this tree lives in another process than its pixels",
                color: Theme.current.textMuted
            )

            HStack(padding: 8) {
                // Its own view, so its own `@State`. Which subtree a change
                // recomputes is decided here, by where the state lives, and
                // not by the framework: `ViewInvalidation` tracks the
                // *composite node that read the value*, so a counter sharing a
                // view with a 560-row list recomputes the list too.
                ClickCounter()
                Button("More rows") { rows += 20 }
                Spacer()
            }

            // The one that matters. A wheel notch over this moves the subtree
            // in the renderer, against a node id, with no round trip — so it
            // keeps working while this process is stopped.
            ScrollView {
                VStack {
                    ForEach(Array(0..<rows), id: \.self) { i in
                        HStack(padding: 6) {
                            Text(
                                "row \(i)",
                                color: i % 2 == 0
                                    ? Theme.current.textPrimary
                                    : Theme.current.textSecondary
                            )
                            Spacer()
                            Text("· scrolls without me", color: Theme.current.textMuted)
                        }
                    }
                }
            }
            .flexGrow(1)
        }
    }
}

/// A counter that owns its own state, so pressing it recomputes only itself.
struct ClickCounter: View {
    @State private var clicks = 0

    var body: some View {
        Button("Clicked \(clicks)×") { clicks += 1 }
    }
}

/// Runs `ClientDemoView` as a client of the compositor.
///
/// Everything this used to spell out — connect, install the resource host,
/// create the arena and the surface, pump the input stream back in — is
/// `LavaClient.run` now, so that being a client is a library feature rather
/// than something this one demo knows how to do.
func runLavaUIClient() -> Never {
    guard let editor = LavaClient.open(
        title: clientName, width: 720, height: 560
    ) else { exit(1) }
    LavaClient.run(editor: editor) { ClientDemoView() }
}
#endif
