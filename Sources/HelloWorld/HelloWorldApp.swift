import SwiftCrossUI
import DefaultBackend
import Foundation

#if canImport(SwiftBundlerRuntime)
    import SwiftBundlerRuntime
#endif

#if canImport(CanvasKit)
    import CanvasKit
#endif

struct FileNode: Identifiable {
    let id = UUID()
    var name: String
    var children: [FileNode]?
}

let sampleFileTree: [FileNode] = [
    FileNode(
        name: "Documents",
        children: [
            FileNode(name: "Resume.pdf", children: nil),
            FileNode(
                name: "Projects",
                children: [
                    FileNode(
                        name: "HelloWorld",
                        children: [
                            FileNode(name: "HelloWorldApp.swift", children: nil),
                            FileNode(name: "TreeView.swift", children: nil),
                        ]
                    ),
                    FileNode(name: "Notes.txt", children: nil),
                ]
            ),
        ]
    ),
    FileNode(
        name: "Photos",
        children: [
            FileNode(name: "Vacation", children: []),
            FileNode(name: "Family.png", children: nil),
        ]
    ),
]

/// Where the canvas engine's Meson build copies its assets/shaders
/// (canvas/meson.build's copy_assets + shaders subdir land here). Computed
/// from this file's own location so it doesn't depend on the process's
/// current directory (which swift-bundler's run loop doesn't put at the
/// HelloWorld repo root).
let canvasAssetsRoot: String = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // HelloWorldApp.swift -> Sources/HelloWorld/
        .deletingLastPathComponent()  // -> Sources/
        .deletingLastPathComponent()  // -> HelloWorld (repo root)
        .appendingPathComponent("canvas/.build.Debug")
        .path
}()

let canvasWidth = 830
let canvasHeight = 340

#if canImport(CanvasKit)
    /// Owns the `CanvasEngine` and runs `repaint`/`readPixels` off the main
    /// actor. This matters a lot in practice: a real Vulkan repaint (device
    /// wait + full-frame CPU readback) takes far longer than the cheap
    /// procedural test pattern this replaced, and running it synchronously
    /// on the main actor — where SwiftCrossUI/Gtk's own event loop also
    /// lives — starves that loop entirely. Observed directly: the app
    /// window went fully unresponsive (100% CPU, frame counter frozen,
    /// clicks ignored) the first time this ran on the main actor instead of
    /// here. An `actor` (not `@MainActor`) gets its own execution context,
    /// so awaiting into it lets Gtk keep pumping events between frames.
    ///
    /// This is retained mode: rectangles added here stick around across
    /// repaint() calls until removed. There's no per-frame loop anymore —
    /// each method below adds/updates the scene and repaints once, mirroring
    /// how the real caller (Swift, driving the scene from user input or FBD
    /// model changes) is expected to work.
    actor CanvasRunner {
        private var engine: CanvasEngine?

        /// Creates the engine (once) and renders the sample FBD diagram.
        /// Returns the first rendered frame, or nil if this wasn't the
        /// first call or the engine failed to start.
        func ensureStarted(assetsRoot: String, width: Int, height: Int) -> [UInt8]? {
            guard engine == nil else { return nil }
            guard let engine = CanvasEngine(assetsRoot: assetsRoot, width: width, height: height) else {
                return nil
            }
            self.engine = engine

            renderDiagram(makeSampleDiagram(), into: engine)
            return engine.readPixels()
        }
    }
#endif

@main
@HotReloadable
struct YourApp: App {
    @State var count = 0
    @State var lastPointer = "–"
    @State var canvasPixels = [UInt8](repeating: 0, count: canvasWidth * canvasHeight * 4)
    #if canImport(CanvasKit)
        @State var canvasRunner = CanvasRunner()
    #endif

    var body: some Scene {
        WindowGroup("YourApp") {
            #hotReloadable {
                HStack(alignment: .top, spacing: 0) {
                    VStack {
                        PixelCanvas(
                            width: canvasWidth,
                            height: canvasHeight,
                            pixels: canvasPixels
                        ) { event in
                            switch event {
                            case .pointerMoved(let x, let y):
                                lastPointer = "(\(Int(x)), \(Int(y)))"
                            case .pointerExited:
                                lastPointer = "–"
                            case .mouseDown(let button, let x, let y):
                                lastPointer = "(\(Int(x)), \(Int(y))) down(\(button))"
                            case .mouseUp(let button, let x, let y):
                                lastPointer = "(\(Int(x)), \(Int(y))) up(\(button))"
                            }
                        }

                        Text("Pointer: \(lastPointer)")
                    }
                    .padding()

                    Divider()

                    VStack {
                        HStack {
                            Button("-") { count -= 1 }
                            Text("Count: \(count)")
                            Button("+") { count += 1 }
                        }.padding()

                        Divider()

                        ScrollView {
                            TreeView(sampleFileTree, children: \.children) { node in
                                Text(node.name)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(width: 320, height: 300)
                        .background(Color(red: 1.0, green: 1.0, blue: 1.0))
                        .padding()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.10, green: 0.11, blue: 0.15))
                .task {
                    #if canImport(CanvasKit)
                        if let pixels = await canvasRunner.ensureStarted(
                            assetsRoot: canvasAssetsRoot,
                            width: canvasWidth,
                            height: canvasHeight
                        ) {
                            canvasPixels = pixels
                        }
                    #endif
                }
            }
        }
        .defaultSize(width: 1230, height: 560)
    }
}