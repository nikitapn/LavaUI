#if canImport(CxxCanvas) && canImport(LavaIDL)
import CxxCanvas
import Foundation
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

/// Runs `ClientDemoView` against a compositor over the control plane.
func runLavaUIClient() {
    guard let editor = LavaApp.openClient(width: 720, height: 560) else { exit(1) }

    let compositor: Compositor
    let rpc: Rpc
    do {
        (compositor, rpc) = try connectToCompositor()
    } catch {
        FileHandle.standardError.write(
            Data("no compositor (\(error)) — is the host running?\n".utf8)
        )
        exit(1)
    }
    rpcRuntime = rpc

    // Before anything loads a face or an image: ids already stamped into a
    // `UIFont` are not revisited, and `LavaApp.openClient` has already
    // bootstrapped the default one against the local table.
    editor.resources = CompositorResources(compositor)
    guard FontStore.bootstrap(
        assetsRoot: LavaResources.root, pixelSize: 16, into: editor
    ) != nil else {
        FileHandle.standardError.write(Data("no UI face from the compositor\n".utf8))
        exit(1)
    }

    // The surface id is only known after `CreateSurface`, which cannot happen
    // until the arena exists, which is what the sink creates. So `onPublish`
    // reads it rather than capturing it — the first frame is published from
    // inside `LavaApp.run`, long after this is filled in.
    nonisolated(unsafe) var surfaceID: UInt32 = 0
    guard let sink = ArenaFrameSink(id: arenaID, onPublish: {
        guard surfaceID != 0 else { return }
        // Fire and forget, and correct rather than merely cheap: the arena's
        // published sequence already says what is current, so a dropped one
        // costs a frame of latency and never a frame of content.
        Task.detached { try? await compositor.present(surfaceId: surfaceID) }
    }) else {
        FileHandle.standardError.write(
            Data("failed to create arena '\(arenaID)' — is one already running?\n".utf8)
        )
        exit(1)
    }
    editor.publishFrames(to: sink)

    let input: InputChannel
    do {
        // Longer than the default: this opens a window and builds a swapchain
        // on the far side, which on a cold device is not a microsecond-scale
        // call like the rest of this interface.
        surfaceID = try blockingCall(timeout: 10) {
            try await compositor.createSurface(
                arenaId: arenaID, width: 720, height: 560, title: clientName
            )
        }
        input = InputChannel(stream: try compositor.subscribeInput(surfaceId: surfaceID))
    } catch {
        FileHandle.standardError.write(Data("surface setup failed: \(error)\n".utf8))
        exit(1)
    }

    // Events arrive on an NPRPC thread and are consumed on the frame loop's,
    // which is exactly what `MainQueue` is for — it hops the work over and
    // wakes the loop out of `pumpEvents` on the way. Draining inside that hop
    // is also the honest place to ack: the serial then means "the tree has
    // seen it", not "the socket has".
    input.onArrival = {
        MainQueue.async {
            for event in input.drain() {
                editor.postInputEvent(
                    InputEvent(
                        kind: InputEventKind(rawValue: event.kind) ?? .none,
                        x: event.x, y: event.y,
                        button: event.button, mods: event.mods
                    )
                )
            }
            // A posted event is not a repaint request on its own — the loop
            // consumes input and then asks invalidation what to do — but the
            // frame it produces has to be asked for, because nothing in the
            // queue does it.
            ViewInvalidation.markNeedsRedraw()
        }
    }

    // The stream is the surface's lease: when it ends — the user closed the
    // window, the compositor went away — the surface goes with it, and there
    // is nothing left to draw into.
    Thread.detachNewThread {
        while !input.isClosed { Thread.sleep(forTimeInterval: 0.25) }
        FileHandle.standardError.write(Data("surface closed — exiting\n".utf8))
        exit(0)
    }

    let banner = "client up — surface \(surfaceID), arena '\(arenaID)' "
        + "(\(sink.mappedBytes / 1024) KiB)\n"
    FileHandle.standardError.write(Data(banner.utf8))

    LavaApp.run(editor: editor) { ClientDemoView() }
}
#endif
