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
        fillScreen: Bool = false,
        dialogParent: UInt32? = nil
    ) -> Editor? {
        Self.title = title
        Self.requestedWidth = width
        Self.requestedHeight = height
        Self.frame = frame
        Self.dialogParent = dialogParent
        // A picker this app opens is a dialog of this window. Read when the
        // picker is asked for, by which time the surface exists.
        // Read when a picker is asked for, by which time a second window may
        // be the one asking. The window the app started with is the fallback
        // for a call that has no window current.
        FileDialog.parentSurface = {
            let id = Self.callingSurface()
            return id == 0 ? nil : id
        }
        FileHandle.standardError.write(
            Data("lava fonts: \(LavaResources.fontsDirectory)\n".utf8)
        )
        guard let editor = Editor.openClient(width: width, height: height) else {
            fail("client engine failed to open")
        }
        if FontStore.bootstrap(
            assetsRoot: LavaResources.root, pixelSize: 16, into: editor
        ) == nil {
            FileHandle.standardError.write(
                Data("warning: default UIFont failed to load\n".utf8)
            )
        }
        if FontStore.symbols == nil {
            FileHandle.standardError.write(
                Data("warning: symbol font missing (Noto Sans Symbols 2)\n".utf8)
            )
        }

        let compositor: Compositor
        do {
            let (proxy, rpc) = try connectToCompositor()
            compositor = proxy
            // Capture (and CreateSurface) can exceed the 1s default: a PNG of
            // a window is the one call that does real GPU work. The switcher
            // fires one per open window.
            compositor.timeout = 10_000
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

        // Same moment as appearance: a panel dropdown that reads
        // `Theme.current` on the first body must not paint the baked-in
        // `.dark` and then snap when the theme stream arrives a frame later.
        report("GetSystemTheme") {
            let theme = try blockingCall {
                try await compositor.getSystemTheme()
            }
            applySystemTheme(theme.name)
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
                // The primary if the compositor has one, otherwise the
                // largest: a window lives on one screen, and the compositor
                // clamps this to that screen's work area anyway.
                let enabled = outputs.filter {
                    $0.enabled && $0.width > 0 && $0.height > 0
                }
                guard let chosen = enabled.first(where: { $0.primary })
                    ?? enabled.max(by: {
                        $0.width * $0.height < $1.width * $1.height
                    })
                else { return }
                Self.requestedWidth = Float(chosen.width)
                Self.requestedHeight = Float(chosen.height)
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
        //
        // The session goes in the name as well, and only for the sake of
        // whoever is reading `/dev/shm`. Which compositor a mapping is for is
        // never in doubt — the id travels over this client's own connection,
        // to the one compositor that then opens it — but `/dev/shm` is a
        // single namespace shared by every session on the machine, and with
        // two of them running, a list of `lava-arena-*` otherwise says
        // nothing about who is drawing what.
        let name = title.replacingOccurrences(of: " ", with: "-")
        let session = ControlPlane.sessionName.map { "\($0)-" } ?? ""
        let arenaID = "\(name)-\(session)\(getpid())"

        // The surface id is only known after `CreateSurface`, which cannot
        // happen until the arena exists, which is what the sink creates. So
        // `onPublish` reads it rather than capturing it — the first frame is
        // published from inside `LavaApp.run`, long after it is filled in.
        guard let sink = ArenaFrameSink(id: arenaID, onPublish: {
            guard surfaceID != 0 else { return }
            // Fire and forget, and correct rather than merely cheap: the
            // arena's published sequence already says what is current, so a
            // dropped one costs a frame of latency, never a frame of content.
            // Read here rather than in the task: this runs on the frame
            // loop, straight after the frame was laid out, so it names the
            // input that frame actually reflects. A task that read it later
            // could pick up an event that arrived in between and claim a
            // frame knew something it did not.
            let serial = inputChannel?.consumedSerial ?? 0
            Task.detached { [compositor] in
                // Unreliable: write and return; no reply waiter (see sendUnreliable).
                await compositor.present(surfaceId: surfaceID, serial: serial)
            }
        }) else {
            fail("failed to create arena '\(arenaID)' — is one already running?")
        }
        editor.publishFrames(to: sink)
        Self.arena = sink
        Self.arenaID = arenaID
        Self.compositor = compositor
        subscribeSystemTheme()
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


    /// Opens the surface a context menu is drawn into.
    ///
    /// Everything `open` does, and then `run` asks for a *menu* surface
    /// instead of a window. The compositor stacks it above the panels, keeps
    /// it hidden between menus, places it at the pointer when `showMenu` says
    /// how big it is, and holds a pointer grab while it is up — see
    /// `CreateMenuSurface` in the IDL.
    ///
    /// - Parameters:
    ///   - width/height: the largest menu this client expects to draw. They
    ///     size the arena and nothing else; every menu is shown at the size
    ///     `showMenu` names. Too small means a menu that cannot grow into its
    ///     own arena, so err upwards — the arena is host memory, not VRAM.
    public static func openMenuSurface(
        title: String,
        width: Float = 480,
        height: Float = 720
    ) -> Editor? {
        Self.menuSurface = (width, height)
        // `.client`: a menu with a title bar would be a joke at the user's
        // expense. The compositor gives one none regardless; saying so here
        // keeps the client's own layout honest about where its content starts.
        return open(title: title, width: width, height: height, frame: .client)
    }

    /// "I have laid out the menu for `serial`; it is `width` × `height`."
    ///
    /// Call it **after** publishing a frame at that size — `Editor
    /// .setClientSize` then a draw — because the compositor reveals the
    /// surface as soon as this returns and shows whatever the arena holds. A
    /// client that asks first and draws second flashes the previous menu.
    public static func showMenu(serial: UInt32, width: Float, height: Float) {
        guard let compositor = Self.compositor, surfaceID != 0 else { return }
        report("ShowMenu") {
            try blockingCall {
                try await compositor.showMenu(
                    surfaceId: surfaceID, serial: serial,
                    width: UInt32(max(1, width.rounded())),
                    height: UInt32(max(1, height.rounded()))
                )
            }
        }
    }

    /// The compositor surface for one of this process's windows. The window
    /// the process started with is the root menu; a fly-out is an extra.
    public static func compositorSurface(for window: WindowID) -> UInt32 {
        if window == .main { return surfaceID }
        return extraSurfaces[window.rawValue]?.surface ?? 0
    }

    /// "This fly-out measured `width` × `height`. Hang it off `row`."
    ///
    /// `row` is in `parent`'s coordinates — the plate the row was drawn on,
    /// which is the root menu for the first branch and the previous branch
    /// after that. A stale serial is ignored by the compositor; a surface it
    /// has already destroyed answers `SurfaceNotFound`, which is the same
    /// fact told a second way and not a failure to report.
    public static func showSubmenu(
        window: WindowID, parent: UInt32, serial: UInt32,
        row: LayoutFrame, width: Float, height: Float
    ) {
        guard let compositor = Self.compositor else { return }
        let surface = compositorSurface(for: window)
        guard surface != 0, parent != 0 else { return }
        report("ShowSubmenu") {
            try blockingCall {
                try await compositor.showSubmenu(
                    surfaceId: surface, parentId: parent, serial: serial,
                    rowX: Int32(row.x.rounded()),
                    rowY: Int32(row.y.rounded()),
                    rowW: UInt32(max(1, row.w.rounded())),
                    rowH: UInt32(max(1, row.h.rounded())),
                    width: UInt32(max(1, width.rounded())),
                    height: UInt32(max(1, height.rounded()))
                )
            }
        }
    }

    /// The menus this client is asked to draw, and the answers it gives back.
    ///
    /// `handler` runs on the frame loop with the request the compositor sent;
    /// a request with `serial == 0` and no items is a **close** — whatever is
    /// showing should stop, and no reply is expected (see `MenuRequest`).
    ///
    /// The returned closure is how a choice is reported: pass the `MenuItem
    /// .id` that was clicked, or 0 for dismissed. Exactly one reply per
    /// request — a menu that closes without one leaves the compositor holding
    /// a grab for a surface nobody is drawing.
    public static func onMenuRequest(
        _ handler: @escaping @Sendable (MenuRequest, @escaping @Sendable (UInt32, UInt32) -> Void) -> Void
    ) {
        guard Self.compositor != nil else { return }
        guard surfaceID != 0 else {
            // Set up before the surface exists, the way a panel sets up
            // `onPanelArea`: this subscription is *about* the surface and
            // cannot be made until there is one. Held until `run` creates it.
            pendingMenuHandler = handler
            return
        }
        startMenuRequests(handler)
    }

    nonisolated(unsafe) private static var pendingMenuHandler:
        (@Sendable (MenuRequest, @escaping @Sendable (UInt32, UInt32) -> Void) -> Void)?

    private static func startMenuRequests(
        _ handler: @escaping @Sendable (MenuRequest, @escaping @Sendable (UInt32, UInt32) -> Void) -> Void
    ) {
        guard let compositor = Self.compositor, surfaceID != 0 else { return }
        let stream: NPRPCBidiStream<MenuReply, MenuRequest>
        do {
            stream = try compositor.subscribeMenu(surfaceId: surfaceID)
        } catch {
            FileHandle.standardError.write(
                Data("SubscribeMenu failed: \(error)\n".utf8)
            )
            return
        }
        Task.detached {
            do {
                for try await request in stream.reader {
                    // The writer is this task's; the handler runs on the frame
                    // loop and hands the answer back through here rather than
                    // writing from the loop thread.
                    let reply: @Sendable (UInt32, UInt32) -> Void = { serial, chosen in
                        Task.detached {
                            try? await stream.writer.write(
                                MenuReply(serial: serial, chosen: chosen)
                            )
                        }
                    }
                    MainQueue.async { handler(request, reply) }
                }
            } catch {
                FileHandle.standardError.write(
                    Data("menu stream ended: \(error)\n".utf8)
                )
            }
            stream.writer.close()
        }
    }

    // ─── Menus this client asks for ────────────────────────────────────────
    //
    // The other direction from `onMenuRequest`: that one is the desktop's
    // menu *renderer*, this is any panel that wants a menu of its own drawn
    // properly. See `OpenMenu` in the IDL for why a panel cannot do it itself
    // — the short version is that a menu has to outlive its panel's surface,
    // sit above every window, and come down on a click the panel never sees.

    /// The answers to this client's own `openMenu` calls.
    ///
    /// `handler` runs on the frame loop with the `MenuItem.id` that was
    /// chosen, or 0 for a menu the user dismissed. Set this **before** opening
    /// a menu: the compositor refuses to open one for a client that is not
    /// listening, rather than take a grab for an answer that goes nowhere.
    public static func onMenuChoice(
        _ handler: @escaping @Sendable (UInt32, UInt32) -> Void
    ) {
        guard Self.compositor != nil else { return }
        guard surfaceID != 0 else {
            // Held until `run` creates the surface, like every subscription
            // that is *about* the surface rather than about the session.
            pendingMenuChoice = handler
            return
        }
        startMenuChoice(handler)
    }

    nonisolated(unsafe) private static var pendingMenuChoice:
        (@Sendable (UInt32, UInt32) -> Void)?

    private static func startMenuChoice(
        _ handler: @escaping @Sendable (UInt32, UInt32) -> Void
    ) {
        guard let compositor = Self.compositor, surfaceID != 0 else { return }
        let stream: NPRPCBidiStream<MenuChoiceAck, MenuChoice>
        do {
            stream = try compositor.subscribeMenuChoice(surfaceId: surfaceID)
        } catch {
            FileHandle.standardError.write(
                Data("SubscribeMenuChoice failed: \(error)\n".utf8)
            )
            return
        }
        Task.detached {
            do {
                for try await choice in stream.reader {
                    let serial = choice.serial
                    let chosen = choice.chosen
                    MainQueue.async { handler(serial, chosen) }
                    try? await stream.writer.write(MenuChoiceAck(serial: serial))
                }
            } catch {
                FileHandle.standardError.write(
                    Data("menu choice stream ended: \(error)\n".utf8)
                )
            }
            stream.writer.close()
        }
    }

    /// Asks the compositor to show a menu for this surface.
    ///
    /// `x` and `y` are in this surface's own coordinates — the point the menu
    /// hangs off, usually the top of whatever was clicked. The compositor
    /// places it from there and flips it above the anchor when there is no
    /// room below, which is what a panel at the bottom edge always wants.
    ///
    /// Returns the serial the answer will name, or 0 when there is no menu
    /// client on this desktop to draw it — a caller that has a fallback can
    /// use it then, and one that has none has correctly done nothing.
    ///
    /// The ids in `items` are this client's own. They come back through
    /// `onMenuChoice` untouched, and nothing between here and there reads
    /// them.
    @discardableResult
    public static func openMenu(
        x: Float, y: Float, title: String = "", items: [LavaIDL.MenuItem]
    ) -> UInt32 {
        guard let compositor = Self.compositor, surfaceID != 0 else { return 0 }
        guard !items.isEmpty else { return 0 }
        do {
            return try blockingCall {
                try await compositor.openMenu(
                    surfaceId: surfaceID,
                    x: Int32(x.rounded()), y: Int32(y.rounded()),
                    title: title, items: items
                )
            }
        } catch {
            FileHandle.standardError.write(
                Data("OpenMenu failed: \(error)\n".utf8)
            )
            return 0
        }
    }

    /// Size last asked of `CreateSurface`. After `fillScreen: true` this is
    /// the largest enabled output — available before the surface exists.
    public static var requestedSize: (width: Float, height: Float) {
        (requestedWidth, requestedHeight)
    }

    /// Connect the control plane and nothing else: no engine, no fonts, no
    /// surface, no frame loop.
    ///
    /// `open` is the path for something that will draw, and it pays for a
    /// Vulkan client engine and a font bootstrap before it ever reaches the
    /// compositor. A tool that only asks questions — which windows exist, put
    /// that one in front — needs none of that, and on a link-handler path it
    /// is the difference between answering in milliseconds and answering
    /// after a GPU context.
    ///
    /// Idempotent, and safe to call before `open`: both share the one
    /// connection, because two from a process would be two sets of ring
    /// buffers for one client.
    @discardableResult
    public static func connectControlPlane() -> Bool {
        if compositor != nil { return true }
        do {
            let (proxy, rpc) = try connectToCompositor()
            proxy.timeout = 10_000
            compositor = proxy
            runtime = rpc
            return true
        } catch {
            FileHandle.standardError.write(
                Data("no compositor (\(error)) — is the renderer running?\n".utf8)
            )
            return false
        }
    }

    /// The compositor's current window list, blocking, without a frame loop.
    ///
    /// For a client that has to *finish* something — capture every poster —
    /// before it may open a surface. `onWindowList` hops through `MainQueue`,
    /// which nobody drains until `run`, so waiting on that from `main` deadlocks.
    /// This reads the opening snapshot on the calling thread and closes the
    /// stream; subscribe again with `onWindowList` for later changes.
    public static func currentWindowList() -> (UInt32, [WindowInfo])? {
        guard let compositor = Self.compositor else { return nil }
        let stream: NPRPCBidiStream<WindowListAck, WindowList>
        do {
            stream = try compositor.subscribeWindows()
        } catch {
            FileHandle.standardError.write(
                Data("SubscribeWindows failed: \(error)\n".utf8)
            )
            return nil
        }
        defer { stream.writer.close() }
        do {
            let list = try blockingCall(timeout: 5) {
                for try await snapshot in stream.reader {
                    try? await stream.writer.write(
                        WindowListAck(serial: snapshot.serial)
                    )
                    return snapshot
                }
                throw ControlPlaneError.timedOut
            }
            return (list.currentWorkspace, list.windows)
        } catch {
            FileHandle.standardError.write(
                Data("currentWindowList failed: \(error)\n".utf8)
            )
            return nil
        }
    }

    /// The desktop's colour theme, and again whenever Settings changes it.
    ///
    /// Applies `Theme.current` on the frame loop and then `Theme.onSystemUpdate`,
    /// so an app that uses system colours retints and one that paints its
    /// own paper can follow or ignore. The first message is the theme at
    /// subscription — a window that opens after nebula is already picked
    /// should not flash dark.
    private static func subscribeSystemTheme() {
        guard let compositor = Self.compositor else { return }
        let stream: NPRPCBidiStream<ThemeAck, SystemTheme>
        do {
            stream = try compositor.subscribeSystemTheme()
        } catch {
            FileHandle.standardError.write(
                Data("SubscribeSystemTheme failed: \(error)\n".utf8)
            )
            return
        }
        Task.detached {
            do {
                for try await theme in stream.reader {
                    let name = theme.name
                    let serial = theme.serial
                    MainQueue.async { applySystemTheme(name) }
                    try? await stream.writer.write(ThemeAck(serial: serial))
                }
            } catch {
                FileHandle.standardError.write(
                    Data("system theme stream ended: \(error)\n".utf8)
                )
            }
            stream.writer.close()
        }
    }

    /// Wears the named palette. Unknown names are left alone — a typo in
    /// `lava.conf` should not blank a running app.
    static func applySystemTheme(_ name: String) {
        guard let theme = Theme.named(name) else { return }
        Theme.current = theme
        Theme.onSystemUpdate?(theme)
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

    /// Whether anything is in the way of this panel, now and whenever it
    /// changes.
    ///
    /// For a panel that hides itself. A dock knows where it is and nothing
    /// about what is in front of it — overlap is the compositor's to see, and
    /// this is it saying so. `covered` is false when the strip the panel
    /// occupies is clear of windows on the current workspace.
    ///
    /// Only meaningful for a panel; a window gets `false` forever.
    public static func onPanelArea(
        _ handler: @escaping @Sendable (Bool) -> Void
    ) {
        guard Self.compositor != nil else { return }
        guard surfaceID != 0 else {
            // Set up before the surface exists, which is where a panel
            // naturally puts its subscriptions — and the only one of them that
            // needs a surface id, because it is the only one that is *about*
            // the surface. Held until `run` creates it.
            pendingPanelArea = handler
            return
        }
        startPanelArea(handler)
    }

    nonisolated(unsafe) private static var pendingPanelArea:
        (@Sendable (Bool) -> Void)?

    private static func startPanelArea(
        _ handler: @escaping @Sendable (Bool) -> Void
    ) {
        guard let compositor = Self.compositor, surfaceID != 0 else { return }
        let stream: NPRPCBidiStream<PanelAreaAck, PanelArea>
        do {
            stream = try compositor.subscribePanelArea(surfaceId: surfaceID)
        } catch {
            FileHandle.standardError.write(
                Data("SubscribePanelArea failed: \(error)\n".utf8)
            )
            return
        }
        Task.detached {
            do {
                for try await area in stream.reader {
                    let covered = area.covered
                    let serial = area.serial
                    MainQueue.async { handler(covered) }
                    try? await stream.writer.write(PanelAreaAck(serial: serial))
                }
            } catch {
                FileHandle.standardError.write(
                    Data("panel area stream ended: \(error)\n".utf8)
                )
            }
            stream.writer.close()
        }
    }

    /// A PNG of another window, as the compositor currently sees it.
    ///
    /// What the app switcher puts on a card. `maxSide` downsamples the longer
    /// edge (0 = native). Nil if the window is gone or has not drawn yet —
    /// a caller should then fall back to an icon rather than retrying in a
    /// loop.
    ///
    /// Safe to call from a worker: the round trip does not touch the frame
    /// loop, and the bytes have no GPU identity until `registerImage(data:)`.
    public static func captureWindow(
        _ surfaceId: UInt32, maxSide: Int32 = 256
    ) -> [UInt8]? {
        guard let compositor = Self.compositor else { return nil }
        do {
            let shot = try blockingCall(timeout: 10) {
                try await compositor.captureSurface(
                    surfaceId: surfaceId, x: 0, y: 0, w: 0, h: 0,
                    maxSide: maxSide
                )
            }
            return shot.png.isEmpty ? nil : Array(shot.png)
        } catch {
            FileHandle.standardError.write(
                Data("CaptureSurface(\(surfaceId)) failed: \(error)\n".utf8)
            )
            return nil
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

    /// Drops the compositor's cached poster for a window.
    ///
    /// A poster is the picture an `ImageSurface` draw command resolves to, and
    /// the compositor keeps it so a shelf of windows costs one dma-buf import
    /// rather than one per frame. That cache is what a *long-lived* shell has
    /// to say something about: the switcher is spawned per invocation and gets
    /// a clean cache with its overlay, while a dock is here all session and
    /// would show the same picture the second time an icon is hovered.
    ///
    /// Say it once when a preview opens, for the windows about to be drawn —
    /// not per frame, which would recapture the whole shelf at 60 Hz.
    public static func forgetWindowPoster(_ surfaceId: UInt32) {
        guard let compositor = Self.compositor, surfaceId != 0 else { return }
        report("ForgetWindowPoster") {
            try blockingCall {
                try await compositor.forgetWindowPoster(surfaceId: surfaceId)
            }
        }
    }

    /// States the smallest this window is willing to be.
    ///
    /// A layout has a size below which it stops being one, and only the
    /// application knows where that is. Told once, the compositor clamps
    /// interactive resizes to it, so a window cannot be dragged into a shape
    /// its own author knows is broken. Zero on an axis means no opinion.
    ///
    /// Quiet when there is no compositor — a windowed build has a window
    /// manager for this, and an app should be able to say it either way.
    public static func setMinimumSize(width: Float, height: Float) {
        // Remembered, not just sent. `open` returns an `Editor` before the
        // surface exists — creation happens on the way into `run` — so an
        // application stating its minimum at the natural moment, right after
        // opening, was sending it to surface id 0 and having it dropped on the
        // floor in a guard. Storing it means the call works whenever it is
        // made, which is the only version of this that is not a trap.
        pendingMinSize = (max(0, width), max(0, height))
        flushMinimumSize()
    }

    /// Sends the stored minimum once there is a surface to attach it to.
    /// Called again from surface setup, which is where the id arrives.
    private static func flushMinimumSize() {
        guard let compositor = Self.compositor, surfaceID != 0,
              let pending = pendingMinSize
        else { return }
        report("SetMinSize") {
            try blockingCall {
                try await compositor.setMinSize(
                    surfaceId: surfaceID,
                    minWidth: UInt32(pending.width),
                    minHeight: UInt32(pending.height)
                )
            }
        }
    }

    /// Frost the desktop behind this window. `radius` 0 turns it off.
    ///
    /// Remembered like `setMinimumSize`: `open` returns before the surface
    /// exists, so an app that sets `WindowBackdrop.blur` in `main` would
    /// otherwise send it to id 0. The compositor draws a blurred copy of
    /// what is *behind* the window; the client's own pixels stay sharp.
    public static func setBackdropBlur(radius: Float) {
        pendingBackdropBlur = max(0, radius)
        flushBackdropBlur()
    }

    /// Bend the rim of this window's frost like glass, by up to `px` pixels;
    /// 0 is flat, and the default. For a small slab — a menu, a popover —
    /// rather than a window that is frosted edge to edge, where it only
    /// reads as warping. Remembered until the surface exists, like the blur.
    public static func setBackdropRefraction(px: Float) {
        pendingBackdropRefraction = max(0, px)
        flushBackdropRefraction()
    }

    private static func flushBackdropRefraction() {
        guard let compositor = Self.compositor, surfaceID != 0,
              let px = pendingBackdropRefraction
        else { return }
        report("SetBackdropRefraction") {
            try blockingCall {
                try await compositor.setBackdropRefraction(
                    surfaceId: surfaceID, px: px
                )
            }
        }
    }

    private static func flushBackdropBlur() {
        guard let compositor = Self.compositor, surfaceID != 0 else { return }
        let radius = pendingBackdropBlur
            ?? WindowBackdrop.current.compositorBlurRadius
        guard radius > 0 || pendingBackdropBlur != nil else { return }
        report("SetBackdropBlur") {
            try blockingCall {
                try await compositor.setBackdropBlur(
                    surfaceId: surfaceID, radius: radius
                )
            }
        }
    }

    /// Ends the compositor session. The panel's Log Out asks first.
    public static func endSession() {
        guard let compositor = Self.compositor else { return }
        report("EndSession") {
            try blockingCall { try await compositor.endSession() }
        }
    }

    /// Frost rectangles of the desktop behind this surface.
    ///
    /// An empty list means every popup is gone. That must not wipe a window
    /// that asked for whole-surface frost (`WindowBackdrop.blur`) — the
    /// two share the same plates, so a clear here restores the window
    /// radius when there is one. Idle frames (never had a popup) send
    /// nothing at all.
    public static func setBackdropBlurRegions(
        radius: Float, rects: [LavaIDL.FrostRect]
    ) {
        // The window whose frame is being emitted. A second window frosting
        // its own popup must not rewrite the first window's plates.
        pendingOverlayFrost = OverlayFrost(
            surface: callingSurface(),
            radius: rects.isEmpty ? 0 : max(0, radius), rects: rects
        )
        flushOverlayFrost()
    }

    private static func flushOverlayFrost() {
        guard let compositor = Self.compositor,
              let pending = pendingOverlayFrost
        else { return }
        let id = pending.surface != 0 ? pending.surface : surfaceID
        guard id != 0 else { return }
        // Per surface. One slot for the whole process made an idle frame of
        // the other window look like "the popup just closed" and cleared it,
        // then the next frame of the window that actually has one put it back.
        guard lastOverlayFrost[id] != pending else { return }

        let hadOverlay = lastOverlayFrost[id].map { $0.radius > 0 } ?? false
        lastOverlayFrost[id] = pending

        // Nothing to tell the compositor: no popup is up, and none was.
        if pending.radius == 0 && !hadOverlay { return }

        Task.detached {
            do {
                if pending.radius == 0 || pending.rects.isEmpty {
                    let windowRadius = WindowBackdrop.current.compositorBlurRadius
                    if windowRadius > 0 {
                        try await compositor.setBackdropBlur(
                            surfaceId: id, radius: windowRadius
                        )
                    } else {
                        try await compositor.setBackdropBlurRegion(
                            surfaceId: id, radius: 0,
                            x: 0, y: 0, w: 0, h: 0, cornerRadius: 0
                        )
                    }
                } else {
                    try await compositor.setBackdropBlurRegions(
                        surfaceId: id, radius: pending.radius,
                        rects: pending.rects
                    )
                }
            } catch {
                FileHandle.standardError.write(
                    Data("SetBackdropBlurRegions failed: \(error)\n".utf8)
                )
                MainQueue.async {
                    BackdropBridge.frostOverlays = nil
                    ViewInvalidation.markDirty()
                }
            }
        }
    }

    private struct OverlayFrost: Equatable, Sendable {
        var surface: UInt32
        var radius: Float
        var rects: [LavaIDL.FrostRect]

        /// By hand: the generated `FrostRect` is a wire type and carries no
        /// `Equatable`, and this comparison is what stops a call per frame
        /// for a menu that has not moved. The surface is part of it so one
        /// window's plates do not count as another's.
        static func == (a: Self, b: Self) -> Bool {
            a.surface == b.surface && a.radius == b.radius
                && a.rects.count == b.rects.count
                && zip(a.rects, b.rects).allSatisfy {
                    $0.x == $1.x && $0.y == $1.y && $0.w == $1.w
                        && $0.h == $1.h && $0.cornerRadius == $1.cornerRadius
                }
        }
    }

    /// One rectangle this surface takes pointer input in, in its own
    /// coordinates.
    ///
    /// For a panel that draws less than it covers — a dock floating over the
    /// desktop is a full-width strip with a few icons in it, and panels are
    /// hit-tested above windows, so without this the empty half of the strip
    /// swallows clicks meant for the window underneath. Pass a zero size to go
    /// back to the whole surface.
    public static func setInputRegion(
        x: Float, y: Float, width: Float, height: Float
    ) {
        let empty = width <= 0 || height <= 0
        setInputRegion(empty ? [] : [
            InputRect(
                x: Int32(x), y: Int32(y),
                w: UInt32(max(0, width)), h: UInt32(max(0, height))
            )
        ])
    }

    /// Every rectangle this surface takes pointer input in. A point counts if
    /// it is inside **any** of them; an empty list restores the whole surface.
    ///
    /// The list form exists because one rectangle could not describe the panel:
    /// its strip spans the screen and its notification cards sit at the right
    /// edge under it, so the only single rectangle containing both is the
    /// whole top of the display — which is what made a toast swallow every
    /// click along that edge until it expired.
    public static func setInputRegion(_ rects: [InputRect]) {
        guard let compositor = Self.compositor, surfaceID != 0 else { return }
        report("SetInputRegion") {
            try blockingCall {
                try await compositor.setInputRegion(
                    surfaceId: surfaceID, rects: rects
                )
            }
        }
    }

    /// Which window has focus, and everything a panel needs to show its menu.
    ///
    /// A struct rather than a handful of positional arguments because three of
    /// the five are `UInt32` and two of *those* are window ids that are equal
    /// for most clients and different for exactly the ones that were broken —
    /// a swap at a call site would be invisible until someone ran glogg.
    public struct FocusedWindow: Sendable {
        /// The compositor surface id. 0 when nothing is focused.
        public var surfaceId: UInt32 = 0
        /// What the window calls itself.
        public var title: String = ""
        /// DBus service owning the window's dbusmenu, from the KDE Wayland
        /// AppMenu protocol. Empty unless the client used it.
        public var menuService: String = ""
        /// Object path to go with `menuService`.
        public var menuObjectPath: String = ""
        /// The client's Unix pid, or 0. The only way to find a Qt5-on-Wayland
        /// menu, which registers under a window id of its own invention.
        public var pid: UInt32 = 0
        /// The key the window's menu is registered under. `surfaceId` for
        /// Wayland clients; an XID for X11 ones.
        public var registrarId: UInt32 = 0
    }

    /// The focused window, now and whenever it changes.
    ///
    /// For a panel: a global menu shows the *active* window's menu, and the
    /// compositor is the only process that knows which that is. `handler` runs
    /// on the frame loop — the same place a view's state may be touched.
    ///
    /// Call after `run` has a surface. The first call back is the state at
    /// subscription rather than the next change, so a panel that started last
    /// is not blank until the user clicks something.
    public static func onActiveWindow(
        _ handler: @escaping @Sendable (FocusedWindow) -> Void
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
                    let focused = FocusedWindow(
                        surfaceId: id,
                        title: window.title,
                        menuService: window.menuService,
                        menuObjectPath: window.menuObjectPath,
                        pid: window.pid,
                        registrarId: window.registrarId
                    )
                    MainQueue.async { handler(focused) }
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
                if let menu = Self.menuSurface {
                    return try await compositor.createMenuSurface(
                        arenaId: arenaID, width: UInt32(menu.width),
                        height: UInt32(menu.height), appId: Self.appId
                    )
                }
                if let panel = Self.panel {
                    return try await compositor.createPanel(
                        arenaId: arenaID, edge: panel.edge,
                        thickness: UInt32(panel.thickness),
                        reserve: panel.reserve, title: title,
                        appId: Self.appId
                    )
                }
                if let parent = Self.dialogParent {
                    return try await compositor.createDialogSurface(
                        arenaId: arenaID,
                        width: UInt32(requestedWidth), height: UInt32(requestedHeight),
                        title: title, frame: Self.frame, appId: Self.appId,
                        parentId: parent
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
            // Anything the application asked for before it had a surface.
            flushMinimumSize()
            flushBackdropRefraction()
            flushBackdropBlur()
            if let pending = pendingPanelArea {
                pendingPanelArea = nil
                startPanelArea(pending)
            }
            if let pending = pendingMenuHandler {
                pendingMenuHandler = nil
                startMenuRequests(pending)
            }
            if let pending = pendingMenuChoice {
                pendingMenuChoice = nil
                startMenuChoice(pending)
            }
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
        ClipboardBridge.imageReader = { [compositor] in
            do {
                return try blockingCall(timeout: 5) {
                    try await compositor.getClipboardPng(surfaceId: surfaceID)
                }
            } catch {
                FileHandle.standardError.write(
                    Data("GetClipboardPng failed: \(error)\n".utf8)
                )
                return []
            }
        }
        // The other selection — what middle-click pastes. Written whenever a
        // selection is *made* rather than copied, so this one is on the path
        // of a drag ending and is worth being the cheap call that it is.
        ClipboardBridge.imageFileWriter = { [compositor] path in
            do {
                try blockingCall {
                    try await compositor.setClipboardImageFile(
                        surfaceId: surfaceID, path: path
                    )
                }
            } catch {
                FileHandle.standardError.write(
                    Data("SetClipboardImageFile failed: \(error)\n".utf8)
                )
            }
        }

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
        ScrollBridge.handBack = { [compositor] dx, dy, window in
            let surface = Self.surface(forWindow: window)
            Task.detached {
                await compositor.scrollUnclaimed(surfaceId: surface, dx: dx, dy: dy)
            }
        }

        // The pointer image, asked for rather than set: there is one pointer
        // and it belongs to the seat. Fire and forget for the reason the wheel
        // hand-back is — this is on the pointer's path, it arrives in bursts as
        // the pointer crosses a toolbar, and a round trip per crossing would
        // sit between the pointer and the next frame.
        CursorBridge.request = { [compositor] shape, window in
            let surface = Self.surface(forWindow: window)
            let resolved = LavaIDL.CursorShape(rawValue: shape) ?? .arrow
            Task.detached {
                await compositor.setCursor(surfaceId: surface, shape: resolved)
            }
        }

        // Always arm the hook. A probe that sent radius 0 at startup
        // cleared the window frost a terminal had just asked for, and
        // every frame without a popup then kept it cleared. Idle emits
        // no-op inside `flushOverlayFrost` until a popup actually asks.
        BackdropBridge.frostOverlays = { radius, rects in
            LavaClient.setBackdropBlurRegions(
                radius: radius,
                rects: rects.map {
                    LavaIDL.FrostRect(
                        x: $0.x, y: $0.y, w: $0.w, h: $0.h,
                        cornerRadius: $0.cornerRadius
                    )
                }
            )
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
            let surface = Self.callingSurface()
            report("BeginMove") {
                try blockingCall { try await compositor.beginMove(surfaceId: surface) }
            }
        }
        WindowBridge.toggleMaximize = { [compositor] in
            let surface = Self.callingSurface()
            report("ToggleMaximize") {
                let now = try blockingCall {
                    try await compositor.toggleMaximize(surfaceId: surface)
                }
                WindowBridge.isMaximized = now
            }
        }
        WindowBridge.setFullscreen = { [compositor] on in
            let surface = Self.callingSurface()
            do {
                try blockingCall {
                    try await compositor.setFullscreen(
                        surfaceId: surface, on: on
                    )
                }
            } catch {
                FileHandle.standardError.write(
                    Data("SetFullscreen failed: \(error)\n".utf8)
                )
            }
        }

        // The desktop, which only the compositor can see. Ten seconds like the
        // agent's capture and for the same reason: an offscreen composite of a
        // whole screen plus a PNG encode of it.
        ScreenCapture.provider = {
            [compositor] includeSelf, x, y, w, h, maxSide in
            let surface = Self.callingSurface()
            do {
                return try blockingCall(timeout: 10) {
                    try await compositor.captureScreen(
                        surfaceId: surface, includeSelf: includeSelf,
                        x: x, y: y, w: w, h: h, maxSide: maxSide
                    )
                }
            } catch {
                FileHandle.standardError.write(
                    Data("CaptureScreen failed: \(error)\n".utf8)
                )
                return nil
            }
        }

        WindowBridge.minimize = { [compositor] in
            let surface = Self.callingSurface()
            report("Minimize") {
                try blockingCall { try await compositor.minimize(surfaceId: surface) }
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
        // paths do not fit in it, and this is the call that carries them.
        // The window id is which surface was dropped on — a second window
        // has its own queue.
        DropBridge.provider = { [compositor] window in
            let surface = Self.surface(forWindow: window)
            do {
                return try blockingCall {
                    try await compositor.takeDroppedPaths(surfaceId: surface)
                }
            } catch {
                FileHandle.standardError.write(
                    Data("TakeDroppedPaths failed: \(error)\n".utf8)
                )
                return []
            }
        }

        // And out. Blocking for the reason `beginDrag` is: the compositor
        // takes the pointer as it answers, and the release it hands back has
        // to arrive after this call rather than race it.
        DragBridge.startFileDrag = { [compositor] paths, chip, offsetX, offsetY, window in
            let surface = Self.surface(forWindow: window)
            // A chip too big for one message is dropped rather than failing
            // the drag: the cursor alone still says what is happening.
            let image: DragImage
            if let chip, chip.byteCount <= DragChipImage.maxWireBytes {
                image = DragImage(
                    width: chip.width, height: chip.height,
                    offsetX: offsetX, offsetY: offsetY,
                    commands: chip.commands, glyphs: chip.glyphs,
                    meshVertices: chip.meshVertices, gradients: chip.gradients
                )
            } else {
                image = DragImage()
            }
            do {
                try blockingCall {
                    try await compositor.startDrag(
                        surfaceId: surface, paths: paths, chip: image
                    )
                }
                return true
            } catch {
                FileHandle.standardError.write(
                    Data("StartDrag failed: \(error)\n".utf8)
                )
                return false
            }
        }

        // Events arrive on an NPRPC thread and are consumed on the frame
        // loop's, which is what `MainQueue` is for — it hops the work over and
        // wakes the loop out of `pumpEvents` on the way. Draining inside that
        // hop is also the honest moment to ack: the serial then means "the
        // tree has seen it", not "the socket has".
        // `.windowState` is applied by the window that receives the event,
        // inside its own scope. Setting the flag here would write the first
        // window's copy, because this hop has no window current.
        watchInput(input, window: .main, editor: editor)

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

        // Before the loop, so a window opened from the first frame has a
        // surface to draw into. Nil again is unnecessary: `run` does not
        // return until the process is leaving.
        LavaApp.ClientSurfaceBridge.open = {
            width, height, title, anchor, blur, refraction in
            Self.openExtraSurface(
                editor: editor, width: width, height: height, title: title,
                anchor: anchor, backdropBlur: blur, refraction: refraction
            )
        }
        LavaApp.ClientSurfaceBridge.openMenuPlate = {
            width, height, blur, refraction in
            Self.openExtraSurface(
                editor: editor, width: width, height: height, title: "Menu",
                anchor: nil, backdropBlur: blur, refraction: refraction,
                submenu: true
            )
        }
        LavaApp.ClientSurfaceBridge.close = { window in
            Self.closeExtraSurface(editor: editor, window: window)
        }

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
    public static func quit(activating surfaceId: UInt32? = nil) -> Never {
        // Overlay first: DestroySurface takes the fullscreen switcher off
        // the scene before we raise the target. Activate-then-quit left the
        // dimmer up until this RPC returned, which is the pause after
        // Ctrl+Tab release.
        releaseSurface()
        if let surfaceId { activateWindow(surfaceId) }
        exit(0)
    }

    /// Drops this client's window on the compositor before the process ends.
    ///
    /// Idempotent: if the compositor already destroyed it (its own close
    /// button, or the stream ended first), `DestroySurface` is a no-op error
    /// we ignore.
    private static func releaseSurface() {
        let extras = extraSurfaces
        extraSurfaces.removeAll()
        for extra in extras.values {
            editorForExtras?.stopPublishingFrames(window: extra.window)
            destroyCompositorSurface(extra.surface)
            extra.input?.close()
        }
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

    /// The compositor surface a call made from a window should name.
    ///
    /// `0` is the window the app started with. Anything else is a window
    /// `openWindow` added, and a raw id we have never seen — a call from
    /// outside any window — falls back to the first surface rather than
    /// failing the gesture.
    private static func surface(forWindow raw: UInt32) -> UInt32 {
        if raw != 0, let extra = extraSurfaces[raw], extra.surface != 0 {
            return extra.surface
        }
        return surfaceID
    }

    /// `surface(forWindow:)` for whichever window is current on the frame loop.
    private static func callingSurface() -> UInt32 {
        surface(forWindow: LavaApp.currentWindow.rawValue)
    }

    /// Drains one surface's input into one engine window.
    ///
    /// Read-back is not a repaint request. `.nodeHover` and `.nodeScroll` are
    /// the renderer telling us what it already drew, and the compositor emits
    /// one of each per frame of an eased scroll — so treating them as repaint
    /// requests makes this process publish a full draw list for every frame
    /// the compositor drew *without* it. `.dragOver` is the same shape: one
    /// arrives per pointer move, and a target that changes state invalidates
    /// through the app's own observed properties.
    private static func watchInput(
        _ input: InputChannel, window: WindowID, editor: Editor
    ) {
        input.onArrival = {
            MainQueue.async {
                var wantsFrame = false
                for event in input.drain() {
                    let kind = InputEventKind(rawValue: event.kind) ?? .none
                    if kind != .nodeHover, kind != .nodeScroll, kind != .dragOver {
                        wantsFrame = true
                    }
                    editor.postInputEvent(
                        LavaUI.InputEvent(
                            kind: kind,
                            x: event.x, y: event.y,
                            button: event.button, mods: event.mods
                        ),
                        window: window
                    )
                }
                // Input is not a repaint request on its own — the loop
                // consumes it and then asks invalidation what to do — but the
                // frame it produces has to be asked for, because nothing in
                // the queue does it.
                if wantsFrame { ViewInvalidation.markNeedsRedraw() }
            }
        }
    }

    /// A second surface. One arena, one input stream, one engine window.
    ///
    /// The stream ending closes that window and nothing else. The stream on
    /// the window the app started with is the process's lease; this one is
    /// not, or closing a mirror would quit the app.
    private static func openExtraSurface(
        editor: Editor, width: Float, height: Float, title: String,
        anchor: LavaApp.SurfaceAnchor?, backdropBlur: Float,
        refraction: Float = 0, submenu: Bool = false
    ) -> WindowID? {
        guard let compositor = Self.compositor else { return nil }
        guard let window = editor.openWindow(
            width: width, height: height, title: title
        ) else { return nil }

        let arenaName = "\(arenaID)-\(window.rawValue)"
        let extra = ExtraSurface(window: window)
        // The sink owns the callback, and the callback has to name this
        // surface. A strong capture would keep both alive after the window
        // closed, which is the mapping `stopPublishingFrames` exists to drop.
        guard let sink = ArenaFrameSink(id: arenaName, onPublish: { [weak extra] in
            guard let extra else { return }
            let surface = extra.surface
            guard surface != 0 else { return }
            let serial = extra.input?.consumedSerial ?? 0
            Task.detached {
                await compositor.present(surfaceId: surface, serial: serial)
            }
        }) else {
            editor.closeWindow(window)
            FileHandle.standardError.write(
                Data("openWindow: arena '\(arenaName)' already exists\n".utf8)
            )
            return nil
        }

        let surface: UInt32
        let w = UInt32(max(1, width.rounded()))
        let h = UInt32(max(1, height.rounded()))
        do {
            surface = try blockingCall(timeout: 10) {
                if submenu {
                    // Hidden until ShowSubmenu. A popup would place it under
                    // the panel anchor and show it before it was measured.
                    return try await compositor.createSubmenuSurface(
                        arenaId: arenaName, width: w, height: h
                    )
                }
                if let anchor {
                    // Of the window this process started with. A popup does
                    // not know where that window is; the anchor is in its
                    // coordinates and the compositor adds the origin.
                    return try await compositor.createPopupSurface(
                        arenaId: arenaName, width: w, height: h, title: title,
                        parentId: surfaceID,
                        anchorX: Int32(anchor.x.rounded()),
                        anchorY: Int32(anchor.y.rounded()),
                        anchorW: UInt32(max(0, anchor.w.rounded())),
                        anchorH: UInt32(max(0, anchor.h.rounded()))
                    )
                }
                return try await compositor.createSurface(
                    arenaId: arenaName, width: w, height: h,
                    title: title, frame: Self.frame, appId: Self.appId
                )
            }
        } catch {
            editor.closeWindow(window)
            FileHandle.standardError.write(
                Data("openWindow: CreateSurface failed: \(error)\n".utf8)
            )
            return nil
        }
        guard surface != 0 else {
            editor.closeWindow(window)
            FileHandle.standardError.write(
                Data("openWindow: CreateSurface returned no surface\n".utf8)
            )
            return nil
        }
        extra.surface = surface
        // Whenever the caller asked — a popup or a menu fly-out. The wash on
        // top has to be translucent or the plate is painted and then covered.
        // The corner is not a parameter: the compositor cuts the plate to
        // the same radius as the window mask, or the two disagree. A hidden
        // fly-out is not captured until `ShowSubmenu` places it.
        if backdropBlur > 0 {
            do {
                try blockingCall {
                    // Before the blur, so the first plate is already bent.
                    if refraction > 0 {
                        try await compositor.setBackdropRefraction(
                            surfaceId: surface, px: refraction
                        )
                    }
                    try await compositor.setBackdropBlur(
                        surfaceId: surface, radius: backdropBlur
                    )
                }
            } catch {
                FileHandle.standardError.write(
                    Data("openWindow: backdrop blur failed: \(error)\n".utf8)
                )
            }
        }

        let input: InputChannel
        do {
            input = InputChannel(
                stream: try compositor.subscribeInput(surfaceId: surface)
            )
        } catch {
            destroyCompositorSurface(surface)
            editor.closeWindow(window)
            FileHandle.standardError.write(
                Data("openWindow: SubscribeInput failed: \(error)\n".utf8)
            )
            return nil
        }
        extra.input = input
        editor.publishFrames(to: sink, window: window)
        extraSurfaces[window.rawValue] = extra
        editorForExtras = editor
        watchInput(input, window: window, editor: editor)

        Thread.detachNewThread {
            while !input.isClosed { Thread.sleep(forTimeInterval: 0.05) }
            MainQueue.async {
                // We closed it on the way out: the entry is already gone,
                // and asking the loop to close the window again would reap
                // a tree that has already been torn down.
                guard Self.extraSurfaces[window.rawValue] != nil else { return }
                LavaApp.closeWindow(window)
            }
        }

        FileHandle.standardError.write(
            Data("client surface \(surface) for window \(window.rawValue)\n".utf8)
        )
        return window
    }

    /// Drops the compositor half of a window `openWindow` added.
    ///
    /// Idempotent. The engine window is closed by `LavaApp`, which is also
    /// who calls this — doing both here would close it twice.
    private static func closeExtraSurface(editor: Editor, window: WindowID) {
        guard let extra = extraSurfaces.removeValue(forKey: window.rawValue)
        else { return }
        editor.stopPublishingFrames(window: window)
        destroyCompositorSurface(extra.surface)
        extra.input?.close()
        extra.surface = 0
    }

    private static func destroyCompositorSurface(_ id: UInt32) {
        guard id != 0, let compositor = Self.compositor else { return }
        do {
            try blockingCall {
                try await compositor.destroySurface(surfaceId: id)
            }
        } catch {
            // Already gone is the ordinary race: the stream ending destroys
            // the surface, and so does the client that noticed.
        }
    }

    /// One extra surface. A class because `Present` reads the id from the
    /// publish callback, which is created before `CreateSurface` returns.
    private final class ExtraSurface: @unchecked Sendable {
        let window: WindowID
        var surface: UInt32 = 0
        var input: InputChannel?
        init(window: WindowID) { self.window = window }
    }

    nonisolated(unsafe) private static var extraSurfaces: [UInt32: ExtraSurface] = [:]
    /// The editor `openExtraSurface` published into. `quit` drops every
    /// extra arena even when the frame loop did not reap the windows.
    nonisolated(unsafe) private static var editorForExtras: Editor?

    /// Set once, before the first publish can read it. See `run`.
    nonisolated(unsafe) private static var surfaceID: UInt32 = 0
    /// A minimum size stated before the surface existed. See `setMinimumSize`.
    nonisolated(unsafe) private static var pendingMinSize: (width: Float, height: Float)?
    /// Backdrop frost asked for before the surface existed. See `setBackdropBlur`.
    nonisolated(unsafe) private static var pendingBackdropBlur: Float?
    /// The same, for `setBackdropRefraction`.
    nonisolated(unsafe) private static var pendingBackdropRefraction: Float?
    /// Popup frost last sent / last asked, so emit can call every frame.
    nonisolated(unsafe) private static var pendingOverlayFrost: OverlayFrost?
    nonisolated(unsafe) private static var lastOverlayFrost: [UInt32: OverlayFrost] = [:]
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
    /// Non-nil opens the window as a dialog of that surface (0: of none) —
    /// no remembered frame, centred over its parent. See
    /// `CreateDialogSurface`.
    nonisolated(unsafe) private static var dialogParent: UInt32?
    /// Set by `openPanel`; nil for an ordinary window.
    nonisolated(unsafe) private static var panel:
        (edge: PanelEdge, thickness: Float, reserve: Bool)?
    /// What this panel reserves, kept across a thickness change so a caller
    /// growing the panel for a menu does not have to restate it.
    nonisolated(unsafe) private static var panelReserved: Float = 0
    /// Set by `openMenuSurface`; nil for anything else. The size is the arena
    /// the menus are drawn into, not a menu's size.
    nonisolated(unsafe) private static var menuSurface: (width: Float, height: Float)?
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
