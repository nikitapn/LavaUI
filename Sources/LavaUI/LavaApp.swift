#if canImport(CxxCanvas)
import Foundation
import CanvasResources

/// Reusable window/input/invalidation/render loop, so a second LavaUI
/// executable is a `main.swift` of a dozen lines instead of a copy of
/// `HelloWorldApp`'s ~350.
///
/// Split into `open` + `run` because asset loading a specific app owns
/// (an app icon, a brand image) has to happen *once*, against an already-open
/// `Editor`, before the first `makeRoot()` — folding it into `run`'s hot path
/// would either re-load it every rebuild or force every caller to thread a
/// cache through their own view. Two calls keeps that ordering explicit:
///
/// ```swift
/// guard let editor = LavaApp.open(title: "My App") else { exit(1) }
/// let icon = ImageStore.loadAsset(
///     named: "icon.png", bundle: .module, into: editor)
/// LavaApp.run(editor: editor) { MyRootView(icon: icon) }
/// ```
public enum LavaApp {
    /// Opens the window and does one-time framework setup: default font
    /// bootstrap, clipboard bridge. Logs and returns `nil` if the window
    /// failed to open — the caller should `exit(1)`.
    ///
    /// - Parameter assetsRoot: Engine resource root (directory with
    ///   `shaders/`). Default is the SwiftPM `CanvasResources` bundle.
    ///   Fonts always load from LavaUI's own resource bundle.
    public static func open(
        title: String,
        assetsRoot: String? = nil,
        width: Float = 1280,
        height: Float = 800
    ) -> Editor? {
        let engineRoot = Self.resolveEngineAssetsRoot(assetsRoot)
        FileHandle.standardError.write(Data("engine assets: \(engineRoot)\n".utf8))
        FileHandle.standardError.write(Data("lava fonts: \(LavaResources.fontsDirectory)\n".utf8))

        guard let editor = Editor.open(
            assetsRoot: engineRoot,
            width: Int32(width),
            height: Int32(height),
            title: title
        ) else {
            FileHandle.standardError.write(Data("failed to open editor window\n".utf8))
            return nil
        }

        // Framework fonts from LavaUI's SPM resources — not the engine tree.
        if FontStore.bootstrap(
            assetsRoot: LavaResources.root,
            pixelSize: 16,
            into: editor
        ) == nil {
            FileHandle.standardError.write(Data("warning: default UIFont failed to load\n".utf8))
        }
        if FontStore.symbols == nil {
            FileHandle.standardError.write(
                Data("warning: symbol font missing (Noto Sans Symbols 2)\n".utf8)
            )
        }

        ClipboardBridge.reader = { editor.clipboardText }
        ClipboardBridge.writer = { editor.clipboardText = $0 }

        return editor
    }

    /// Opens a client: the same framework, laying out and emitting frames for
    /// another process to draw, with no window and no GPU of its own.
    ///
    /// The counterpart to `open`, and `run` takes what it returns unchanged —
    /// a client app's `main.swift` differs from a windowed one's by this call
    /// and nothing else.
    ///
    /// Fonts still load and shape here, because shaping never needed the
    /// device; only rasterizing into the glyph atlas does, and that belongs
    /// to whoever draws. No engine assets are needed for the same reason: a
    /// client compiles no shaders.
    ///
    /// - Parameters `width`/`height`: the size to lay out at until something
    ///   tells it otherwise (`Editor.setClientSize`). A client has no surface
    ///   to measure, so this is a starting guess rather than a fact.
    public static func openClient(width: Float = 1280, height: Float = 800) -> Editor? {
        FileHandle.standardError.write(Data("lava fonts: \(LavaResources.fontsDirectory)\n".utf8))

        guard let editor = Editor.openClient(width: width, height: height) else {
            FileHandle.standardError.write(Data("failed to open client engine\n".utf8))
            return nil
        }

        if FontStore.bootstrap(
            assetsRoot: LavaResources.root,
            pixelSize: 16,
            into: editor
        ) == nil {
            FileHandle.standardError.write(Data("warning: default UIFont failed to load\n".utf8))
        }
        if FontStore.symbols == nil {
            FileHandle.standardError.write(
                Data("warning: symbol font missing (Noto Sans Symbols 2)\n".utf8)
            )
        }

        // Left unset rather than wired to an engine that has no window: the
        // clipboard is the display server's, and a client reaches it through
        // whoever owns the surface. `LavaClient.run` installs the pair that
        // asks the compositor once it has a surface to ask about; until then
        // reads return "" and writes are dropped, which is what
        // `ClipboardBridge` already does with no reader.
        return editor
    }

