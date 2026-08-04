#if canImport(CxxCanvas)
import Foundation

/// One window's worth of the frame loop: its layout tree, its draw arena, its
/// slice of framework state, and the input → invalidate → body → layout → emit
/// → present pipeline that connects them.
///
/// This is the half of `LavaApp.run` that was per window all along and only
/// looked global because there was one of them. What stays in `LavaApp` is the
/// part that genuinely belongs to the process: the GLFW wait, the agent server,
/// `MainQueue`, `FrameTasks`, and deciding when the app is over.
///
/// Every public entry point runs its body with `scope` current, which is what
/// lets a widget keep calling `ViewInvalidation.markNeedsRedraw()` or
/// `FocusManager.focus(…)` with no window in scope and still land in the right
/// one. See `WindowScope`.
public final class LavaWindow {
    public let id: WindowID

    /// Framework state that used to be process-global.
    public let scope: WindowScope

    public let host = LayoutHost()

    let editor: Editor
    let drawList: DrawList
    let menuHost: MenuHost?

    /// Rebuilds and mounts the root view.
    ///
    /// Erased to a closure because `LayoutHost.setRoot` needs a concrete
    /// `V: View` and `any View` does not conform to `View` — so the generic
    /// parameter has to be captured where it is still known, in `init`, rather
    /// than stored. The same reason the debug structure dump is a closure.
    private var installRootImpl: () -> Void = {}
    private var structureLinesImpl: () -> [String] = { [] }

    /// Type name of the root view, for the debug dump header.
    private var rootLabel = ""

    private let makeMenu: (() -> MenuBar)?
    private let onRawKey: ((InputEvent) -> Bool)?

    /// Run after the window has been removed from the app's list. Lets the
    /// opener drop whatever it was keeping alive for this window.
    public var onClose: (() -> Void)?

    private(set) var width: Float = 1280
    private(set) var height: Float = 800

    /// In-window strip is composed inside the view tree when used; DBus global
    /// menu needs no client offset either. Kept as a named constant because
    /// every hit test and emit origin below refers to it.
    private let menuH: Float = 0

    /// Forces a full `.body` pass on the next frame regardless of what
    /// invalidation says — the first frame, and nothing else so far.
    private var dirty = true
    private var lastLoggedLayout: (w: Float, h: Float) = (0, 0)
    /// Previous iteration's visibility, so the loop can tell a minimize/restore
    /// edge from a steady state and redraw exactly once.
    private var wasWindowVisible = true
    /// Last seen font-metrics generation. Anything that changes the UI scale —
    /// the zoom chord, a menu item, an agent script — bumps
    /// `FontStore.metricsGeneration`, and this is the one place that turns that
    /// into the Yoga re-measure it needs, per window because each has its own
    /// `LayoutHost` to re-measure.
    private var lastMetricsGeneration = FontStore.metricsGeneration

    private let enableDebug = ProcessInfo.processInfo.environment["LAVAUI_DEBUG"] == "1"
    private var probeBody = 0.0
    private var probeLayout = 0.0
    private var probeEmit = 0.0

    // ─── Construction ────────────────────────────────────────────────────

    /// - Parameter scope: `.main` for the window the app opened with, so that
    ///   single-window apps, tests and `LavaBench` — none of which register a
    ///   scope — resolve to the same state the running window uses.
    init<V: View>(
        editor: Editor,
        id: WindowID,
        scope: WindowScope,
        menu: (() -> MenuBar)?,
        onRawKey: ((InputEvent) -> Bool)?,
        makeRoot: @escaping () -> V
    ) {
        self.editor = editor
        self.id = id
        self.scope = scope
        self.drawList = DrawList(editor: editor, window: id)
        self.menuHost = menu != nil ? MenuHost(editor: editor) : nil
        self.makeMenu = menu
        self.onRawKey = onRawKey

        let fb = editor.framebufferSize(window: id)
        if fb.w >= 1, fb.h >= 1 {
            width = fb.w
            height = fb.h
        }
        wasWindowVisible = editor.isVisible(window: id)

        rootLabel = String(describing: V.self)
        installRootImpl = { [unowned self] in
            if self.makeMenu != nil, let menuHost = self.menuHost,
               menuHost.showsInWindowChrome
            {
                self.host.setRoot(
                    MenuChromeRoot(
                        model: menuHost.model,
                        onActivate: { menuHost.activate($0) },
                        content: makeRoot()
                    )
                )
            } else {
                // No menu, or a DBus global menu (or an empty model): app
                // content only.
                self.host.setRoot(makeRoot())
            }
        }
        structureLinesImpl = { [unowned self] in
            if let menuHost = self.menuHost, menuHost.showsInWindowChrome {
                return MenuChromeRoot(
                    model: menuHost.model,
                    onActivate: { _ in },
                    content: makeRoot()
                ).structureLines()
            }
            return makeRoot().structureLines()
        }
    }

