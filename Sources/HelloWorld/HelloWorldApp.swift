import Foundation
import LavaUI

#if canImport(CxxCanvas)

/// Runs the LavaUI widget playground (`DemoExample`).
@main
struct HelloWorldApp {
    static func main() {
        let assets = assetsRoot()
        FileHandle.standardError.write(Data("assets: \(assets)\n".utf8))

        var windowW: Float = 1280
        var windowH: Float = 800
        let menuH: Float = 0

        guard let editor = Editor.open(
            assetsRoot: assets,
            width: Int32(windowW),
            height: Int32(windowH),
            title: "LavaUI · DemoExample"
        ) else {
            FileHandle.standardError.write(Data("failed to open editor window\n".utf8))
            exit(1)
        }

        let fb0 = editor.framebufferSize()
        if fb0.w >= 1, fb0.h >= 1 {
            windowW = fb0.w
            windowH = fb0.h
        }

        if FontStore.bootstrap(assetsRoot: assets, pixelSize: 16, into: editor) == nil {
            FileHandle.standardError.write(Data("warning: default UIFont failed to load\n".utf8))
        }

        let brandImage = ImageStore.loadAsset(
            named: "football-157930.svg_64.png",
            assetsRoot: assets,
            into: editor
        )
        if brandImage == nil {
            FileHandle.standardError.write(Data("warning: brand image failed to load\n".utf8))
        }

        ClipboardBridge.reader = { editor.clipboardText }
        ClipboardBridge.writer = { editor.clipboardText = $0 }

        let host = LayoutHost()
        let drawList = DrawList()

        var dirty = true
        // The wheel event carries no position, so remember the last one.
        var lastPointer: (x: Float, y: Float) = (0, 0)
        var lastLoggedLayout: (w: Float, h: Float) = (0, 0)

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

        func makeRoot() -> DemoExample {
            DemoExample(brandImage: brandImage)
        }

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
                host.setRoot(makeRoot())
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

            editor.submitDrawList(drawList)
            if enableDebug { probeEmit = (FrameScheduler.now() - t2) * 1000 }
            dirty = false
        }

        // Lightweight structure dump (no FBD chrome phases).
        let demo0 = makeRoot()
        FileHandle.standardError.write(Data("--- DemoExample structure ---\n".utf8))
        for line in demo0.structureLines() {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        FileHandle.standardError.write(Data("--- end structure ---\n".utf8))

        renderFrame(.body)

        while editor.isOpen {
            // One scheduler for every periodic thing: caret blink, animations,
            // and later tooltips. Negative blocks until input arrives.
            editor.pumpEvents(timeout: FrameScheduler.timeoutUntilNextWake())

            while let ev = editor.pollInputEvent() {
                switch ev.kind {
                case .mouseDown:
                    if let action = host.hitTestClick(
                        x: ev.x, y: ev.y,
                        originX: 0, originY: menuH
                    ) {
                        action()
                    }
                case .resize:
                    // GLFW framebuffer callback (live drag). Layout only — view
                    // structure is unchanged; Yoga needs the new root size.
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
                    // Un-minimize / expose / compositor damage: re-present.
                    // Size may have changed while hidden — prefer layout if so.
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
                    // Wheel goes to whatever is under the pointer, focused or
                    // not, so scrolling a panel never steals focus.
                    ScrollRouter.deliver(
                        to: host.hitTestHover(x: lastPointer.x, y: lastPointer.y, originY: menuH),
                        dx: ev.x, dy: ev.y, mods: ev.button
                    )
                case .text:
                    if let scalar = Unicode.Scalar(UInt32(bitPattern: ev.button)) {
                        _ = FocusManager.handle(character: Character(scalar))
                    }
                case .key:
                    let isPress = ev.x > 0
                    // Before focus: Escape closes a menu rather than being
                    // eaten by whatever text field happens to be focused.
                    if isPress, ev.button == KeyCode.escape, host.dismissOverlays() {
                        break
                    }
                    if isPress,
                       FocusManager.handle(
                           KeyEvent(key: ev.button, mods: Int32(ev.y), isRepeat: ev.x > 1)
                       )
                    {
                        break
                    }
                    if ContentScaleShortcuts.handle(ev, editor: editor) {
                        host.invalidateTextMetrics()
                        dirty = true
                        let s = FontStore.scale
                        let msg = String(
                            format: "ui scale → %.2fx (%dpx)\n",
                            s.multiplier, Int(s.pixelSize)
                        )
                        FileHandle.standardError.write(Data(msg.utf8))
                    }
                default:
                    break
                }
            }

            // Live size from GLFW (not only post-swapchain). Covers any resize
            // that arrived without a Resize event still in the queue.
            let fb = editor.framebufferSize()
            if fb.w >= 1, fb.h >= 1, fb.w != windowW || fb.h != windowH {
                windowW = fb.w
                windowH = fb.h
                ViewInvalidation.markNeedsLayout()
            }

            // Animations step before the level is read, so a still-running one
            // raises the flag for this frame rather than the next.
            AnimationDriver.tick()

            if FocusManager.focusedID != nil {
                // A blinking caret is a pure redraw, and it keeps asking to be
                // woken for as long as something is focused.
                if CaretBlink.phaseChanged() { ViewInvalidation.markNeedsRedraw() }
                FrameScheduler.requestWake(in: CaretBlink.period / 4)
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
                    // Written rather than `print`: stdout is block-buffered
                    // when redirected, so piping to a file would show nothing
                    // until the app exits.
                    FileHandle.standardOutput.write(Data(line.utf8))
                }
            }
        }
    }

    static func assetsRoot() -> String {
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
}

extension InvalidationLevel {
    /// How much of body → layout → emit this frame ran, for the timing line.
    var probeName: String {
        switch self {
        case .none: return "none"
        case .redraw: return "redraw"
        case .layout: return "layout"
        case .body: return "body"
        }
    }
}

#else

@main
struct HelloWorldApp {
    static func main() {
        FileHandle.standardError.write(
            Data("HelloWorld: LavaUI requires Linux + libcanvas (CxxCanvas).\n".utf8)
        )
        exit(1)
    }
}

#endif