    /// Engine assets root: `override`, else `CANVAS_ASSETS_ROOT`, else the
    /// `CanvasResources` SwiftPM bundle (checked-in SPIR-V under `shaders/`).
    public static func resolveEngineAssetsRoot(_ override: String? = nil) -> String {
        if let override { return override }
        return CanvasResources.engineRoot
    }

    /// Back-compat alias — engine root only. App images should use
    /// `ImageStore.loadAsset(named:bundle:into:)` with the **app** bundle.
    public static func resolveAssetsRoot(_ override: String? = nil) -> String {
        resolveEngineAssetsRoot(override)
    }

    /// Runs the full input/invalidation/render/agent-server loop until the
    /// window closes.
    ///
    /// Drives **every** open window, not just this one: `openWindow` adds a
    /// second tree to the same loop, and one GLFW wait serves all of them, so
    /// N windows cost N draw arenas rather than N event loops. The app ends
    /// when the window opened here closes; secondary windows come and go under
    /// it. See `LavaWindow` for the per-window half and `WindowScope` for what
    /// each window owns privately.
    ///
    /// - `makeRoot`: rebuilds the view tree from scratch. Called on the first
    ///   frame and on any invalidation that can't be satisfied per-node (see
    ///   `ViewInvalidation.consumeDirtyBodyNodes`) — keep it cheap, an app's
    ///   own one-time setup belongs before this call, against the `Editor`
    ///   `open` already returned.
    /// - `menu`: optional application menubar. When a global-menu registrar is
    ///   available (Vala Panel / Plasma appmenu / …), the tree is exported via
    ///   DBusMenu and no in-window strip is drawn. Otherwise `MenuChromeRoot`
    ///   draws it with Vulkan. Override with `LAVA_MENU=vulkan` or `dbus`.
    ///   Rebuilt on every full body pass so labels/`isEnabled` stay in sync.
    ///   Menu shortcuts are matched after `onRawKey` (both backends).
    /// - `onRawKey`: first look at every key event, ahead of focus/overlay/
    ///   content-scale handling. Return `true` to consume it.
    public static func run<V: View>(
        editor: Editor,
        menu: (() -> MenuBar)? = nil,
        onRawKey: ((InputEvent) -> Bool)? = nil,
        makeRoot: @escaping () -> V
    ) {
        // Lets a worker thread unblock `pumpEvents` the moment it has a result,
        // the same way the agent socket does.
        MainQueue.install(wake: { [editor] in editor.wakeEventLoop() })

        Self.editor = editor
        Self.appRawKey = onRawKey
        WindowScope.register(.main)
        let main = LavaWindow(
            editor: editor, id: .main, scope: .main,
            menu: menu, onRawKey: onRawKey, makeRoot: makeRoot
        )
        windows = [main]
        main.bringUp()

        let agentServer = makeAgentServer(editor: editor, main: main)

        while editor.isOpen, !windows.isEmpty {
            // Agent wake posts an empty GLFW event, so we can still block
            // forever when idle (zero CPU) and still answer TCP immediately.
            //
            // Exception: DBusMenu. The panel issues synchronous D-Bus calls
            // (GetLayout / AboutToShow) on the session bus; those only complete
            // when we iterate GLib. Blocking forever in glfwWaitEvents with no
            // other wake source freezes the whole panel/session. Cap the wait
            // and pump GLib on both sides of the wait.
            var wake = FrameScheduler.timeoutUntilNextWake()
            if main.menuHost?.needsDBusPump == true {
                let cap = MenuHost.dbusPumpInterval
                if wake < 0 || wake > cap { wake = cap }
            }
            // Clear any D-Bus work already queued before parking in GLFW.
            main.menuHost?.poll()
            editor.pumpEvents(timeout: wake)

            // After wake (input, animation, agent, or D-Bus pump interval),
            // service the agent before the rest of the frame so injects land
            // this tick.
            agentServer?.poll()

            // Before input and before invalidation is consumed: a worker
            // result delivered while the loop was parked belongs to the frame
            // about to be built, not the one after it. No window is current
            // here, so a coarse invalidation from a worker reaches all of them
            // — see `WindowScope`.
            MainQueue.drain()

            // Global-menu: process GetLayout / activations that arrived during
            // the wait (and any more that show up while dispatching).
            main.menuHost?.poll()

            // Input and sizing for every window first, so the animation tick
            // below sees this iteration's visibility rather than last one's.
            // Once per iteration for the whole process, before any window
            // emits. This is a no-op on the many wakes that draw nothing —
            // input, D-Bus pumps, agent traffic — because ids age on emit
            // passes, not on iterations. See `SceneNodeIdentity`.
            SceneNodeIdentity.advanceFrame()
            for window in windows { window.update() }

            // Once for the process, not once per window: the registry is
            // shared and each entry knows which window it redraws.
            AnimationDriver.tick()

            for window in windows { window.syncCaret() }
            for window in windows { window.present() }

            reapClosedWindows()
            // After present, so anything queued from an input handler this
            // iteration got its "before" frame on screen first.
            FrameTasks.drain()
            // A handler may have asked for a window; bring it up before the
            // loop parks again, or it would stay blank until the next event.
            bringUpPendingWindows()
        }

        for window in windows { window.teardown() }
        windows.removeAll()
        Self.editor = nil
        Self.appRawKey = nil
        agentServer?.close()
    }

