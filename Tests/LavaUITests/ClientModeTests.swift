import XCTest

@testable import LavaUI

/// Client mode: body → layout → emit with no Vulkan, no window, no GPU.
///
/// The first tests here that open an `Editor` at all, and deliberately so —
/// the property under test is that opening one no longer implies a device.
/// They therefore also run where the other two would have been the only ones
/// able to: a machine with no GPU, no display server and no swapchain.
///
/// What is *not* asserted is what the frame looks like. A client's output is
/// checked against a renderer, and there is none here; these ask only whether
/// the pipeline runs and produces a frame, which is the thing that used to be
/// impossible.
final class ClientModeTests: XCTestCase {
    /// A tree with a bit of everything a client can legitimately emit: text
    /// that has to shape, nested layout, and a scroll container that opens a
    /// scene node.
    private struct Root: View {
        var body: some View {
            VStack(padding: 8) {
                Text("Client mode")
                ScrollView {
                    VStack {
                        ForEach(Array(0..<20), id: \.self) { i in
                            Text("row \(i)")
                        }
                    }
                }
            }
        }
    }

    private func openClient(
        width: Float = 800, height: Float = 600, file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Editor {
        let editor = try XCTUnwrap(
            Editor.openClient(width: width, height: height),
            "client engine failed to open", file: file, line: line
        )
        // Shaping is FreeType and HarfBuzz and never needed the device; this
        // asserts that, because without a face `Text` measures to nothing and
        // the emit below would pass for the wrong reason.
        XCTAssertNotNil(
            FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editor),
            "default face failed to load in client mode", file: file, line: line
        )
        return editor
    }

    /// The whole point: a frame gets built without a GPU anywhere in reach.
    func testClientEmitsAFrameWithNoDevice() throws {
        let editor = try openClient()
        let host = LayoutHost()
        host.setRoot(Root())
        _ = host.calculateLayout(width: 800, height: 600)
        let root = try XCTUnwrap(host.rootNode)

        let list = DrawList(editor: editor)
        list.clear()
        list.emitTree(root, viewportW: 800, viewportH: 600)
        editor.submitDrawList(list)

        XCTAssertGreaterThan(list.commandCount, 0, "client emitted no commands")
        XCTAssertGreaterThan(
            list.glyphCount, 0,
            "client emitted no glyphs — text did not shape without a device"
        )
    }

    /// A client has no surface to measure, so being told its size is the only
    /// way it can learn one — and it has to arrive as the same `.resize` a
    /// windowed app gets, or nothing above re-lays-out.
    func testClientSizeArrivesAsAResizeEvent() throws {
        let editor = try openClient(width: 800, height: 600)
        XCTAssertEqual(editor.framebufferSize().w, 800)

        editor.setClientSize(width: 1024, height: 768)
        XCTAssertEqual(editor.framebufferSize().w, 1024)
        XCTAssertEqual(editor.framebufferSize().h, 768)

        var sawResize = false
        while let ev = editor.pollInputEvent() {
            guard ev.kind == .resize else { continue }
            sawResize = true
            XCTAssertEqual(ev.x, 1024)
            XCTAssertEqual(ev.y, 768)
        }
        XCTAssertTrue(sawResize, "resize to a new size queued no .resize event")

        // A restated size is not a change, and a producer that re-lays-out on
        // every one of those is doing it for nothing.
        editor.setClientSize(width: 1024, height: 768)
        XCTAssertNil(editor.pollInputEvent())
    }

    /// Injection is a client's whole input path rather than a test affordance
    /// over a real one, which is what lets the agent server drive a client
    /// with no compositor on the other end.
    func testInjectedInputReachesTheQueue() throws {
        let editor = try openClient()
        editor.injectPointerMove(x: 120, y: 64)

        var move: InputEvent?
        while let ev = editor.pollInputEvent() {
            if ev.kind == .mouseMove { move = ev }
        }
        let seen = try XCTUnwrap(move, "injected pointer move never arrived")
        XCTAssertEqual(seen.x, 120)
        XCTAssertEqual(seen.y, 64)
    }

    /// The gaps, asserted rather than assumed. Both are scoped work, and both
    /// fail in a way callers already handle — a missing image file does the
    /// same thing, and a screenshot of a client is not a thing that exists.
    func testGpuBoundCallsFailRatherThanPretend() throws {
        let editor = try openClient()
        XCTAssertNil(editor.capturePngBase64(), "a client has no pixels to capture")
        XCTAssertFalse(editor.hasImage(key: "anything"))
    }

    /// `renderFrame` succeeding is what lets `LavaWindow` present a client
    /// frame with no branch of its own: the frame is finished when it is
    /// committed, and drawing it is someone else's job.
    func testRenderFrameSucceedsAndDrawsNowhere() throws {
        let editor = try openClient()
        XCTAssertTrue(editor.renderFrame())
        XCTAssertFalse(
            editor.takeInternalRepaint(),
            "a client owns no scene state, so nothing can ask it to repaint"
        )
    }
}
