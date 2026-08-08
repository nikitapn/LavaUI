#if canImport(CxxCanvas) && canImport(LavaIDL)
import CxxCanvas
import Foundation
import LavaIDL
import LavaMenu
import LavaUI
import NPRPC

/// Runs a LavaUI app as a client of the compositor: no window, no GPU, frames
/// published into shared memory for another process to draw.
///
/// The whole of what a client is, in one call. `LavaApp.run` underneath is the
/// same loop every windowed app uses and is not modified; what this adds is the
/// three installs that have to happen before it, and the wiring in both
/// directions that has no home in `LavaUI` because `LavaUI` does not know what
/// a compositor is:
///
///   1. `openClient` instead of `open`   — no window, no GPU
///   2. `editor.resources = …`           — ids come from whoever draws
///   3. `editor.publishFrames(to: …)`    — frames go to a shared arena
///
/// plus `Present` after each publish, and the compositor's input stream fed
/// back in through `MainQueue`.
///
/// ```swift
/// guard let editor = LavaClient.open(title: "My App") else { exit(1) }
/// LavaClient.run(editor: editor) { RootView() }
/// ```
///
/// Does not return: like `LavaApp.run`, it owns the frame loop, and it exits
/// the process when the surface goes away — the input stream is the surface's
/// lease, so when the user closes the window or the compositor stops, there is
/// nothing left to draw into.
public enum LavaClient {
    /// - Parameters:
    ///   - title: names the window the compositor opens, and the arena.
    ///   - width/height: a *request*. The window manager has the last word,
    ///     and the size to actually draw at arrives as the opening `Resize` on
    ///     the input stream. A client that trusts these numbers instead draws
    ///     at the wrong size on any tiling WM.
    public static func open(
        title: String,
        width: Float = 1280,
        height: Float = 800
    ) -> Editor? {
        Self.title = title
        Self.requestedWidth = width
        Self.requestedHeight = height
        guard let editor = LavaApp.openClient(width: width, height: height) else {
            fail("client engine failed to open")
        }

        let compositor: Compositor
        do {
            let (proxy, rpc) = try connectToCompositor()
            compositor = proxy
            // Held for the process's lifetime: the `Rpc` owns the transport,
            // and ARC releases a local at its last use, not at end of scope.
            runtime = rpc
        } catch {
            fail("no compositor (\(error)) — is the renderer running?")
        }

        // Before anything loads a face or an image. Ids already stamped into a
        // `UIFont` are not revisited, and `openClient` has just bootstrapped
        // the default one against the local table.
        editor.resources = CompositorResources(compositor)
        if FontStore.bootstrap(
            assetsRoot: LavaResources.root, pixelSize: 16, into: editor
        ) == nil {
            fail("no UI face from the compositor")
        }

        // Namespaced by pid: `DrawArena.create` refuses an id that already
        // exists, which is the right refusal and exactly what two clients of
        // the same compositor would hit if the id were a constant.
        let arenaID = "\(title.replacingOccurrences(of: " ", with: "-"))-\(getpid())"

        // The surface id is only known after `CreateSurface`, which cannot
        // happen until the arena exists, which is what the sink creates. So
        // `onPublish` reads it rather than capturing it — the first frame is
        // published from inside `LavaApp.run`, long after it is filled in.
        guard let sink = ArenaFrameSink(id: arenaID, onPublish: {
            guard surfaceID != 0 else { return }
            // Fire and forget, and correct rather than merely cheap: the
            // arena's published sequence already says what is current, so a
            // dropped one costs a frame of latency, never a frame of content.
            Task.detached { [compositor] in
                // Unreliable: write and return; no reply waiter (see sendUnreliable).
                await compositor.present(surfaceId: surfaceID)
            }
        }) else {
            fail("failed to create arena '\(arenaID)' — is one already running?")
        }
        editor.publishFrames(to: sink)
        Self.arena = sink
        Self.arenaID = arenaID
        Self.compositor = compositor
        return editor
    }