    // ─── Windows ─────────────────────────────────────────────────────────

    /// Open windows, in the order they were opened. `windows[0]` is the one
    /// the app started with; closing it ends `run`.
    nonisolated(unsafe) private static var windows: [LavaWindow] = []
    /// Opened during a frame, brought up once that frame is on screen.
    nonisolated(unsafe) private static var pendingWindows: [LavaWindow] = []
    nonisolated(unsafe) private static var editor: Editor?
    nonisolated(unsafe) private static var appRawKey: ((InputEvent) -> Bool)?

    public static var windowCount: Int { windows.count + pendingWindows.count }

    /// Opens a second window running its own view tree, sharing this process's
    /// GPU, font atlas, texture cache and frame loop.
    ///
    /// Safe to call from a button handler: the window is created immediately
    /// but brought up at the end of the current frame, so it never draws
    /// against a half-updated tree, and the caller's own window still presents
    /// the frame the click belongs to.
    ///
    /// The new window gets its own focus, invalidation and hover state (see
    /// `WindowScope`) and the app-level `onRawKey` from `run`. It does **not**
    /// get the menubar: a second menubar strip is a decision for the app, not
    /// a default, and the DBus global menu is registered per process.
    ///
    /// Returns `nil` if the engine could not open it, or if called before
    /// `run`.
    @discardableResult
    public static func openWindow<V: View>(
        title: String,
        width: Float = 800,
        height: Float = 600,
        onClose: (() -> Void)? = nil,
        makeRoot: @escaping () -> V
    ) -> WindowID? {
        guard let editor else {
            FileHandle.standardError.write(
                Data("openWindow: no running LavaApp\n".utf8)
            )
            return nil
        }
        guard let id = editor.openWindow(width: width, height: height, title: title)
        else {
            FileHandle.standardError.write(
                Data("openWindow: engine refused \"\(title)\"\n".utf8)
            )
            return nil
        }
        let scope = WindowScope(label: title, windowID: id)
        WindowScope.register(scope)
        let window = LavaWindow(
            editor: editor, id: id, scope: scope,
            menu: nil, onRawKey: appRawKey, makeRoot: makeRoot
        )
        window.onClose = onClose
        pendingWindows.append(window)
        // The loop may be parked in `pumpEvents`; without this the new window
        // would stay hidden until unrelated input arrived.
        FrameScheduler.requestWake(in: 0)
        return id
    }

