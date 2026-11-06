import CYoga
import CxxCanvas
import XCTest

@testable import LavaUI

/// What a window drawn on a scaled screen asks the renderer to decode.
///
/// The compositor draws a window at its output's scale and rasterises text at
/// the device size itself, but an image is decoded at whatever size the client
/// asked for — so a box laid out at 80pt on a 1.5 screen has to ask for 120
/// pixels, or the renderer can only stretch what it was given. The layout must
/// not move: only the request changes.
final class DisplayScaleTests: XCTestCase {
    // ─── The arithmetic ──────────────────────────────────────────────────

    func testPixelsRoundUp() {
        XCTAssertEqual(DisplayScale.pixels(80, scale: 1), 80)
        XCTAssertEqual(DisplayScale.pixels(80, scale: 1.5), 120)
        // Up, not to nearest: a decode a pixel short is a resample, a pixel
        // over is invisible.
        XCTAssertEqual(DisplayScale.pixels(81, scale: 1.25), 102)
        XCTAssertEqual(DisplayScale.pixels(0, scale: 2), 0, "0 means native and must stay 0")
    }

    func testNonsenseScalesAreRefused() {
        // Zero would turn every cap into 0, which reads as *native* — a
        // thumbnail grid decoding every photo at full size.
        XCTAssertNil(DisplayScale.note(0, window: WindowID(raw: 7)))
        XCTAssertNil(DisplayScale.note(.nan, window: WindowID(raw: 7)))
        XCTAssertNil(DisplayScale.note(100, window: WindowID(raw: 7)))
        XCTAssertEqual(DisplayScale.note(1.5, window: WindowID(raw: 7)), 1.5)
        // Not the main window, so the app-wide reading does not follow.
        XCTAssertEqual(DisplayScale.main, 1)
    }

    // ─── What emit asks for ──────────────────────────────────────────────

    /// Records the decodes asked of it and answers none, so every request is
    /// visible and nothing is cached between scales.
    private final class RecordingHost: GPUResourceHost, @unchecked Sendable {
        var asks: [(path: String, maxPixelSize: UInt32)] = []

        func registerFont(
            path: String, pixelSize26_6: UInt32, faceIndex: UInt32,
            rasterFlags: UInt32
        ) -> UInt32? { 1 }

        func registerImage(
            path: String, maxPixelSize: UInt32, turn: ImageTurn
        ) -> UIImage? {
            asks.append((path, maxPixelSize))
            return nil
        }

        func registerImageAsync(
            path: String, maxPixelSize: UInt32, turn: ImageTurn,
            completion: @escaping @Sendable (UIImage?) -> Void
        ) {
            asks.append((path, maxPixelSize))
            completion(nil)
        }

        func registerImage(data: [UInt8], maxPixelSize: UInt32) -> UIImage? { nil }

        func uploadPixels(
            _ pixels: UnsafeRawBufferPointer, width: UInt32, height: UInt32,
            stride: UInt32, format: PixelFormat
        ) -> UIImage? { nil }

        func releaseImage(key: String) {}
    }

    private func decodeAsked(at scale: Float, path: String) throws -> [UInt32] {
        let editor = try XCTUnwrap(
            Editor.openClient(width: 400, height: 300), "client engine failed to open"
        )
        let host = RecordingHost()
        editor.resources = host

        let root = ViewGraph.mount(
            Image(path: path, width: .pt(80), height: .pt(60))
        )
        let yoga = try XCTUnwrap(root.flattenedLayoutNodes().first?.yoga)
        YGNodeCalculateLayout(yoga, 400, 300, YGDirectionLTR)
        // The box is the same at every scale; only the request may differ.
        XCTAssertEqual(YGNodeLayoutGetWidth(yoga), 80)

        let list = DrawList(editor: editor, sink: CapturedFrameSink())
        list.displayScale = scale
        list.clear()
        list.emitDetached(root, width: 400, height: 300)
        return host.asks.filter { $0.path == path }.map(\.maxPixelSize)
    }

    func testAnImageIsDecodedForTheDeviceSize() throws {
        // A path per case: `ImageStore` remembers what is in flight, and a
        // shared one would make the second case a no-op.
        XCTAssertEqual(try decodeAsked(at: 1, path: "/nonexistent/scale-1.png"), [80])
        XCTAssertEqual(try decodeAsked(at: 1.5, path: "/nonexistent/scale-15.png"), [120])
        XCTAssertEqual(try decodeAsked(at: 2, path: "/nonexistent/scale-2.png"), [160])
    }
}