    // ─── Frame ───────────────────────────────────────────────────────────

    /// Builds and presents the first frame, then shows the window.
    ///
    /// Ordering matters and is not cosmetic: a window shown before it has
    /// drawn presents an undefined swapchain image, which reaches the screen
    /// as a flash of garbage.
    func bringUp() {
        WindowScope.withCurrent(scope) {
            refreshMenuModel()
            if enableDebug {
                let label = menuHost?.showsInWindowChrome == true
                    ? "MenuChromeRoot<\(rootLabel)>"
                    : (menuHost?.backend == .dbusMenu ? "\(rootLabel)+AppMenu" : rootLabel)
                FileHandle.standardError.write(Data("--- \(label) structure ---\n".utf8))
                for line in structureLinesImpl() {
                    FileHandle.standardError.write(Data((line + "\n").utf8))
                }
                FileHandle.standardError.write(Data("--- end structure ---\n".utf8))
            }
            renderFrame(.body)
            // Keep `pending` in sync with the dirty-node state `renderFrame`
            // just drained via `consumeDirtyBodyNodes()` — this path bypasses
            // the normal `consume()`-driven loop, so without this the level
            // would sit stale at its initial default and the first real
            // `consume()` would see `.body` with nothing left to act on.
            _ = ViewInvalidation.consume()
            editor.renderFrame(window: id)
        }
        editor.setVisible(true, window: id)
    }

    /// Drains input and refreshes everything the render decision depends on.
    /// Split from `present()` so the app can tick animation once, globally,
    /// after every window has reported its visibility and consumed its input.
    func update() {
        WindowScope.withCurrent(scope) {
            menuHost?.poll()

            while let ev = editor.pollInputEvent(window: id) {
                processInputEvent(ev)
            }

            // After input and after menu activations, so a scale change from
            // any of them re-measures before this frame lays out.
            syncTextMetrics()

            // Live size from GLFW (not only post-swapchain).
            syncFramebufferSize()

            scope.windowVisible = editor.isVisible(window: id)
        }
    }

    /// Caret bookkeeping and the minimize/restore edge. Runs after
    /// `AnimationDriver.tick()` so a restore's redraw cannot be consumed by
    /// the same frame that decided nothing was animating.
    func syncCaret() {
        WindowScope.withCurrent(scope) {
            // A blinking caret is the other thing that keeps an idle app awake
            // forever, and unlike an animation it does not need
            // `NodeVisibility` to know it is pointless: nobody can see a
            // minimized window's caret, so it must not schedule wakes or dirty
            // frames there.
            if scope.windowVisible, FocusManager.focusedID != nil {
                if CaretBlink.phaseChanged() { ViewInvalidation.markNeedsRedraw() }
                FrameScheduler.requestWake(in: CaretBlink.period / 4)
            }

            if scope.windowVisible != wasWindowVisible {
                wasWindowVisible = scope.windowVisible
                // On restore the caret has to come back without waiting for the
                // user to type or click: the suspended blink left the phase
                // stale, so adopt the live one and paint a frame with it.
                if scope.windowVisible {
                    CaretBlink.resync()
                    ViewInvalidation.markNeedsRedraw()
                }
            }
        }
    }