    /// Closes a window this app opened. Closing the window the app started
    /// with ends `run`, the same as its titlebar X.
    ///
    /// Takes effect at the end of the current frame, so it is safe from a
    /// handler running inside that window's own tree.
    public static func closeWindow(_ id: WindowID) {
        if let window = windows.first(where: { $0.id == id }) {
            window.requestClose()
            FrameScheduler.requestWake(in: 0)
        }
        pendingWindows.removeAll { $0.id == id }
    }

    /// Whether `id` is still open.
    public static func isWindowOpen(_ id: WindowID) -> Bool {
        windows.contains { $0.id == id } || pendingWindows.contains { $0.id == id }
    }

    /// The window whose frame is being built or whose handler is running.
    ///
    /// Ambient rather than passed down, for the reason `WindowScope` gives at
    /// length: a view genuinely does not know which window it is in, and every
    /// view in a tree would have to thread the answer through to the one place
    /// that wants it. Outside a frame this is the first window.
    public static var currentWindow: WindowID { WindowScope.currentOrMain.windowID }

    /// Closes the window this handler is running in. What a "Close" button in
    /// a secondary window wants, without the window having to know its own id.
    public static func closeCurrentWindow() { closeWindow(currentWindow) }

    private static func bringUpPendingWindows() {
        guard !pendingWindows.isEmpty else { return }
        let opening = pendingWindows
        pendingWindows.removeAll()
        for window in opening {
            window.bringUp()
            windows.append(window)
        }
    }

    /// Removes windows that have been asked to close.
    ///
    /// The first window is special only in what closing it *means*: the loop's
    /// `windows.isEmpty` check ends the app, so dropping it here is what turns
    /// its titlebar X into a quit. Secondary windows come and go under a
    /// running app.
    private static func reapClosedWindows() {
        guard windows.contains(where: { $0.shouldClose }) else { return }
        if windows[0].shouldClose {
            // Quitting: tear every window down, not just the one clicked —
            // including any a handler asked for this same frame, which would
            // otherwise be brought up into an app that is already leaving.
            for window in pendingWindows { editor?.closeWindow(window.id) }
            pendingWindows.removeAll()
            for window in windows { window.teardown() }
            for window in windows where window.id != .main {
                editor?.closeWindow(window.id)
            }
            windows.removeAll()
            return
        }
        var survivors: [LavaWindow] = []
        for window in windows {
            guard window.shouldClose else {
                survivors.append(window)
                continue
            }
            window.teardown()
            editor?.closeWindow(window.id)
        }
        windows = survivors
    }

    // ─── Agent control plane ─────────────────────────────────────────────

