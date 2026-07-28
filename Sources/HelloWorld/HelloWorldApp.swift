import Foundation
import FBDModel

#if canImport(CxxCanvas)

/// Single window: View DSL + Yoga + draw list (Phases 1–4).
@main
struct HelloWorldApp {
    static func main() {
        let assets = assetsRoot()
        FileHandle.standardError.write(Data("assets: \(assets)\n".utf8))

        let windowW: Float = 1280
        let windowH: Float = 800
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
            let bodyW = windowW
            let bodyH = windowH - menuH
            let chrome = makeChrome()
            host.setRoot(chrome)
            _ = host.calculateLayout(width: bodyW, height: bodyH)

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

        while editor.isOpen {
            while let ev = editor.pollInputEvent() {
                if ev.kind == 1 {
                    if let action = host.hitTestClick(
                        x: ev.x, y: ev.y,
                        originX: 0, originY: menuH
                    ) {
                        action()
                    }
                }
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