    /// Opens a *panel*: a surface docked to a screen edge.
    ///
    /// Everything `open` does, and then `run` asks for a panel instead of a
    /// window. A panel gets no title bar, is stacked above ordinary windows,
    /// and does not choose where it is — only how deep.
    ///
    /// - Parameters:
    ///   - thickness: how deep the panel is in the direction it is *not* long:
    ///     height for a top or bottom panel, width for a left or right one.
    ///     A request, like a window's size — the real one arrives as the
    ///     opening `Resize`, which is also how a panel learns its length.
    ///   - reserve: ask that windows be laid out around this panel rather than
    ///     under it. What a taskbar wants; an overlay does not.
    public static func openPanel(
        title: String,
        edge: PanelEdge = .top,
        thickness: Float = 32,
        reserve: Bool = true
    ) -> Editor? {
        Self.panel = (edge, thickness, reserve)
        // The requested size is only a starting point for layout until the
        // compositor sends the real one; a panel's length is not its own to
        // choose, so guessing the screen's width is as good as anything.
        return open(title: title, width: 1920, height: thickness)
    }

    /// Takes a surface, subscribes to its input, and runs the frame loop.
    ///
    /// Split from `open` for the reason `LavaApp` splits them: an app's
    /// one-time asset loading has to happen against an already-open `Editor`
    /// and before the first frame. `menu` and `onRawKey` mean exactly what
    /// they mean there.
    public static func run<V: View>(
        editor: Editor,
        menu: (() -> MenuBar)? = nil,
        onRawKey: ((LavaUI.InputEvent) -> Bool)? = nil,
        makeRoot: @escaping () -> V
    ) -> Never {
        guard let compositor = Self.compositor, let sink = Self.arena else {
            fail("LavaClient.run before LavaClient.open")
        }
        let arenaID = Self.arenaID

        let input: InputChannel
        do {
            // Longer than the default: this opens a window and builds a
            // swapchain on the far side, which on a cold device is not a
            // microsecond-scale call like the rest of this interface.
            surfaceID = try blockingCall(timeout: 10) {
                // The only place `open` and `openPanel` differ. Everything
                // after this — the input stream, the frame loop, `Present` —
                // is the same surface id either way, which is why the panel
                // role is a different way to *create* a surface rather than a
                // different kind of thing to own.
                if let panel = Self.panel {
                    return try await compositor.createPanel(
                        arenaId: arenaID, edge: panel.edge,
                        thickness: UInt32(panel.thickness),
                        reserve: panel.reserve, title: title
                    )
                }
                return try await compositor.createSurface(
                    arenaId: arenaID,
                    width: UInt32(requestedWidth), height: UInt32(requestedHeight),
                    title: title
                )
            }
            input = InputChannel(
                stream: try compositor.subscribeInput(surfaceId: surfaceID)
            )
        } catch {
            fail("surface setup failed: \(error)")
        }

        // Now that there is a surface to name, the clipboard has somewhere to
        // go. `openClient` deliberately left this unwired; this is the other
        // half. Both run on the frame loop, from a key handler, and both
        // block it for a round trip — a keystroke's worth of latency, in the
        // client that pressed the key.
        //
        // Failure is silence, not a crash: a compositor that went away is
        // about to end this process through the input stream anyway, and a
        // paste that inserts nothing is a better last act than a trap.
        ClipboardBridge.reader = { [compositor] in
            do {
                return try blockingCall {
                    try await compositor.getClipboard(surfaceId: surfaceID)
                }
            } catch {
                FileHandle.standardError.write(
                    Data("GetClipboard failed: \(error)\n".utf8)
                )
                return ""
            }
        }
        ClipboardBridge.writer = { [compositor] text in
            do {
                try blockingCall {
                    try await compositor.setClipboard(
                        surfaceId: surfaceID, text: text
                    )
                }
            } catch {
                FileHandle.standardError.write(
                    Data("SetClipboard failed: \(error)\n".utf8)
                )
            }
        }

        // A wheel notch this tree declined, handed back to the scene that
        // forwarded it. Fire and forget, like `Present` and for the same
        // reason: the renderer owns the offset, so this is a nudge rather than
        // a fact, and the wheel arrives in bursts that must not each cost the
        // frame loop a round trip.
        ScrollBridge.handBack = { [compositor] dx, dy in
            Task.detached {
                await compositor.scrollUnclaimed(surfaceId: surfaceID, dx: dx, dy: dy)
            }
        }

        // The agent's screenshot, which is the one command that checks what a
        // user would actually see and the one a client could not answer.
        // Longer budget than the rest: this is a GPU read-back plus a PNG
        // encode of a whole window on the far side.
        ScreenshotBridge.provider = { [compositor] x, y, w, h, maxSide in
            do {
                let shot = try blockingCall(timeout: 10) {
                    try await compositor.captureSurface(
                        surfaceId: surfaceID, x: x, y: y, w: w, h: h,
                        maxSide: maxSide
                    )
                }
                // Base64 here rather than on the wire: it is the agent's JSON
                // that wants text, and the compositor does not speak it.
                return (
                    Data(shot.png).base64EncodedString(),
                    Int32(shot.width), Int32(shot.height)
                )
            } catch {
                FileHandle.standardError.write(
                    Data("CaptureSurface failed: \(error)\n".utf8)
                )
                return nil
            }
        }

        // Same shape again: the `FileDrop` event crosses on the stream, its
        // paths do not fit in it, and this is the call that carries them. The
        // window id is ignored because a client has exactly one surface — the
        // day it has two, this closure is where that becomes a lookup.
        DropBridge.provider = { [compositor] _ in
            do {
                return try blockingCall {
                    try await compositor.takeDroppedPaths(surfaceId: surfaceID)
                }
            } catch {
                FileHandle.standardError.write(
                    Data("TakeDroppedPaths failed: \(error)\n".utf8)
                )
                return []
            }
        }

        // Events arrive on an NPRPC thread and are consumed on the frame
        // loop's, which is what `MainQueue` is for — it hops the work over and
        // wakes the loop out of `pumpEvents` on the way. Draining inside that
        // hop is also the honest moment to ack: the serial then means "the
        // tree has seen it", not "the socket has".
        input.onArrival = {
            MainQueue.async {
                for event in input.drain() {
                    editor.postInputEvent(
                        LavaUI.InputEvent(
                            kind: InputEventKind(rawValue: event.kind) ?? .none,
                            x: event.x, y: event.y,
                            button: event.button, mods: event.mods
                        )
                    )
                }
                // Input is not a repaint request on its own — the loop
                // consumes it and then asks invalidation what to do — but the
                // frame it produces has to be asked for, because nothing in
                // the queue does it.
                ViewInvalidation.markNeedsRedraw()
            }
        }

        // The stream is the surface's lease. When it ends — the user closed
        // the window, the compositor went away, the client was evicted — the
        // surface goes with it and there is nothing left to draw into.
        Thread.detachNewThread {
            while !input.isClosed { Thread.sleep(forTimeInterval: 0.25) }
            FileHandle.standardError.write(Data("surface closed — exiting\n".utf8))
            exit(0)
        }

        let banner = "client up — surface \(surfaceID), arena '\(arenaID)' "
            + "(\(sink.mappedBytes / 1024) KiB)\n"
        FileHandle.standardError.write(Data(banner.utf8))

        LavaApp.run(editor: editor, menu: menu, onRawKey: onRawKey, makeRoot: makeRoot)
        exit(0)
    }

    /// Set once, before the first publish can read it. See `run`.
    nonisolated(unsafe) private static var surfaceID: UInt32 = 0
    /// Handed from `open` to `run`. Statics rather than a returned handle so
    /// the pair reads exactly like `LavaApp.open`/`LavaApp.run`, which an app
    /// is switching between.
    nonisolated(unsafe) private static var compositor: Compositor?
    nonisolated(unsafe) private static var arena: ArenaFrameSink?
    nonisolated(unsafe) private static var arenaID = ""
    nonisolated(unsafe) private static var title = ""
    nonisolated(unsafe) private static var requestedWidth: Float = 1280
    nonisolated(unsafe) private static var requestedHeight: Float = 800
    /// Set by `openPanel`; nil for an ordinary window.
    nonisolated(unsafe) private static var panel:
        (edge: PanelEdge, thickness: Float, reserve: Bool)?
    /// The `Rpc` owns the transport — the shared-memory listener, its ring
    /// buffers, the worker threads — and dropping it tears all of that down.
    nonisolated(unsafe) private static var runtime: Rpc?

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
#endif
