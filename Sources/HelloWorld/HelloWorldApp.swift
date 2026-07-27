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

let canvasAssetsRoot: String = {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("canvas/.build.Debug")
        .path
}()

#if canImport(CanvasKit)
    /// Owns the windowed canvas. Strategy while the Gtk host moves/resizes:
    /// hide the GLFW surface immediately (Swift slot placeholder shows),
    /// then after a short settle delay re-place and show it. Minimized host
    /// keeps the canvas hidden until restored.
    actor CanvasRunner {
        private var engine: CanvasEngine?
        private var editorID: TextWidgetID?

        private var pendingFrame: ScreenRect?
        private var lastAppliedFrame: ScreenRect?
        private var hostActive = true
        private var settleTask: Task<Void, Never>?

        /// How long the host geometry must be stable before we show again.
        private let settleDelayMs: UInt64 = 150

        func ensureStarted(assetsRoot: String) -> Bool {
            guard engine == nil else { return engine?.isWindowOpen ?? false }
            guard let engine = CanvasEngine.openWindow(
                assetsRoot: assetsRoot,
                width: 640,
                height: 360,
                title: "FBD Canvas"
            ) else {
                return false
            }
            self.engine = engine
            // Start hidden until first settled layout frame arrives.
            engine.setWindowVisible(false)

            engine.addRect(x: 16, y: 16, width: 200, height: 48, r: 0.25, g: 0.28, b: 0.35)
            engine.addRect(x: 40, y: 90, width: 560, height: 220, r: 0.18, g: 0.20, b: 0.26)

            let editor = engine.addTextWidget(
                x: 56, y: 120, width: 528, height: 160,
                text: """
                // FUNCTION expression (demo ST)
                IF speed > 10.0 THEN
                  out := TRUE;
                ELSE
                  out := FALSE;
                END_IF
                """,
                multiline: true
            )
            _ = engine.setTextWidgetHighlightRules(editor, HighlightPresets.structuredText)
            engine.setTextWidgetFocused(editor, true)
            editorID = editor
            return true
        }

        func isWindowOpen() -> Bool {
            engine?.isWindowOpen ?? false
        }

        func isCanvasVisible() -> Bool {
            engine?.isWindowVisible ?? false
        }

        func handleSlotEvent(_ event: CanvasSlotEvent) {
            switch event {
            case .hostActive(let active):
                let wasActive = hostActive
                hostActive = active
                if !active {
                    settleTask?.cancel()
                    settleTask = nil
                    hideCanvas()
                } else if !wasActive {
                    // Restored from minimize — reattach once we have a frame.
                    scheduleSettleAndShow()
                }

            case .frameChanged(let frame):
                guard frame.width > 1, frame.height > 1 else { return }
                pendingFrame = frame
                // During continuous move/resize: hide immediately so the user
                // sees the Swift placeholder instead of a lagging overlay.
                hideCanvas()
                scheduleSettleAndShow()
            }
        }

        private func hideCanvas() {
            guard let engine, engine.isWindowOpen else { return }
            // Always post hide — render thread applies it (GLFW-thread-safe).
            engine.setWindowVisible(false)
        }

        private func scheduleSettleAndShow() {
            settleTask?.cancel()
            let delay = settleDelayMs
            settleTask = Task {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                await self.applySettledFrameAndShow()
            }
        }

        private func applySettledFrameAndShow() {
            guard let engine, engine.isWindowOpen else { return }
            guard hostActive else { return }
            guard let frame = pendingFrame, frame.width > 1, frame.height > 1 else { return }

            // Always re-apply frame + show. Even if the rect is unchanged we
            // may have been hidden during the drag; skipping setWindowFrame
            // when equal was fine, but we must always setVisible(true).
            lastAppliedFrame = frame
            engine.setWindowFrame(
                x: frame.x, y: frame.y,
                width: frame.width, height: frame.height
            )
            engine.setWindowVisible(true)
        }

        func pollEditorPreview() -> String? {
            guard let engine, let editorID else { return nil }
            _ = engine.textWidgetChanged(editorID)
            return engine.textWidgetText(editorID)
        }
    }
#endif

@main
@HotReloadable
struct YourApp: App {
    @State var count = 0
    @State var canvasStatus = "Canvas: starting…"
    @State var editorPreview = "(edit text in the canvas slot)"
    @State var slotLabel = "slot: –"
    #if canImport(CanvasKit)
        @State var canvasRunner = CanvasRunner()
    #endif

    var body: some Scene {
        WindowGroup("YourApp") {
            #hotReloadable {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SwiftCrossUI chrome")
                        Text(canvasStatus)
                        Text(slotLabel)
                        Text(
                            "During move/resize/minimize the live canvas hides "
                                + "and the slot placeholder shows. After ~150ms "
                                + "idle it reattaches."
                        )
                        .frame(maxWidth: 280, alignment: .leading)

                        Divider()

                        Text("Editor buffer:")
                        Text(editorPreview)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Spacer()
                    }
                    .padding()
                    .frame(width: 300)

                    Divider()

                    VStack(spacing: 0) {
                        CanvasLayoutSlot(minWidth: 400, minHeight: 280) { event in
                            switch event {
                            case .frameChanged(let frame):
                                slotLabel =
                                    "slot: \(frame.width)×\(frame.height) @ (\(frame.x),\(frame.y))"
                            case .hostActive(let active):
                                if !active {
                                    slotLabel = "slot: host inactive (minimized)"
                                }
                            }
                            #if canImport(CanvasKit)
                                Task {
                                    await canvasRunner.handleSlotEvent(event)
                                }
                            #endif
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

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
                        .frame(width: 260)
                        .background(Color(red: 1.0, green: 1.0, blue: 1.0))
                        .padding()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.10, green: 0.11, blue: 0.15))
                .task {
                    #if canImport(CanvasKit)
                        let ok = await canvasRunner.ensureStarted(assetsRoot: canvasAssetsRoot)
                        canvasStatus = ok
                            ? "Canvas: ready (hide-on-move)"
                            : "Canvas: failed to open (see stderr)"

                        while !Task.isCancelled {
                            if let text = await canvasRunner.pollEditorPreview() {
                                editorPreview = text
                            }
                            if !(await canvasRunner.isWindowOpen()) {
                                canvasStatus = "Canvas: closed"
                            } else if await canvasRunner.isCanvasVisible() {
                                canvasStatus = "Canvas: live"
                            } else {
                                canvasStatus = "Canvas: paused (placeholder)"
                            }
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                    #endif
                }
            }
        }
        .defaultSize(width: 1200, height: 700)
    }
}
