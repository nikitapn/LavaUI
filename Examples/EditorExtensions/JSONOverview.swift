import Foundation
import LavaEditorExtensionAPI
import LavaUI

private struct OverviewState: Codable {
    var snapshot: UUID? = UUID()
    var reversed = false
    var offset = 0
    var headerBottom: Float = 0

}

/// The activation ABI serializes calls to this library in each worker.
private final class OverviewRenderer: @unchecked Sendable {
    static let shared = OverviewRenderer()
    private lazy var editor = Editor.openClient()
    private var font: UIFont?

    // Keep only the most recently used source. Switching back to an evicted
    // preview (or starting a new worker) reconstructs it from its snapshot.
    private var tree: JSONTree?
    private var snapshot: UUID?

    func rows(for state: OverviewState, surface: EmbeddedSurfaceProvider, invocation: UInt64) async throws -> [JSONTree.Row] {
        if snapshot != state.snapshot || tree == nil {
            let document = try await surface.readDocument(invocation: invocation)
            tree = try JSONTree(text: document.text, descending: state.reversed)
            snapshot = state.snapshot
        } else {
            try tree?.order(descending: state.reversed)
        }
        return tree?.rows ?? []
    }

    func render(_ input: SurfaceRequest, state: inout OverviewState, rows: [JSONTree.Row]) throws -> SurfaceFrame {
        let viewport = input.viewport
        let size = Float(viewport.size26_6) / 64
        guard let editor, let hinting = FontHinting(rawValue: viewport.rasterFlags & 15) else {
            throw CocoaError(.coderInvalidValue)
        }
        if font?.contentDigest != viewport.fontSha256 || font?.path != viewport.fontPath || font?.pixelSize != size || font?.faceIndex != viewport.face ||
            font?.raster.raw != viewport.rasterFlags {
            font = UIFont(path: viewport.fontPath, pixelSize: size, faceIndex: viewport.face,
                          raster: FontRasterFlags(hinting: hinting, forceAutohint: viewport.rasterFlags & 16 != 0))
        }
        guard let font, font.contentDigest == viewport.fontSha256 else { throw CocoaError(.fileReadUnknown) }
        let pitch = max(24, font.lineHeight + 8)
        let top = pitch + 20
        let visibleCount = max(1, Int(ceil(max(0, viewport.height - top) / pitch)))
        state.offset = min(max(0, state.offset), max(0, rows.count - visibleCount))
        let visible = try rows.dropFirst(state.offset).prefix(visibleCount).map { row in
            (depth: row.depth, text: try row.text())
        }
        state.headerBottom = 8 + pitch
        let captured = DrawList.captureEmbedded(editor: editor, scale: viewport.scale) { list in
            let ink = Color(r: 0.14, g: 0.18, b: 0.20)
            list.rect(x: 0, y: 0, w: viewport.width, h: viewport.height, color: Color(r: 0.97, g: 0.97, b: 0.95))
            list.roundedRect(x: 12, y: 8, w: 184, h: pitch, color: Color(r: 0.80, g: 0.88, b: 0.84))
            list.text(state.reversed ? "Order: descending" : "Order: ascending", x: 17, y: 12, w: 176, h: pitch,
                      color: ink, font: font)
            list.image(textureId: 1, x: 173, y: 8 + (pitch - 9) / 2, w: 9, h: 9)
            var y = top
            // Bound shaping to the visible line; a JSON string can itself be megabytes.
            let columns = max(1, Int(viewport.width / max(1, font.pixelSize / 4)))
            for row in visible {
                let x = 12 + Float(row.depth) * 18
                if x < viewport.width {
                    let label = String(row.text.unicodeScalars.prefix(columns))
                    list.text(label, x: x, y: y, w: viewport.width - x, h: pitch, color: ink, font: font)
                }
                y += pitch
            }
        }
        var frame = SurfaceFrame()
        frame.viewportId = viewport.id
        frame.frameId = input.frameId
        frame.commands = captured.commands
        frame.glyphs = captured.glyphs
        // The sort arrow is a surface-local image, shared by all unchanged frames.
        var rgba = Array(repeating: UInt8(0), count: 9 * 9 * 4)
        for row in 0..<5 {
            let y = state.reversed ? 6 - row : row + 2
            for x in (4 - row)...(4 + row) {
                rgba.replaceSubrange((y * 9 + x) * 4..<(y * 9 + x + 1) * 4, with: [36, 46, 51, 255])
            }
        }
        frame.images = [SurfaceImage(id: 1, width: 9, height: 9, rgba: rgba)]
        frame.state = Array(try PropertyListEncoder().encode(state))
        return frame
    }

}

func renderOverview(_ reference: UnsafePointer<CChar>, invocation: UInt64) -> Int32 {
    runEmbeddedSurfaceProvider(reference) { surface in
        let input = try await surface.readRequest(invocation: invocation)
        var state: OverviewState
        if input.state.isEmpty {
            state = OverviewState()
        } else {
            state = try PropertyListDecoder().decode(OverviewState.self, from: Data(input.state))
        }
        if state.snapshot == nil { state.snapshot = UUID() }
        for event in input.events {
            switch event.kind {
            case .press where event.code == PointerButton.left && (12...196).contains(event.x) &&
                event.y >= 8 && event.y <= state.headerBottom:
                state.reversed.toggle()
            case .key where event.code == KeyCode.space: state.reversed.toggle()
            case .key where event.code == KeyCode.down: state.offset += 1
            case .key where event.code == KeyCode.up: state.offset -= 1
            case .wheel: state.offset -= Int(max(-256, min(256, event.dy * 3)))
            default: break
            }
            state.offset = max(0, state.offset)
        }
        let renderer = OverviewRenderer.shared
        let rows = try await renderer.rows(for: state, surface: surface, invocation: invocation)
        let frame = try renderer.render(input, state: &state, rows: rows)
        guard try await surface.submitFrame(invocation: invocation, frame: frame) else {
            throw CocoaError(.coderInvalidValue)
        }
    }
}
