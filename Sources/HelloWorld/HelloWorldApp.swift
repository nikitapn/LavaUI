import Foundation
import FBDModel

#if canImport(CxxCanvas)

/// Single window: View DSL + Yoga + draw list (Phases 1–4).
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

        // Swift owns font policy: load default + push same face to C++ draw.
        if FontStore.bootstrap(assetsRoot: assets, pixelSize: 16, into: editor) == nil {
            FileHandle.standardError.write(Data("warning: default UIFont failed to load\n".utf8))
        }

        let diagram = makeSampleDiagram()
        let host = LayoutHost()
        let drawList = DrawList()

        var selectedBlockId: String? = nil
        var clickCount = 0
        var dirty = true
        var lastLoggedLayout: (w: Float, h: Float) = (0, 0)

        func makeChrome() -> EditorChrome {
            let blocks = diagram.blocks.values.sorted { $0.name < $1.name }
            return EditorChrome(
                blocks: blocks,
                selectedId: selectedBlockId,
                clickCount: clickCount,
                onSelect: { id, name in
                    selectedBlockId = id
                    clickCount += 1
                    dirty = true
                    FileHandle.standardError.write(
                        Data("click: \(name) (#\(clickCount))\n".utf8)
                    )
                }
            )
        }

        func renderFrame() {
            // Always trust live framebuffer size (resize events can lag mid-drag).
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
                // Sanity: root must fill the body (within 1px rounding).
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
        Phase4TextDump.run(chrome: chrome0, width: windowW, height: windowH - menuH)

        renderFrame()

        // GLFW key / mod codes (match canvas key_codes + glfw3.h).
        let keyEqual: Int32 = 61
        let keyMinus: Int32 = 45
        let keyKpAdd: Int32 = 334
        let keyKpSub: Int32 = 333
        let key0: Int32 = 48
        let keyKp0: Int32 = 320
        let modShift: Int32 = 0x0001
        let modControl: Int32 = 0x0002
        let actionPress: Float = 1
        let actionRepeat: Float = 2

        while editor.isOpen {
            while let ev = editor.pollInputEvent() {
                switch ev.kind {
                case 1: // MouseDown
                    if let action = host.hitTestClick(
                        x: ev.x, y: ev.y,
                        originX: 0, originY: menuH
                    ) {
                        action()
                    }
                case 4: // Resize — x/y are new framebuffer width/height
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
                case 5: // Key — button=key, x=action, y=mods
                    // Discrete UI scale: re-font → re-measure → Yoga reflow.
                    let key = ev.button
                    let action = ev.x
                    let mods = Int32(ev.y)
                    let isDown = action == actionPress || action == actionRepeat
                    guard isDown else { break }
                    let ctrlShift = (mods & modControl) != 0 && (mods & modShift) != 0
                    guard ctrlShift else { break }
                    let changed: Bool
                    if key == keyEqual || key == keyKpAdd {
                        changed = FontStore.zoomIn(into: editor)
                    } else if key == keyMinus || key == keyKpSub {
                        changed = FontStore.zoomOut(into: editor)
                    } else if key == key0 || key == keyKp0 {
                        changed = FontStore.resetScale(into: editor)
                    } else {
                        changed = false
                    }
                    if changed {
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

            // Safety net if a resize event was coalesced away.
            let fb = editor.framebufferSize()
            if fb.w >= 1, fb.h >= 1, fb.w != windowW || fb.h != windowH {
                windowW = fb.w
                windowH = fb.h
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
            Data("HelloWorld: CxxCanvas requires Linux + libcanvas.\n".utf8)
        )
        exit(1)
    }
}

#endif
