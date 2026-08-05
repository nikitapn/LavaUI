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

    /// A client with nobody to ask still has to answer, and does so from a
    /// local table — stable ids, and a bad path caught at registration rather
    /// than as missing text in a frame nobody can debug.
    func testAClientWithNoHostNamesItsOwnFonts() throws {
        let editor = try openClient()
        let face = LavaResources.fontsDirectory + "/OpenSans-Regular.ttf"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: face), "no UI face on disk")

        let first = try XCTUnwrap(editor.registerFont(path: face, pixelSize: 16))
        XCTAssertEqual(
            editor.registerFont(path: face, pixelSize: 16), first,
            "registration is idempotent per (path, pixelSize)"
        )
        XCTAssertNotEqual(
            editor.registerFont(path: face, pixelSize: 24), first,
            "a different size is a different face"
        )
        XCTAssertNil(
            editor.registerFont(path: "/nonesuch.ttf", pixelSize: 16),
            "a face that will not load must not get an id"
        )
    }

    /// A client cannot capture pixels it never drew. Failing is the honest
    /// answer; an empty PNG would look like a black screen.
    func testCaptureFailsRatherThanPretend() throws {
        let editor = try openClient()
        XCTAssertNil(editor.capturePngBase64())
    }

    // ─── Two modes ───────────────────────────────────────────────────────

    /// Stands in for the compositor: records what it was asked and hands back
    /// ids nothing local would ever mint, so a call that went to the built-in
    /// renderer instead is visible rather than merely wrong.
    private final class StubHost: GPUResourceHost, @unchecked Sendable {
        var fontAsks: [(path: String, pixelSize: Float)] = []
        var imageAsks: [(path: String, maxPixelSize: UInt32)] = []
        var released: [String] = []

        static let fontID: UInt32 = 4242
        static let textureID: UInt32 = 9001

        func registerFont(path: String, pixelSize: Float) -> UInt32? {
            fontAsks.append((path, pixelSize))
            return Self.fontID
        }

        func registerImage(path: String, maxPixelSize: UInt32) -> UIImage? {
            imageAsks.append((path, maxPixelSize))
            return UIImage(
                path: path,
                cacheKey: ImageStore.key(path: path, maxPixelSize: maxPixelSize),
                textureId: Self.textureID, pixelWidth: 64, pixelHeight: 48
            )
        }

        func releaseImage(key: String) { released.append(key) }
    }

    /// The seam: with a host installed, the id stamped into every glyph is
    /// the host's. Getting this wrong draws the wrong face silently, because
    /// a stale font id is still a valid index.
    func testInstalledHostNamesFonts() throws {
        let editor = try openClient()
        let host = StubHost()
        editor.resources = host

        let face = LavaResources.fontsDirectory + "/OpenSans-Regular.ttf"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: face), "no UI face on disk")
        let font = try XCTUnwrap(UIFont.loadUI(assetsRoot: LavaResources.root, pixelSize: 16))
        XCTAssertTrue(font.registerWithEngine(editor))

        XCTAssertEqual(font.engineId, StubHost.fontID, "font id did not come from the host")
        XCTAssertEqual(host.fontAsks.count, 1)
        XCTAssertEqual(host.fontAsks.first?.path, face)
    }

    /// The same seam for images, including the part that is easy to get
    /// wrong: the handle a host returns has to carry the cache key
    /// `ImageStore` will look it up by, or every frame after the first misses
    /// and registers it again.
    func testInstalledHostNamesImages() throws {
        let editor = try openClient()
        let host = StubHost()
        editor.resources = host

        let image = try XCTUnwrap(ImageStore.load(path: "/pretend/art.png", into: editor))
        XCTAssertEqual(image.textureId, StubHost.textureID)
        XCTAssertEqual(image.pixelWidth, 64)
        XCTAssertEqual(host.imageAsks.count, 1)

        // The second ask is a cache hit, not a second registration.
        _ = ImageStore.load(path: "/pretend/art.png", into: editor)
        XCTAssertEqual(host.imageAsks.count, 1, "cache missed its own entry")
    }

    /// Restoring the default is what a test needs and what a misconfigured
    /// app needs to be able to do; `resources` must not latch.
    func testResourcesFallsBackToTheEditor() throws {
        let editor = try openClient()
        XCTAssertTrue(editor.resources === editor, "default host is the editor itself")
        editor.resources = StubHost()
        XCTAssertFalse(editor.resources === editor)
        editor.resources = editor
        XCTAssertTrue(editor.resources === editor, "assigning the editor must not cycle")
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
