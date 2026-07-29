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
        var lastLoggedLayout: (w: Float, h: Float) = (0, 0)

        func makeRoot() -> DemoExample {
            DemoExample(brandImage: brandImage)
        }

        func renderFrame() {
            let fb = editor.framebufferSize()
            if fb.w >= 1, fb.h >= 1 {
                windowW = fb.w
                windowH = fb.h
            }
            let bodyW = windowW
            let bodyH = max(1, windowH - menuH)
            host.setRoot(makeRoot())
            let frames = host.calculateLayout(width: bodyW, height: bodyH)

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

            // Demo has a DiagramHost but no FBD scene — leave the host fill as-is.
            if let dh = host.diagramHostFrame() {
                editor.setDiagramViewport(x: dh.x, y: dh.y + menuH, w: dh.w, h: dh.h)
            }

            editor.submitDrawList(drawList)
            dirty = false
        }

        // Lightweight structure dump (no FBD chrome phases).
        let demo0 = makeRoot()
        FileHandle.standardError.write(Data("--- DemoExample structure ---\n".utf8))
        for line in demo0.structureLines() {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        FileHandle.standardError.write(Data("--- end structure ---\n".utf8))

        renderFrame()

        while editor.isOpen {
            let wake: Double = FocusManager.focusedID != nil ? CaretBlink.period / 4 : -1
            editor.pumpEvents(timeout: wake)

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
                    let nw = max(1, ev.x)
                    let nh = max(1, ev.y)
                    if nw != windowW || nh != windowH {
                        windowW = nw
                        windowH = nh
                        dirty = true
                        FileHandle.standardError.write(
                            Data("layout resize → \(Int(nw))×\(Int(nh))\n".utf8)
                        )
                    }
                case .mouseMove:
                    if PointerCapture.isActive {
                        PointerCapture.move(x: ev.x, y: ev.y - menuH)
                    } else {
                        HoverState.set(
                            host.hitTestHover(x: ev.x, y: ev.y, originY: menuH)
                        )
                    }
                case .mouseUp:
                    PointerCapture.release()
                case .text:
                    if let scalar = Unicode.Scalar(UInt32(bitPattern: ev.button)) {
                        _ = FocusManager.handle(character: Character(scalar))
                    }
                case .key:
                    let isPress = ev.x > 0
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

            let fb = editor.framebufferSize()
            if fb.w >= 1, fb.h >= 1, fb.w != windowW || fb.h != windowH {
                windowW = fb.w
                windowH = fb.h
                dirty = true
            }

            if ViewInvalidation.consume() {
                dirty = true
            }
            if FocusManager.focusedID != nil, CaretBlink.phaseChanged() {
                dirty = true
            }

            if dirty {
                renderFrame()
                editor.renderFrame()
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
