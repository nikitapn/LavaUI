import Foundation
import FBDModel

#if canImport(CxxCanvas)

/// C++ interop app: Swift owns FBDModel + declarative UI tree;
/// C++ owns Vulkan / Yoga / TextRenderer / hit-test.
@main
struct HelloWorldApp {
    static func main() {
        let assets = assetsRoot()
        FileHandle.standardError.write(Data("assets: \(assets)\n".utf8))

        guard let editor = Editor.open(
            assetsRoot: assets,
            width: 1280,
            height: 800,
            title: "FBD Editor"
        ) else {
            FileHandle.standardError.write(Data("failed to open editor window\n".utf8))
            exit(1)
        }

        let diagram = makeSampleDiagram()
        renderDiagram(diagram, into: editor)

        let ui = UI()
        var selectedBlockId: String? = nil
        var clickCount = 0

        func rebuildChrome() {
            ui.beginCommit()
            let blocks = diagram.blocks.values.sorted { $0.name < $1.name }
            let sel = selectedBlockId ?? blocks.first.map { String($0.id.rawValue) }

            let root = ui.HStack(flexGrow: 1, padding: 4) {
                // Left: project tree as Text labels
                ui.VStack(width: 220, padding: 8) {
                    ui.Text("Project", r: 0.7, g: 0.75, b: 0.9)
                    ui.Text("Diagrams", r: 0.55, g: 0.55, b: 0.6)
                    ui.Text("  Main", r: 0.85, g: 0.85, b: 0.85)
                    for b in blocks {
                        let id = String(b.id.rawValue)
                        let selected = (id == sel)
                        ui.Text(
                            "  \(b.name)",
                            r: selected ? 1.0 : 0.8,
                            g: selected ? 0.85 : 0.8,
                            b: selected ? 0.4 : 0.8,
                            onClick: {
                                selectedBlockId = id
                                clickCount += 1
                                FileHandle.standardError.write(
                                    Data("click: \(b.name) (#\(clickCount))\n".utf8)
                                )
                            }
                        )
                    }
                    ui.Spacer()
                    ui.Text(
                        "clicks: \(clickCount)",
                        r: 0.5, g: 0.6, b: 0.5
                    )
                }

                // Center: FBD diagram host (Yoga flex-grow)
                ui.DiagramHost()

                // Right: properties for selection
                ui.VStack(width: 260, padding: 8) {
                    ui.Text("Properties", r: 0.7, g: 0.75, b: 0.9)
                    if let sel, let bid = Int(sel),
                       let block = diagram.blocks[BlockID(bid)]
                    {
                        ui.Text("Name: \(block.name)")
                        ui.Text("Kind: \(block.kind.displayName)")
                        ui.Text("In: \(block.inputs.count)  Out: \(block.outputs.count)")
                        for (k, v) in block.properties.sorted(by: { $0.key < $1.key }) {
                            ui.Text("\(k): \(v.description)", r: 0.75, g: 0.75, b: 0.75)
                        }
                    } else {
                        ui.Text("(nothing selected)", r: 0.5, g: 0.5, b: 0.5)
                    }
                    ui.Spacer()
                    ui.Text(
                        "Hot-update: re-commit tree",
                        r: 0.45, g: 0.55, b: 0.5
                    )
                }
            }

            editor.commitUI(root, ui: ui)
        }

        rebuildChrome()

        // ST editor sits in diagram-local coords (offset/scissor by C++).
        let editorId = editor.addTextWidget(
            x: 24, y: 360, w: 420, h: 120,
            text: """
            // FUNCTION expression
            IF speed > 10.0 THEN
              out := TRUE;
            END_IF
            """,
            multiline: true
        )
        _ = editor.addTextHighlight(
            id: editorId, pattern: #"//[^\n]*"#,
            r: 0.40, g: 0.70, b: 0.40, priority: 10
        )
        _ = editor.addTextHighlight(
            id: editorId,
            pattern: #"\b(IF|THEN|ELSE|END_IF|TRUE|FALSE)\b"#,
            r: 0.75, g: 0.55, b: 1.0, priority: 5
        )
        editor.setTextWidgetFocused(editorId, true)

        var lastSelected = selectedBlockId
        var lastClicks = clickCount
        while editor.isOpen {
            editor.dispatchUIEvents(ui: ui)
            // Structural hot update: re-commit tree when Swift state changes.
            // (Cheap for small trees; this is the "hot reload of the tree" path.)
            if selectedBlockId != lastSelected || clickCount != lastClicks {
                lastSelected = selectedBlockId
                lastClicks = clickCount
                rebuildChrome()
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