    /// Optional automation server (`LAVA_AGENT_PORT=9876`).
    ///
    /// Addresses the first window only. Its verbs are single-target by
    /// construction — one layout tree, one hit test, one screenshot — and the
    /// engine's inject entry points still default to the first window, so
    /// pointing it at a second one is a protocol change rather than a
    /// plumbing change. `settle` is the exception and does drive every window,
    /// because a screenshot taken while another window is mid-frame is a
    /// screenshot of a stale screen.
    private static func makeAgentServer(
        editor: Editor, main: LavaWindow
    ) -> AgentServer? {
        let host = main.host
        let menuH: Float = 0
        let settleFrame = { for window in windows { window.settle() } }

        let agentPort: UInt16 = {
            guard let s = ProcessInfo.processInfo.environment["LAVA_AGENT_PORT"],
                  let p = UInt16(s), p > 0 else { return 0 }
            return p
        }()
        guard agentPort > 0 else { return nil }
        return {
            let agentHost = AgentHost(
                framebufferSize: { editor.framebufferSize() },
                settle: { settleFrame() },
                layoutTreeJSON: { depth in
                    host.agentLayoutTreeJSON(originY: menuH, maxDepth: depth)
                },
                hitLabel: { x, y in host.agentHitLabel(x: x, y: y, originY: menuH) },
                resolveFrame: { sid, label, id, query in
                    if let sid, !sid.isEmpty, let f = host.agentFrame(sid: sid, originY: menuH) {
                        return (f.label, sid, f.x, f.y, f.w, f.h)
                    }
                    if let id, let f = host.agentFrame(id: id, originY: menuH) {
                        return (f.label, "id:\(id)", f.x, f.y, f.w, f.h)
                    }
                    if let label, let f = host.agentFrame(label: label, originY: menuH) {
                        return (f.label, label, f.x, f.y, f.w, f.h)
                    }
                    if let query, !query.isEmpty {
                        let hits = host.agentFind(query: query, originY: menuH, limit: 1)
                        if let h0 = hits.first {
                            let x = (h0["x"] as? NSNumber)?.floatValue ?? (h0["x"] as? Float)
                            let y = (h0["y"] as? NSNumber)?.floatValue ?? (h0["y"] as? Float)
                            let w = (h0["w"] as? NSNumber)?.floatValue ?? (h0["w"] as? Float)
                            let h = (h0["h"] as? NSNumber)?.floatValue ?? (h0["h"] as? Float)
                            if let x, let y, let w, let h {
                                let lab = (h0["label"] as? String) ?? query
                                let s = (h0["sid"] as? String) ?? lab
                                return (lab, s, x, y, w, h)
                            }
                        }
                    }
                    return nil
                },
                find: { query, limit in
                    host.agentFind(query: query, originY: menuH, limit: limit)
                },
                // Every entry point that carries a position tells the window
                // where the pointer now is, because nothing else will: an
                // injected move reaches no renderer, and a client has none of
                // its own. See `LavaWindow.noteInjectedPointer`.
                injectMove: { x, y in
                    editor.injectPointerMove(x: x, y: y)
                    main.noteInjectedPointer(x: x, y: y)
                },
                injectClick: { x, y, button in
                    editor.injectPointerMove(x: x, y: y)
                    main.noteInjectedPointer(x: x, y: y)
                    editor.injectPointerButton(button: button, pressed: true, x: x, y: y)
                    editor.injectPointerButton(button: button, pressed: false, x: x, y: y)
                },
                injectPointerButton: { x, y, button, pressed in
                    // A press with no move before it still has to say where it
                    // is: `pointer_down` at one place and `pointer_up` at
                    // another is how a drag is spelled.
                    main.noteInjectedPointer(x: x, y: y)
                    editor.injectPointerButton(
                        button: button, pressed: pressed, x: x, y: y
                    )
                },
                injectScroll: { dx, dy in editor.injectScroll(dx: dx, dy: dy) },
                injectKey: { key, action, mods in
                    editor.injectKey(key: key, action: action, mods: mods)
                },
                injectText: { text in editor.injectText(text) },
                screenshotBase64: { x, y, w, h, maxSide in
                    ScreenshotBridge.capture(
                        x: x, y: y, w: w, h: h, maxSide: maxSide, editor: editor
                    )
                }
            )
            // Unblock pumpEvents the moment the agent socket is readable
            // (watcher thread → glfwPostEmptyEvent). Do not use min(wake, 0.05)
            // when wake is -1 ("block forever") — min(-1, 0.05) stays -1.
            return AgentServer(
                host: agentHost,
                port: agentPort,
                wakeMainLoop: { [editor] in editor.wakeEventLoop() }
            )
        }()
    }
}

#endif
