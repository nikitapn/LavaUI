import CxxCanvas
import XCTest

@testable import LavaUI

/// A drag chip is a frame in canvas's own format, chip-local, at its own size.
///
/// Each of these fails invisibly until somebody drags a file on a real
/// desktop: a chip emitted in window coordinates draws off the edge of its
/// own surface and shows as nothing, one measured against the window comes
/// out window-sized, and an array that is not whole structs is refused by
/// the compositor without a word to the client.
final class DragChipTests: XCTestCase {
    private func openEditor() throws -> Editor {
        let editor = try XCTUnwrap(
            Editor.openClient(width: 400, height: 300),
            "client engine failed to open"
        )
        XCTAssertNotNil(
            FontStore.bootstrap(assetsRoot: LavaResources.root, pixelSize: 16, into: editor),
            "default face failed to load"
        )
        return editor
    }

    private func commands(of chip: DragChipImage) -> [canvas.DrawCommand] {
        let stride = MemoryLayout<canvas.DrawCommand>.stride
        return chip.commands.withUnsafeBytes { raw in
            (0..<raw.count / stride).map { index in
                raw.loadUnaligned(fromByteOffset: index * stride, as: canvas.DrawCommand.self)
            }
        }
    }

    func testAChipIsTheSizeItAskedForNotTheWindows() throws {
        let editor = try openEditor()
        let chip = try XCTUnwrap(
            DragChipCapture.capture(
                view: Text("photo.jpg")
                    .frame(width: .pt(120), height: .pt(24))
                    .background(Theme.current.panel),
                editor: editor
            )
        )
        XCTAssertEqual(chip.width, 120)
        XCTAssertEqual(chip.height, 24)
    }

    func testEveryArrayIsWholeStructs() throws {
        let editor = try openEditor()
        let chip = try XCTUnwrap(
            DragChipCapture.capture(
                view: HStack(padding: 8, spacing: 8) {
                    Text("▤")
                    Text("notes.md")
                }
                .background(Theme.current.panel)
                .cornerRadius(6),
                editor: editor
            )
        )
        XCTAssertFalse(chip.commands.isEmpty)
        XCTAssertFalse(chip.glyphs.isEmpty, "the label's glyphs travel with it")
        XCTAssertEqual(chip.commands.count % MemoryLayout<canvas.DrawCommand>.stride, 0)
        XCTAssertEqual(chip.glyphs.count % MemoryLayout<canvas.GlyphInstance>.stride, 0)
        XCTAssertEqual(chip.meshVertices.count % MemoryLayout<canvas.MeshVertex>.stride, 0)
        XCTAssertEqual(chip.gradients.count % MemoryLayout<canvas.GradientDesc>.stride, 0)
    }

    func testTheChipIsDrawnFromItsOwnOrigin() throws {
        let editor = try openEditor()
        let chip = try XCTUnwrap(
            DragChipCapture.capture(
                view: Text("x")
                    .frame(width: .pt(60), height: .pt(20))
                    .background(Theme.current.panel),
                editor: editor
            )
        )
        let fills = commands(of: chip).filter {
            $0.kind == DrawKind.rect.rawValue || $0.kind == DrawKind.roundedRect.rawValue
        }
        let plate = try XCTUnwrap(fills.first, "the background is a fill")
        XCTAssertEqual(plate.x, 0, accuracy: 0.5)
        XCTAssertEqual(plate.y, 0, accuracy: 0.5)
        XCTAssertEqual(plate.w, 60, accuracy: 0.5)
        XCTAssertEqual(plate.h, 20, accuracy: 0.5)
    }

    func testAChipCannotGrowIntoAWindow() throws {
        let editor = try openEditor()
        let chip = try XCTUnwrap(
            DragChipCapture.capture(
                view: Text("wide")
                    .frame(width: .pt(4000), height: .pt(3000))
                    .background(Theme.current.panel),
                editor: editor
            )
        )
        XCTAssertLessThanOrEqual(Float(chip.width), DragChipCapture.maxSide)
        XCTAssertLessThanOrEqual(Float(chip.height), DragChipCapture.maxSide)
    }

    func testAChipThatDrawsNothingIsNoChip() throws {
        let editor = try openEditor()
        XCTAssertNil(DragChipCapture.capture(view: EmptyView(), editor: editor))
    }
}