    /// Does whatever work this window's invalidation asks for, and presents if
    /// there was any.
    func present() {
        WindowScope.withCurrent(scope) {
            let level = ViewInvalidation.consume()
            if dirty { ViewInvalidation.markNeedsBody() }
            let work = dirty ? InvalidationLevel.body : level
            dirty = false

            // A frame the renderer wants for itself: a tint still fading, a
            // scroll still easing, or one parked at the edge of the content
            // it was handed and freed to continue by the publish that just
            // widened it. Consumed unconditionally — it is a take.
            //
            // None of those change a view value, so there is nothing to
            // re-emit; the retained list is redrawn as it stands. Without
            // this the renderer's own motion only reaches the screen when it
            // happens to move a node far enough to report a new offset, and a
            // scroll that stops moving stops being drawn.
            let rendererWantsFrame = editor.takeInternalRepaint(window: id)
            guard work > .none else {
                if rendererWantsFrame { editor.renderFrame(window: id) }
                return
            }

            let p0 = enableDebug ? FrameScheduler.now() : 0
            renderFrame(work)
            let p1 = enableDebug ? FrameScheduler.now() : 0
            editor.renderFrame(window: id)
            if enableDebug { logFrame(work, renderStart: p0, presentStart: p1) }
            // Only after a frame was actually emitted. Advancing the image
            // clock on an idle iteration would mean "nothing was drawn", which
            // makes every cached image look unused — including the ones on
            // screen — and evicts them straight into a reload.
            ImageStore.endFrame(into: editor)
        }
    }

    /// One full frame, ignoring invalidation. Used by the agent server's
    /// `settle`, which needs the screen current before it screenshots.
    func settle() {
        WindowScope.withCurrent(scope) {
            menuHost?.poll()
            while let ev = editor.pollInputEvent(window: id) {
                processInputEvent(ev)
            }
            syncTextMetrics()
            syncFramebufferSize()
            scope.windowVisible = editor.isVisible(window: id)
            if scope.windowVisible { AnimationDriver.tick() }
            let level = ViewInvalidation.consume()
            if dirty { ViewInvalidation.markNeedsBody() }
            let work = dirty ? InvalidationLevel.body : max(level, .redraw)
            dirty = false
            renderFrame(work)
            editor.renderFrame(window: id)
        }
    }

    /// True once this window has been asked to close — its titlebar X, a WM
    /// request, or `requestClose()`.
    var shouldClose: Bool { closeRequested || editor.windowShouldClose(id) }

    /// Asks for this window to be reaped at the end of the frame. Separate
    /// from the engine's own should-close flag so a programmatic close and a
    /// titlebar X take exactly the same path out.
    private var closeRequested = false

    func requestClose() { closeRequested = true }

    /// Detaches this window's nodes from the registries that outlive it.
    ///
    /// Those registries are keyed by `NodeID` and shared process-wide, which
    /// is correct — ids are unique, so windows cannot collide — but it means
    /// nothing drops an entry when a tree goes away. Node `deinit` does not
    /// do it either, and never had to: with one window the tree lived as long
    /// as the process. Now it does not, and the handlers are closures that
    /// capture their nodes, so leaving them behind would keep the whole closed
    /// tree alive and let a wheel event route into it.
    func teardown() {
        var ids: Set<NodeID> = []
        if let root = host.rootNode { collectIDs(root, into: &ids) }
        ScrollRouter.unregisterAll(ids: ids)
        DropRouter.unregisterAll(ids: ids)
        HoverState.unregisterAll(ids: ids)
        PointerCapture.discard(ids: ids)
        AnimationDriver.unregisterAll(in: scope)
        WindowScope.unregister(scope)
        onClose?()
    }

    private func collectIDs(_ node: any AnyViewNode, into ids: inout Set<NodeID>) {
        ids.insert(node.id)
        for child in node.childNodes { collectIDs(child, into: &ids) }
    }

    // ─── Pipeline ────────────────────────────────────────────────────────

