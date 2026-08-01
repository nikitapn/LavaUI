#if canImport(CxxCanvas)
import Foundation

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
/// let icon = ImageStore.loadAsset(named: "icon.png", assetsRoot: ..., into: editor)
/// LavaApp.run(editor: editor) { MyRootView(icon: icon) }
/// ```
public enum LavaApp {
    /// Opens the window and does one-time framework setup: default font
    /// bootstrap, clipboard bridge. Logs and returns `nil` if the window
    /// failed to open — the caller should `exit(1)`.
    public static func open(
        title: String,
        assetsRoot: String? = nil,
        width: Float = 1280,
        height: Float = 800
    ) -> Editor? {
        let assets = Self.resolveAssetsRoot(assetsRoot)
        FileHandle.standardError.write(Data("assets: \(assets)\n".utf8))

        guard let editor = Editor.open(
            assetsRoot: assets,
            width: Int32(width),
            height: Int32(height),
            title: title
        ) else {
            FileHandle.standardError.write(Data("failed to open editor window\n".utf8))
            return nil
        }

        if FontStore.bootstrap(assetsRoot: assets, pixelSize: 16, into: editor) == nil {
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

    /// `override` if given, else `CANVAS_ASSETS_ROOT` if set, else
    /// `canvas/.build.Debug` relative to this file — which only resolves
    /// correctly because every executable target lives one level under
    /// `Sources/`, the same depth as this file. Pass `override` (or
    /// `assetsRoot` to `open`) if that stops being true for some target.
    ///
    /// Public so a caller's own one-time asset loading — between `open` and
    /// `run` — can resolve the same root `open` used, without duplicating
    /// this logic or re-deriving it from `#filePath` in its own module.
    public static func resolveAssetsRoot(_ override: String? = nil) -> String {
        if let override { return override }
        if let env = ProcessInfo.processInfo.environment["CANVAS_ASSETS_ROOT"], !env.isEmpty {
            return env
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("canvas/.build.Debug")
            .path
    }

    /// Runs the full input/invalidation/render/agent-server loop until the
    /// window closes.
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
        var windowW: Float = 1280
        var windowH: Float = 800
        // In-window strip is composed inside the view tree when used; DBus
        // global menu needs no client offset either. menuH stays 0.
        let menuH: Float = 0
        let fb0 = editor.framebufferSize()
        if fb0.w >= 1, fb0.h >= 1 {
            windowW = fb0.w
            windowH = fb0.h
        }

        let host = LayoutHost()
        let drawList = DrawList(editor: editor)
        let menuHost: MenuHost? = menu != nil ? MenuHost(editor: editor) : nil

        // Lets a worker thread unblock `pumpEvents` the moment it has a result,
        // the same way the agent socket does.
        MainQueue.install(wake: { [editor] in editor.wakeEventLoop() })

        var dirty = true
        // The wheel event carries no position, so remember the last one.
        var lastPointer: (x: Float, y: Float) = (0, 0)
        var lastLoggedLayout: (w: Float, h: Float) = (0, 0)
        // Previous iteration's window visibility, so the loop can tell a
        // minimize/restore edge from a steady state and redraw exactly once.
        var wasWindowVisible = editor.isWindowVisible
        // Last seen font-metrics generation. Anything that changes the UI
        // scale — the zoom chord, a menu item, an agent script — bumps
        // `FontStore.metricsGeneration`, and this is the one place that turns
        // that into the Yoga re-measure it needs. Centralised because the
        // `LayoutHost` is reachable only from here.
        var lastMetricsGeneration = FontStore.metricsGeneration

        /// Re-measures text if the active face changed size since last check.
        func syncTextMetrics() {
            guard FontStore.metricsGeneration != lastMetricsGeneration else { return }
            lastMetricsGeneration = FontStore.metricsGeneration
            host.invalidateTextMetrics()
            dirty = true
            let s = FontStore.scale
            FileHandle.standardError.write(Data(String(
                format: "ui scale → %.2fx (%dpx)\n", s.multiplier, Int(s.pixelSize)
            ).utf8))
        }

        // Per-frame timing, one line per rendered frame on stdout. Idle frames
        // print nothing, because idle frames are not rendered.
        //
        // Kept because the cost that mattered was invisible: a slider drag
        // spent 4.3ms in Yoga per pointer move and only *looked* like the knob
        // lagging. No test catches that — the output was correct, just late.
        // `layout` on a drag or an animation tick is the tell.
        //
        // Set LAVAUI_DEBUG=0 to silence without rebuilding.
        let enableDebug = ProcessInfo.processInfo.environment["LAVAUI_DEBUG"] != "0"
        var probeBody = 0.0
        var probeLayout = 0.0
        var probeEmit = 0.0

        /// Does only as much of the pipeline as `level` requires. A pure
        /// redraw — an animation tick, a caret blink — skips body recompute
        /// and layout entirely, which is what keeps animation cheap.
        func renderFrame(_ level: InvalidationLevel) {
            let fb = editor.framebufferSize()
            if fb.w >= 1, fb.h >= 1 {
                windowW = fb.w
                windowH = fb.h
            }
            let bodyW = windowW
            let bodyH = max(1, windowH - menuH)
            let t0 = enableDebug ? FrameScheduler.now() : 0
            if level >= .body {
                // Per-node invalidation: a change tracked to specific
                // composite nodes recomputes just those, instead of every
                // node in the tree via a fresh root value. `nil` means
                // something raised `.body` without naming a node (first
                // frame, or state outside the observation system), which
                // still needs the full rebuild.
                //
                // With a menubar, always rebuild the root: `menu` is a
                // free closure (not a mounted node), so per-node recompute
                // would leave the strip's `MenuModel` stale.
                if menuHost != nil {
                    installRoot()
                } else if let dirty = ViewInvalidation.consumeDirtyBodyNodes() {
                    for node in dirty { node.recomputeBody() }
                } else {
                    host.setRoot(makeRoot())
                }
            }
            let t1 = enableDebug ? FrameScheduler.now() : 0
            let frames = level >= .layout
                ? host.calculateLayout(width: bodyW, height: bodyH)
                : host.lastLayoutFrames
            let t2 = enableDebug ? FrameScheduler.now() : 0
            if enableDebug {
                probeBody = (t1 - t0) * 1000
                probeLayout = (t2 - t1) * 1000
                // Overwritten below unless the guard on `rootNode` returns
                // first, in which case there was no emit to time.
                probeEmit = 0
            }

            if abs(bodyW - lastLoggedLayout.w) > 0.5 || abs(bodyH - lastLoggedLayout.h) > 0.5 {
                lastLoggedLayout = (bodyW, bodyH)
                let hostFrame = frames.first(where: { $0.label == "DiagramHost" })
                let msg: String
                if let dh = hostFrame {
                    msg =
                        "layout: \(Int(bodyW))×\(Int(bodyH)) DiagramHost "
                        + "\(Int(dh.w))×\(Int(dh.h))\n"
                } else {
                    msg = "layout: \(Int(bodyW))×\(Int(bodyH))\n"
                }
                FileHandle.standardError.write(Data(msg.utf8))
            }

            guard let root = host.rootNode else { return }

            drawList.clear()
            drawList.rect(
                x: 0, y: 0, w: windowW, h: windowH,
                color: Theme.current.background
            )
            drawList.emitTree(
                root,
                originX: 0,
                originY: menuH,
                viewportW: windowW,
                viewportH: windowH
            )
            // This frame's NodeVisibility is now current; give any node that
            // just scrolled/resized/expanded into view a queued wake so it
            // resumes on its own next iteration (see doc comment).
            AnimationDriver.requestRevisibilityCheck()

            editor.submitDrawList(drawList)
            if enableDebug { probeEmit = (FrameScheduler.now() - t2) * 1000 }
            dirty = false
        }

        /// Mount / remount the retained tree. Updates the menubar IR first when
        /// a `menu` builder was provided.
        func installRoot() {
            if let menu, let menuHost {
                menuHost.update(menu())
                let hostRef = menuHost
                if hostRef.showsInWindowChrome {
                    host.setRoot(
                        MenuChromeRoot(
                            model: hostRef.model,
                            onActivate: { hostRef.activate($0) },
                            content: makeRoot()
                        )
                    )
                } else {
                    // DBus global menu (or empty model): app content only.
                    host.setRoot(makeRoot())
                }
            } else {
                host.setRoot(makeRoot())
            }
        }

        // Lightweight structure dump (no FBD chrome phases).
        if let menu {
            menuHost?.update(menu())
        }
        let demo0: any View = {
            if let menuHost, menuHost.showsInWindowChrome {
                return MenuChromeRoot(
                    model: menuHost.model,
                    onActivate: { _ in },
                    content: makeRoot()
                )
            }
            return makeRoot()
        }()
        let rootLabel: String = {
            if menuHost?.showsInWindowChrome == true {
                return "MenuChromeRoot<\(V.self)>"
            }
            if menuHost?.backend == .dbusMenu {
                return "\(V.self)+AppMenu"
            }
            return String(describing: V.self)
        }()
        FileHandle.standardError.write(Data("--- \(rootLabel) structure ---\n".utf8))
        for line in demo0.structureLines() {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        FileHandle.standardError.write(Data("--- end structure ---\n".utf8))

        renderFrame(.body)
        // Keep `pending` in sync with the dirty-node state `renderFrame` just
        // drained via `consumeDirtyBodyNodes()` — this call bypasses the
        // normal `consume()`-driven loop below, so without this the level
        // scalar would sit stale at its initial default and the loop's first
        // real `consume()` would see `.body` with nothing left to act on.
        _ = ViewInvalidation.consume()
        editor.renderFrame()

        func processInputEvent(_ ev: InputEvent) {
            switch ev.kind {
            case .mouseDown:
                if let action = host.hitTestClick(
                    x: ev.x, y: ev.y,
                    originX: 0, originY: menuH, mods: ev.mods
                ) {
                    action()
                    // A handler exists to change something, so a click is a
                    // repaint request. `@State` writes invalidate themselves
                    // through `Binding.set`, but a handler that mutates an
                    // `@Observable` model reaches the screen only if some body
                    // *read* that property — and a live-read presenter like
                    // `overlay(isPresented:)` never does. Without this, opening
                    // a panel from a click showed nothing until an unrelated
                    // event (a hover) happened to repaint.
                    //
                    // `.redraw` is the right floor, the same reasoning
                    // `Binding.set` documents: anything that genuinely changed
                    // the tree has already raised `.body` via observation.
                    ViewInvalidation.markNeedsRedraw()
                }
            case .resize:
                let nw = max(1, ev.x)
                let nh = max(1, ev.y)
                if nw != windowW || nh != windowH {
                    windowW = nw
                    windowH = nh
                    ViewInvalidation.markNeedsLayout()
                    FileHandle.standardError.write(
                        Data("layout resize → \(Int(nw))×\(Int(nh))\n".utf8)
                    )
                }
            case .refresh:
                let fb = editor.framebufferSize()
                if fb.w >= 1, fb.h >= 1, fb.w != windowW || fb.h != windowH {
                    windowW = fb.w
                    windowH = fb.h
                    ViewInvalidation.markNeedsLayout()
                } else {
                    ViewInvalidation.markNeedsRedraw()
                }
            case .mouseMove:
                lastPointer = (ev.x, ev.y)
                PointerState.set(x: ev.x, y: ev.y)
                if PointerCapture.isActive {
                    PointerCapture.move(x: ev.x, y: ev.y - menuH)
                } else {
                    HoverState.set(
                        host.hitTestHover(x: ev.x, y: ev.y, originY: menuH)
                    )
                }
            case .mouseUp:
                PointerCapture.release()
            case .scroll:
                // Chain, not the single hover target: the wheel bubbles past a
                // button or field that happens to be topmost to the nearest
                // scroll-capable ancestor.
                ScrollRouter.deliver(
                    to: host.hitTestScrollChain(
                        x: lastPointer.x, y: lastPointer.y, originY: menuH
                    ),
                    dx: ev.x, dy: ev.y, mods: ev.button
                )
            case .fileDrop:
                DropRouter.deliver(
                    to: host.hitTestHover(x: ev.x, y: ev.y, originY: menuH),
                    paths: editor.droppedFiles()
                )
            case .text:
                if let scalar = Unicode.Scalar(UInt32(bitPattern: ev.button)) {
                    _ = FocusManager.handle(character: Character(scalar))
                }
            case .key:
                if onRawKey?(ev) == true { break }
                let isPress = ev.x > 0
                if isPress, ev.button == KeyCode.escape, host.dismissOverlays() {
                    break
                }
                if isPress,
                   let menuHost,
                   menuHost.activate(matchingKey: ev.button, mods: Int32(ev.y))
                {
                    break
                }
                if isPress,
                   FocusManager.handle(
                       KeyEvent(key: ev.button, mods: Int32(ev.y), isRepeat: ev.x > 1)
                   )
                {
                    break
                }
                // Metrics invalidation is handled centrally off
                // `FontStore.metricsGeneration`, so this no longer has to —
                // and neither does any other caller that changes the scale.
                ContentScaleShortcuts.handle(ev, editor: editor)
            default:
                break
            }
        }

        /// Drain input queue, run invalidation pipeline, present.
        func settleFrame() {
            MainQueue.drain()
            syncTextMetrics()
            menuHost?.poll()
            while let ev = editor.pollInputEvent() {
                processInputEvent(ev)
            }
            let fb = editor.framebufferSize()
            if fb.w >= 1, fb.h >= 1, fb.w != windowW || fb.h != windowH {
                windowW = fb.w
                windowH = fb.h
                ViewInvalidation.markNeedsLayout()
            }
            // Minimized/occluded: Yoga's cull rect has no idea the whole
            // window is off-screen, so this is the one gate that has to live
            // outside `NodeVisibility` — skipping the tick here is what stops
            // a playing continuous-redraw canvas from still asking for 60fps
            // while nobody can see the window at all.
            if editor.isWindowVisible {
                AnimationDriver.tick()
            }
            let level = ViewInvalidation.consume()
            if dirty { ViewInvalidation.markNeedsBody() }
            let work = dirty ? InvalidationLevel.body : max(level, .redraw)
            dirty = false
            renderFrame(work)
            editor.renderFrame()
            FrameTasks.drain()
        }

        // Agent control plane (optional). LAVA_AGENT_PORT=9876
        let agentPort: UInt16 = {
            guard let s = ProcessInfo.processInfo.environment["LAVA_AGENT_PORT"],
                  let p = UInt16(s), p > 0 else { return 0 }
            return p
        }()
        let agentServer: AgentServer? = {
            guard agentPort > 0 else { return nil }
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
                injectMove: { x, y in editor.injectPointerMove(x: x, y: y) },
                injectClick: { x, y, button in
                    editor.injectPointerMove(x: x, y: y)
                    editor.injectPointerButton(button: button, pressed: true, x: x, y: y)
                    editor.injectPointerButton(button: button, pressed: false, x: x, y: y)
                },
                injectPointerButton: { x, y, button, pressed in
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
                    editor.capturePngBase64(x: x, y: y, w: w, h: h, maxSide: maxSide)
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

        while editor.isOpen {
            // Agent wake posts an empty GLFW event, so we can still block
            // forever when idle (zero CPU) and still answer TCP immediately.
            //
            // Exception: DBusMenu. The panel issues synchronous D-Bus calls
            // (GetLayout / AboutToShow) on the session bus; those only complete
            // when we iterate GLib. Blocking forever in glfwWaitEvents with no
            // other wake source freezes the whole panel/session. Cap the wait
            // and pump GLib on both sides of the wait.
            var wake = FrameScheduler.timeoutUntilNextWake()
            if menuHost?.needsDBusPump == true {
                let cap = MenuHost.dbusPumpInterval
                if wake < 0 || wake > cap { wake = cap }
            }
            // Clear any D-Bus work already queued before parking in GLFW.
            menuHost?.poll()
            editor.pumpEvents(timeout: wake)

            // After wake (input, animation, agent, or D-Bus pump interval),
            // service the agent before the rest of the frame so injects land
            // this tick.
            agentServer?.poll()

            // Before input and before invalidation is consumed: a worker
            // result delivered while the loop was parked belongs to the frame
            // about to be built, not the one after it.
            MainQueue.drain()

            // Global-menu: process GetLayout / activations that arrived during
            // the wait (and any more that show up while dispatching).
            menuHost?.poll()

            while let ev = editor.pollInputEvent() {
                processInputEvent(ev)
            }

            // After input and after menu activations, so a scale change from
            // any of them re-measures before this frame lays out.
            syncTextMetrics()

            // Live size from GLFW (not only post-swapchain).
            let fb = editor.framebufferSize()
            if fb.w >= 1, fb.h >= 1, fb.w != windowW || fb.h != windowH {
                windowW = fb.w
                windowH = fb.h
                ViewInvalidation.markNeedsLayout()
            }

            let windowVisible = editor.isWindowVisible
            if windowVisible {
                AnimationDriver.tick()
            }

            // A blinking caret is the other thing that keeps an idle app awake
            // forever, and unlike an animation it does not need `NodeVisibility`
            // to know it is pointless: nobody can see a minimized window's
            // caret, so it must not schedule wakes or dirty frames there.
            if windowVisible, FocusManager.focusedID != nil {
                if CaretBlink.phaseChanged() { ViewInvalidation.markNeedsRedraw() }
                FrameScheduler.requestWake(in: CaretBlink.period / 4)
            }

            if windowVisible != wasWindowVisible {
                wasWindowVisible = windowVisible
                // On restore the caret has to come back without waiting for the
                // user to type or click: the suspended blink left `lastPhase`
                // stale, so adopt the live phase and paint one frame with it.
                if windowVisible {
                    CaretBlink.resync()
                    ViewInvalidation.markNeedsRedraw()
                }
            }

            let level = ViewInvalidation.consume()
            if dirty { ViewInvalidation.markNeedsBody() }
            let work = dirty ? InvalidationLevel.body : level
            dirty = false

            if work > .none {
                let p0 = enableDebug ? FrameScheduler.now() : 0
                renderFrame(work)
                let p1 = enableDebug ? FrameScheduler.now() : 0
                editor.renderFrame()
                if enableDebug {
                    let now = FrameScheduler.now()
                    let label = work.probeName
                        .padding(toLength: 6, withPad: " ", startingAt: 0)
                    let line = "frame \(label) " + String(
                        format:
                            "body=%5.2f layout=%5.2f emit=%5.2f "
                            + "present=%5.2f total=%5.2f ms\n",
                        probeBody, probeLayout, probeEmit,
                        (now - p1) * 1000, (now - p0) * 1000
                    )
                    FileHandle.standardOutput.write(Data(line.utf8))
                    if WidgetProfiler.isEnabled {
                        let top = WidgetProfiler.snapshot().prefix(5)
                            .map { String(format: "%@=%.2fms(%d)", $0.label, $0.ms, $0.count) }
                            .joined(separator: " ")
                        if !top.isEmpty {
                            FileHandle.standardOutput.write(Data("  top: \(top)\n".utf8))
                        }
                    }
                }
                // Only after a frame was actually emitted. Advancing the image
                // clock on an idle iteration would mean "nothing was drawn",
                // which makes every cached image look unused — including the
                // ones on screen — and evicts them straight into a reload.
                ImageStore.endFrame(into: editor)
            }

            // After present, so anything queued from an input handler this
            // iteration got its "before" frame on screen first.
            FrameTasks.drain()
        }

        agentServer?.close()
    }
}

extension InvalidationLevel {
    /// How much of body → layout → emit this frame ran, for the timing line.
    fileprivate var probeName: String {
        switch self {
        case .none: return "none"
        case .redraw: return "redraw"
        case .layout: return "layout"
        case .body: return "body"
        }
    }
}

#endif
