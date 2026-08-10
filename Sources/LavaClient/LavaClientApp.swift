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
    ///   - frame: who draws the non-client area. `.server` is the compositor's
    ///     title bar, which costs 32 pixels above the app and gives it a drag
    ///     handle and a close button for free. `.client` is those pixels back:
    ///     the window is the app's content and nothing else, and the app places
    ///     `WindowControls()` and `.windowDrag()` wherever its own design wants
    ///     them — or nowhere, for an overlay that should have no chrome at all.
    ///   - fillScreen: ask for the whole screen, whatever size it is. Replaces
    ///     `width`/`height` with the largest screen the compositor has, which
    ///     is both a better *request* and — the reason this exists — a
    ///     truthful size to lay out at while the opening `Resize` is in
    ///     flight. Asking for something deliberately bigger than any screen
    ///     works for the request and is a lie to the layout: the tree lays out
    ///     once at the size that was asked for, so a virtualised list
    ///     materialises every row a 4K window would show before being told the
    ///     window is a quarter of that.
    public static func open(
        title: String,
        width: Float = 1280,
        height: Float = 800,
        frame: WindowFrame = .server,
        fillScreen: Bool = false
    ) -> Editor? {
        Self.title = title
        Self.requestedWidth = width
        Self.requestedHeight = height
        Self.frame = frame
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

        // What the desktop looks like, before the first body runs — a view
        // reading `WindowBridge.desktopCornerRadius` as it builds must not see
        // a zero that is about to become a twelve.
        //
        // Not fatal if it fails: a compositor too old to answer leaves the
        // radius at 0, which means square, which is what this looked like
        // before there was a radius at all.
        report("GetAppearance") {
            let appearance = try blockingCall {
                try await compositor.getAppearance()
            }
            WindowBridge.desktopCornerRadius = appearance.cornerRadius
            WindowBridge.desktopShadow = (
                blur: appearance.shadowBlur,
                opacity: appearance.shadowOpacity,
                offsetY: appearance.shadowOffsetY
            )
        }

        // Before the first body runs, for the same reason as the appearance
        // above: a tree that lays out at a size nobody has, and then again at
        // the real one, has done all of its work twice — and a virtualised
        // list has done the expensive half of it for rows that were never on
        // screen. Failure leaves the requested size alone, which is the
        // behaviour this replaces.
        if fillScreen {
            report("ListOutputs") {
                let outputs = try blockingCall { try await compositor.listOutputs() }
                // The largest single screen rather than the bounding box of
                // all of them: a window lives on one screen, and the
                // compositor clamps this to that screen's work area anyway.
                guard let largest = outputs
                    .filter({ $0.enabled && $0.width > 0 && $0.height > 0 })
                    .max(by: { $0.width * $0.height < $1.width * $1.height })
                else { return }
                Self.requestedWidth = Float(largest.width)
                Self.requestedHeight = Float(largest.height)
                editor.setClientSize(
                    width: Self.requestedWidth, height: Self.requestedHeight
                )
            }
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
        Self.panelReserved = reserve ? thickness : 0
        // The requested size is only a starting point for layout until the
        // compositor sends the real one; a panel's length is not its own to
        // choose, so guessing the screen's width is as good as anything.
        return open(title: title, width: 1920, height: thickness)
    }

    /// Grows or shrinks this panel, keeping what it reserves.
    ///
    /// For a panel that has to draw something taller than its strip — a menu
    /// dropdown is the case this exists for. The windows underneath do not
    /// move, because the reservation is unchanged; the panel simply has more
    /// surface, and takes the clicks that land in it, which is what dismisses
    /// an open menu.
    ///
    /// Pass `reserved: nil` to keep the reservation the panel was opened with,
    /// which is almost always what a caller means.
    public static func setPanelThickness(_ thickness: Float, reserved: Float? = nil) {
        guard let compositor = Self.compositor, surfaceID != 0 else { return }
        let claim = reserved ?? Self.panelReserved
        report("SetPanelThickness") {
            try blockingCall {
                try await compositor.setPanelThickness(
                    surfaceId: surfaceID,
                    thickness: UInt32(max(1, thickness)),
                    reserved: UInt32(max(0, claim))
                )
            }
        }
    }

    /// Every window on the desktop, and again whenever the set changes.
    ///
    /// What a dock or a task list is built on: the compositor knows which
    /// windows exist and a client cannot see past its own. `handler` runs on
    /// the frame loop with the whole list — a snapshot, not a delta, so a
    /// shell that draws what it is handed is always right.
    ///
    /// The first call back is the state at subscription, so a dock started
    /// after the windows are open is not empty until one of them moves.
    public static func onWindowList(
        _ handler: @escaping @Sendable (UInt32, [WindowInfo]) -> Void
    ) {
        guard let compositor = Self.compositor else { return }
        let stream: NPRPCBidiStream<WindowListAck, WindowList>
        do {
            stream = try compositor.subscribeWindows()
        } catch {
            FileHandle.standardError.write(
                Data("SubscribeWindows failed: \(error)\n".utf8)
            )
            return
        }
        Task.detached {
            do {
                for try await list in stream.reader {
                    let workspace = list.currentWorkspace
                    let windows = list.windows
                    let serial = list.serial
                    MainQueue.async { handler(workspace, windows) }
                    try? await stream.writer.write(WindowListAck(serial: serial))
                }
            } catch {
                FileHandle.standardError.write(
                    Data("window list stream ended: \(error)\n".utf8)
                )
            }
            stream.writer.close()
        }
    }

    /// Brings a window forward: restores, raises and focuses it in one go.
    /// What a dock icon does when it is clicked.
    public static func activateWindow(_ surfaceId: UInt32) {
        guard let compositor = Self.compositor else { return }
        report("ActivateWindow") {
            try blockingCall {
                try await compositor.activateWindow(surfaceId: surfaceId)
            }
        }
    }

    /// Hides a window without ending it, by surface id.
    ///
    /// The window-state calls on `WindowBridge` act on *this* client's own
    /// window; a shell acts on somebody else's, which is why this one takes an
    /// id and lives here rather than there.
    public static func minimizeWindow(_ surfaceId: UInt32) {
        guard let compositor = Self.compositor else { return }
        report("Minimize") {
            try blockingCall {
                try await compositor.minimize(surfaceId: surfaceId)
            }
        }
    }

    /// Limits where this surface takes pointer input, in its own coordinates.
    ///
    /// For a panel that draws less than it covers — a dock floating over the
    /// desktop is a full-width strip with a few icons in it, and panels are
    /// hit-tested above windows, so without this the empty half of the strip
    /// swallows clicks meant for the window underneath. Pass a zero size to go
    /// back to the whole surface.
    public static func setInputRegion(
        x: Float, y: Float, width: Float, height: Float
    ) {
        guard let compositor = Self.compositor, surfaceID != 0 else { return }
        report("SetInputRegion") {
            try blockingCall {
                try await compositor.setInputRegion(
                    surfaceId: surfaceID, x: Int32(x), y: Int32(y),
                    w: UInt32(max(0, width)), h: UInt32(max(0, height))
                )
            }
        }
    }

    /// The focused window, now and whenever it changes.
    ///
    /// For a panel: a global menu shows the *active* window's menu, and the
    /// compositor is the only process that knows which that is. `handler` runs
    /// on the frame loop — the same place a view's state may be touched — with
    /// the surface id (0 for none) and the window's title.
    ///
    /// Call after `run` has a surface. The first call back is the state at
    /// subscription rather than the next change, so a panel that started last
    /// is not blank until the user clicks something.
    public static func onActiveWindow(
        _ handler: @escaping @Sendable (UInt32, String, String, String) -> Void
    ) {
        guard let compositor = Self.compositor else { return }
        let stream: NPRPCBidiStream<FocusAck, ActiveWindow>
        do {
            stream = try compositor.subscribeActiveWindow()
        } catch {
            FileHandle.standardError.write(
                Data("SubscribeActiveWindow failed: \(error)\n".utf8)
            )
            return
        }
        Task.detached {
            do {
                for try await window in stream.reader {
                    let id = window.surfaceId
                    let title = window.title
                    let menuService = window.menuService
                    let menuObjectPath = window.menuObjectPath
                    MainQueue.async {
                        handler(id, title, menuService, menuObjectPath)
                    }
                    // Cheap, and the only thing that keeps the stream's flow
                    // control moving — see `FocusAck`.
                    try? await stream.writer.write(FocusAck(surfaceId: id))
                }
            } catch {
                FileHandle.standardError.write(
                    Data("active window stream ended: \(error)\n".utf8)
                )
            }
            stream.writer.close()
        }
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
                        reserve: panel.reserve, title: title,
                        appId: Self.appId
                    )
                }
                return try await compositor.createSurface(
                    arenaId: arenaID,
                    width: UInt32(requestedWidth), height: UInt32(requestedHeight),
                    title: title, frame: Self.frame, appId: Self.appId
                )
            }
            inputChannel = InputChannel(
                stream: try compositor.subscribeInput(surfaceId: surfaceID)
            )
        } catch {
            fail("surface setup failed: \(error)")
        }
        guard let input = inputChannel else {
            fail("surface setup failed: no input channel")
        }

        // The id this app's menu is registered under, and the same id the
        // compositor reports when this window takes focus — which is what lets
        // a panel pair the two. Set before `LavaApp.run` builds the `MenuHost`,
        // since that is when the registration happens.
        MenuHost.exportWindowId = surfaceID

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
        // The other selection — what middle-click pastes. Written whenever a
        // selection is *made* rather than copied, so this one is on the path
        // of a drag ending and is worth being the cheap call that it is.
        ClipboardBridge.primaryReader = { [compositor] in
            do {
                return try blockingCall {
                    try await compositor.getPrimarySelection(surfaceId: surfaceID)
                }
            } catch {
                FileHandle.standardError.write(
                    Data("GetPrimarySelection failed: \(error)\n".utf8)
                )
                return ""
            }
        }
        ClipboardBridge.primaryWriter = { [compositor] text in
            do {
                try blockingCall {
                    try await compositor.setPrimarySelection(
                        surfaceId: surfaceID, text: text
                    )
                }
            } catch {
                FileHandle.standardError.write(
                    Data("SetPrimarySelection failed: \(error)\n".utf8)
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

        // The window's own chrome, for an app drawing its own frame — and for
        // one that is not, since a menu item that maximizes is as good a caller
        // as a button. `close` needs nothing here: a client's window is held by
        // its input stream, so ending the app is how it closes.
        //
        // Blocking, like the clipboard and for the same reason: these run on
        // the frame loop from a press handler, and the round trip is the ~7 µs
        // shared memory takes rather than anything a user could see. `drag` in
        // particular *must* be synchronous — the compositor is about to take
        // the pointer, and a detached task would let the release race it.
        WindowBridge.drawsOwnChrome = Self.frame == .client
        WindowBridge.beginDrag = { [compositor] in
            report("BeginMove") {
                try blockingCall { try await compositor.beginMove(surfaceId: surfaceID) }
            }
        }
        WindowBridge.toggleMaximize = { [compositor] in
            report("ToggleMaximize") {
                _ = try blockingCall {
                    try await compositor.toggleMaximize(surfaceId: surfaceID)
                }
            }
        }
        WindowBridge.minimize = { [compositor] in
            report("Minimize") {
                try blockingCall { try await compositor.minimize(surfaceId: surfaceID) }
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
        // the window from the compositor side, the compositor went away, the
        // client was evicted — the surface goes with it and there is nothing
        // left to draw into.
        Thread.detachNewThread {
            while !input.isClosed { Thread.sleep(forTimeInterval: 0.05) }
            FileHandle.standardError.write(Data("surface closed — exiting\n".utf8))
            exit(0)
        }

        startHeartbeat(compositor)

        let banner = "client up — surface \(surfaceID), arena '\(arenaID)' "
            + "(\(sink.mappedBytes / 1024) KiB), "
            + "corner radius \(Int(WindowBridge.desktopCornerRadius))\n"
        FileHandle.standardError.write(Data(banner.utf8))

        LavaApp.run(editor: editor, menu: menu, onRawKey: onRawKey, makeRoot: makeRoot)
        // Frame-loop return (client chrome X, `LavaApp.closeWindow`, …).
        // Handlers that call `exit` directly never get here — use `quit()`.
        quit()
    }

    /// Ends this client: drops the surface on the compositor, then exits.
    ///
    /// Prefer this over bare `exit(0)`. Shared-memory NPRPC only notices a
    /// dead peer on a ~500 ms poll, so a process that dies without
    /// `DestroySurface` leaves its window on screen for that long. Compositor
    /// shortcuts (Mod+Q) destroy the surface themselves and feel instant;
    /// Escape / "launch then close" in a launcher must take this path to match.
    ///
    /// Safe to call from a key handler on the frame loop. Idempotent.
    public static func quit() -> Never {
        releaseSurface()
        exit(0)
    }

    /// Drops this client's window on the compositor before the process ends.
    ///
    /// Idempotent: if the compositor already destroyed it (its own close
    /// button, or the stream ended first), `DestroySurface` is a no-op error
    /// we ignore.
    private static func releaseSurface() {
        let id = surfaceID
        let compositor = Self.compositor
        let input = inputChannel
        surfaceID = 0
        // Visual first: scene node gone before we do anything else.
        if id != 0, let compositor {
            do {
                try blockingCall {
                    try await compositor.destroySurface(surfaceId: id)
                }
            } catch {
                // Already gone is the ordinary race with compositor-side close.
            }
        }
        input?.close()
        inputChannel = nil
    }

    /// Set once, before the first publish can read it. See `run`.
    nonisolated(unsafe) private static var surfaceID: UInt32 = 0
    /// Input lease for `quit()` / compositor-side close. Set in `run`.
    nonisolated(unsafe) private static var inputChannel: InputChannel?
    /// Handed from `open` to `run`. Statics rather than a returned handle so
    /// the pair reads exactly like `LavaApp.open`/`LavaApp.run`, which an app
    /// is switching between.
    ///
    /// Visible inside the module so `DesktopSettings` can reach the same
    /// connection rather than opening a second one: the compositor's reference
    /// is a shared-memory session, and two of them from one process would be
    /// two sets of ring buffers for one client.
    nonisolated(unsafe) static var compositor: Compositor?
    nonisolated(unsafe) private static var arena: ArenaFrameSink?
    nonisolated(unsafe) private static var arenaID = ""
    nonisolated(unsafe) private static var title = ""
    nonisolated(unsafe) private static var requestedWidth: Float = 1280
    nonisolated(unsafe) private static var requestedHeight: Float = 800
    /// Who draws the non-client area. Read once, at `CreateSurface`.
    nonisolated(unsafe) private static var frame: WindowFrame = .server
    /// What this application calls itself, for a dock looking for its icon.
    /// The executable's name unless the app says otherwise, which is the
    /// closest thing a process has to an identity without being told one.
    nonisolated(unsafe) private static var appId =
        ProcessInfo.processInfo.processName
    /// Set by `openPanel`; nil for an ordinary window.
    nonisolated(unsafe) private static var panel:
        (edge: PanelEdge, thickness: Float, reserve: Bool)?
    /// What this panel reserves, kept across a thickness change so a caller
    /// growing the panel for a menu does not have to restate it.
    nonisolated(unsafe) private static var panelReserved: Float = 0
    /// The `Rpc` owns the transport — the shared-memory listener, its ring
    /// buffers, the worker threads — and dropping it tears all of that down.
    nonisolated(unsafe) private static var runtime: Rpc?

    /// How often to say "still drawing". The compositor waits several of
    /// these before concluding anything, so this is a cheap number rather than
    /// a tuned one: six datagrams a minute, no reply, no round trip.
    private static let heartbeatInterval: TimeInterval = 2

    /// Tells the compositor this client is still drawing, for as long as it is.
    ///
    /// The beat is sent from the **frame loop**, not from the thread that
    /// times it, and that is the whole design. A timer thread proves the
    /// process exists — which the compositor can already see, since it is the
    /// parent — while a beat that has to pass through `MainQueue` proves the
    /// loop that draws is still turning. An app deadlocked in its own view
    /// tree looks perfectly healthy to `waitpid` and stops beating here.
    ///
    /// Every client does this; only the components the compositor started are
    /// watched, and a client is not told which it is. That keeps the rule
    /// simple — there is no supervised mode to get wrong — at the cost of a
    /// datagram every two seconds from windows nobody is watching.
    private static func startHeartbeat(_ compositor: Compositor) {
        let surface = surfaceID
        guard surface != 0 else { return }
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: heartbeatInterval)
                MainQueue.async {
                    // Inside the queue: reaching here is the fact being
                    // reported. `[unreliable]`, so this neither waits for a
                    // reply nor blocks the loop it is running on.
                    Task.detached {
                        await compositor.heartbeat(surfaceId: surface)
                    }
                }
            }
        }
    }

    /// Runs a control-plane call whose failure is worth saying and not worth
    /// crashing over. A window that would not maximize is a bad frame, not a
    /// bad process — and the compositor going away already ends this one
    /// through the input stream.
    private static func report(_ call: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            FileHandle.standardError.write(
                Data("\(call) failed: \(error)\n".utf8)
            )
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