    /// Does only as much of the pipeline as `level` requires. A pure redraw —
    /// an animation tick, a caret blink — skips body recompute and layout
    /// entirely, which is what keeps animation cheap.
    ///
    /// Assumes `scope` is already current; every caller above goes through
    /// `withCurrent`.
    private func renderFrame(_ level: InvalidationLevel) {
        syncFramebufferSize(invalidate: false)
        let bodyW = width
        let bodyH = max(1, height - menuH)
        let t0 = enableDebug ? FrameScheduler.now() : 0
        if level >= .body {
            // Per-node invalidation: a change tracked to specific composite
            // nodes recomputes just those, instead of every node in the tree
            // via a fresh root value. `nil` means something raised `.body`
            // without naming a node (first frame, or state outside the
            // observation system), which still needs the full rebuild.
            //
            // `menu` is a free closure, not a mounted node, so nothing
            // recomputes it — the IR has to be rebuilt here or a label, check
            // mark or enablement goes stale. That is cheap: it builds a menu
            // *description*, not a view tree.
            //
            // What is not cheap is remounting the root, which this used to do
            // unconditionally whenever a menubar existed — and since every app
            // has one, the per-node path below was dead code in every real
            // program. `update` already reports whether the platform-facing
            // model actually changed, so pay for the root only then.
            let menuChanged = refreshMenuModel()
            if menuChanged {
                installRootImpl()
            } else if let dirtyNodes = ViewInvalidation.consumeDirtyBodyNodes() {
                for node in dirtyNodes { node.recomputeBody() }
            } else {
                installRootImpl()
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
            // Overwritten below unless the guard on `rootNode` returns first,
            // in which case there was no emit to time.
            probeEmit = 0
        }

        if abs(bodyW - lastLoggedLayout.w) > 0.5 || abs(bodyH - lastLoggedLayout.h) > 0.5 {
            lastLoggedLayout = (bodyW, bodyH)
            let hostFrame = frames.first(where: { $0.label == "DiagramHost" })
            let msg: String
            if let dh = hostFrame {
                msg = "layout: \(Int(bodyW))×\(Int(bodyH)) DiagramHost "
                    + "\(Int(dh.w))×\(Int(dh.h))\n"
            } else {
                msg = "layout: \(Int(bodyW))×\(Int(bodyH))\n"
            }
            FileHandle.standardError.write(Data(msg.utf8))
        }

        guard let root = host.rootNode else { return }

        drawList.clear()
        drawList.rect(x: 0, y: 0, w: width, h: height, color: Theme.current.background)
        drawList.emitTree(
            root, originX: 0, originY: menuH, viewportW: width, viewportH: height
        )
        // This frame's NodeVisibility is now current; give any node that just
        // scrolled/resized/expanded into view a queued wake so it resumes on
        // its own next iteration (see doc comment).
        AnimationDriver.requestRevisibilityCheck()

        editor.submitDrawList(drawList)
        if enableDebug { probeEmit = (FrameScheduler.now() - t2) * 1000 }
        dirty = false
    }

    private func processInputEvent(_ ev: InputEvent) {
        switch ev.kind {
        case .mouseDown:
            if let action = host.hitTestClick(
                x: ev.x, y: ev.y, originX: 0, originY: menuH, mods: ev.mods
            ) {
                action()
                // A handler exists to change something, so a click is a repaint
                // request. `@State` writes invalidate themselves through
                // `Binding.set`, but a handler that mutates an `@Observable`
                // model reaches the screen only if some body *read* that
                // property — and a live-read presenter like
                // `overlay(isPresented:)` never does. Without this, opening a
                // panel from a click showed nothing until an unrelated event (a
                // hover) happened to repaint.
                //
                // `.redraw` is the right floor, the same reasoning
                // `Binding.set` documents: anything that genuinely changed the
                // tree has already raised `.body` via observation.
                ViewInvalidation.markNeedsRedraw()
            }
        case .resize:
            let nw = max(1, ev.x)
            let nh = max(1, ev.y)
            if nw != width || nh != height {
                width = nw
                height = nh
                ViewInvalidation.markNeedsLayout()
                FileHandle.standardError.write(
                    Data("layout resize → \(Int(nw))×\(Int(nh))\n".utf8)
                )
            }
        case .refresh:
            if !syncFramebufferSize() { ViewInvalidation.markNeedsRedraw() }
        case .mouseMove:
            PointerState.set(x: ev.x, y: ev.y)
            if PointerCapture.isActive {
                PointerCapture.move(x: ev.x, y: ev.y - menuH)
            }
        case .mouseUp:
            PointerCapture.release()
        case .scroll:
            // Renderer-owned ScrollViews consume this before it reaches us, so
            // arriving here means a node under the pointer declared a wheel
            // handler and the renderer stood aside for it. Chain delivery is
            // unchanged: the innermost handler willing to take the notch wins.
            let pointer = PointerState.window
            let consumed = ScrollRouter.deliver(
                to: host.hitTestScrollChain(
                    x: pointer.x, y: pointer.y, originY: menuH
                ),
                dx: ev.x, dy: ev.y, mods: ev.button
            )
            // Every handler declined — an editor already at its last line, a
            // canvas that only wants Ctrl+wheel. The container around them
            // should still scroll, which is what the wheel would have done had
            // none of them been there, so the notch goes back to the renderer.
            // Without this a pinned inner widget silently eats the event and
            // the page it sits on refuses to move.
            if !consumed {
                editor.scrollSceneUnclaimed(dx: ev.x, dy: ev.y, window: id)
            }
        case .nodeHover:
            HoverState.set(SceneNodeIdentity.node(for: UInt32(bitPattern: ev.button)))
        case .nodeScroll:
            guard let nodeID = SceneNodeIdentity.node(for: UInt32(bitPattern: ev.button)),
                  let scroll = findNode(nodeID, in: host.rootNode) as? ScrollNode
            else { break }
            scroll.adoptRendererOffset(x: ev.x, y: ev.y)
        case .fileDrop:
            DropRouter.deliver(
                to: host.hitTestHover(x: ev.x, y: ev.y, originY: menuH),
                paths: editor.droppedFiles(window: id)
            )
        case .text:
            if let scalar = Unicode.Scalar(UInt32(bitPattern: ev.button)) {
                _ = FocusManager.handle(character: Character(scalar))
            }
        case .key:
            if onRawKey?(ev) == true { break }
            let isPress = ev.x > 0
            if isPress, ev.button == KeyCode.escape, host.dismissOverlays() { break }
            if isPress, let menuHost,
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
            // `FontStore.metricsGeneration`, so this no longer has to — and
            // neither does any other caller that changes the scale.
            ContentScaleShortcuts.handle(ev, editor: editor)
        default:
            break
        }
    }

    private func findNode(
        _ id: NodeID, in node: (any AnyViewNode)?
    ) -> (any AnyViewNode)? {
        guard let node else { return nil }
        if node.id == id { return node }
        for child in node.childNodes {
            if let found = findNode(id, in: child) { return found }
        }
        return nil
    }

    /// Adopts the live framebuffer size. Returns whether it changed.
    @discardableResult
    private func syncFramebufferSize(invalidate: Bool = true) -> Bool {
        let fb = editor.framebufferSize(window: id)
        guard fb.w >= 1, fb.h >= 1, fb.w != width || fb.h != height else {
            return false
        }
        width = fb.w
        height = fb.h
        if invalidate { ViewInvalidation.markNeedsLayout() }
        return true
    }

    /// Re-measures text if the active face changed size since last check.
    private func syncTextMetrics() {
        guard FontStore.metricsGeneration != lastMetricsGeneration else { return }
        lastMetricsGeneration = FontStore.metricsGeneration
        host.invalidateTextMetrics()
        dirty = true
        let s = FontStore.scale
        FileHandle.standardError.write(Data(String(
            format: "ui scale → %.2fx (%dpx)\n", s.multiplier, Int(s.pixelSize)
        ).utf8))
    }

    /// Rebuilds the menubar IR from the app's builder. Returns whether the
    /// platform-facing model changed — i.e. whether the in-window strip has to
    /// be remounted, or the global menu re-exported.
    ///
    /// Always safe to call: `MenuController.update` re-stores the item actions
    /// regardless, so a menu whose labels are unchanged but whose closures
    /// captured newer state still activates against the new ones.
    @discardableResult
    private func refreshMenuModel() -> Bool {
        guard let makeMenu, let menuHost else { return false }
        return menuHost.update(makeMenu())
    }

    /// Per-frame timing, one line per rendered frame on stdout. Idle frames
    /// print nothing, because idle frames are not rendered.
    ///
    /// Kept because the cost that mattered was invisible: a slider drag spent
    /// 4.3ms in Yoga per pointer move and only *looked* like the knob lagging.
    /// No test catches that — the output was correct, just late. `layout` on a
    /// drag or an animation tick is the tell.
    private func logFrame(
        _ work: InvalidationLevel, renderStart p0: Double, presentStart p1: Double
    ) {
        let now = FrameScheduler.now()
        let label = work.probeName.padding(toLength: 6, withPad: " ", startingAt: 0)
        // Only when there is more than one window, so single-window output is
        // byte-identical to what it has always been.
        let prefix = LavaApp.windowCount > 1 ? "[\(scope.label)] " : ""
        let line = "\(prefix)frame \(label) " + String(
            format: "body=%5.2f layout=%5.2f emit=%5.2f present=%5.2f total=%5.2f ms\n",
            probeBody, probeLayout, probeEmit, (now - p1) * 1000, (now - p0) * 1000
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
