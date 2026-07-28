import Foundation
import FBDModel
import LavaUI

#if canImport(CxxCanvas)

/// FBD editor app: LavaUI chrome + diagram host.
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
            title: "FBD Editor"
        ) else {
            FileHandle.standardError.write(Data("failed to open editor window\n".utf8))
            exit(1)
        }

        // Sync to actual framebuffer (may differ from requested on HiDPI / WM).
        let fb0 = editor.framebufferSize()
        if fb0.w >= 1, fb0.h >= 1 {
            windowW = fb0.w
            windowH = fb0.h
        }

        if FontStore.bootstrap(assetsRoot: assets, pixelSize: 16, into: editor) == nil {
            FileHandle.standardError.write(Data("warning: default UIFont failed to load\n".utf8))
        }

        let diagram = makeSampleDiagram()
        let host = LayoutHost()
        let drawList = DrawList()

        // Selection and click count now live in EditorChrome's @State. The
        // run loop no longer mirrors view state, and `dirty` only tracks the
        // things Observation cannot see: window size and font scale.
        var dirty = true
        var lastLoggedLayout: (w: Float, h: Float) = (0, 0)

        func makeChrome() -> EditorChrome {
            EditorChrome(blocks: diagram.blocks.values.sorted { $0.name < $1.name })
        }

        func renderFrame() {
            let fb = editor.framebufferSize()
            if fb.w >= 1, fb.h >= 1 {
                windowW = fb.w
                windowH = fb.h
            }
            let bodyW = windowW
            let bodyH = max(1, windowH - menuH)
            let chrome = makeChrome()
            host.setRoot(chrome)
            let frames = host.calculateLayout(width: bodyW, height: bodyH)
            if let rootFrame = frames.first(where: { $0.label == "HStack" }) {
                if abs(rootFrame.w - bodyW) > 2 || abs(rootFrame.h - bodyH) > 2 {
                    let msg =
                        "layout warn: HStack \(Int(rootFrame.w))×\(Int(rootFrame.h)) "
                        + "!= body \(Int(bodyW))×\(Int(bodyH))\n"
                    FileHandle.standardError.write(Data(msg.utf8))
                }
            }
            if abs(bodyW - lastLoggedLayout.w) > 0.5 || abs(bodyH - lastLoggedLayout.h) > 0.5,
               let dh = frames.first(where: { $0.label == "DiagramHost" })
            {
                lastLoggedLayout = (bodyW, bodyH)
                let msg =
                    "layout: \(Int(bodyW))×\(Int(bodyH)) DiagramHost "
                    + "\(Int(dh.w))×\(Int(dh.h)) @ (\(Int(dh.x)),\(Int(dh.y)))\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }

            guard let root = host.rootNode else { return }

            drawList.clear()
            drawList.rect(
                x: 0, y: 0, w: windowW, h: windowH,
                color: Color(r: 0.10, g: 0.11, b: 0.13)
            )
            drawList.emitTree(
                root,
                originX: 0,
                originY: menuH,
                viewportW: windowW,
                viewportH: windowH
            )

            if let dh = host.diagramHostFrame() {
                let hx = dh.x
                let hy = dh.y + menuH
                editor.setDiagramViewport(x: hx, y: hy, w: dh.w, h: dh.h)
                drawList.pushClip(x: hx, y: hy, w: dh.w, h: dh.h)
                emitDiagram(diagram, into: drawList, hostX: hx, hostY: hy)
                drawList.popClip()
            }

            editor.submitDrawList(drawList)
            dirty = false
        }

        let chrome0 = makeChrome()
        Phase1Dump.run(chrome: chrome0)
        Phase2LayoutDump.run(chrome: chrome0, width: windowW, height: windowH - menuH)
        Phase5StateDump.run()
        Phase4TextDump.run(chrome: chrome0, width: windowW, height: windowH - menuH)

        renderFrame()

        while editor.isOpen {
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
                case .key:
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

            // A body read something that changed (a click mutating @State, say).
            // Observation set the flag; the loop decides when to act on it.
            if ViewInvalidation.consume() {
                dirty = true
            }

            if dirty {
                renderFrame()
            }
            Thread.sleep(forTimeInterval: 0.016)
        }
    }

    static func assetsRoot() -> String {
        if let env = ProcessInfo.processInfo.environment["CANVAS_ASSETS_ROOT"], !env.isEmpty {
            return env
        }
        // Sources/HelloWorld/HelloWorldApp.swift → repo root → canvas/.build.Debug
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
