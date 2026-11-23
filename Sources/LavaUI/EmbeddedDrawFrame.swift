import CxxCanvas

/// A validated subset of the native draw-list wire format for an embedded
/// producer. Resource IDs belong to the producer until replay.
public struct EmbeddedDrawFrame {
    let commands: [canvas.DrawCommand]
    let glyphs: [canvas.GlyphInstance]

    public init?(commands bytes: [UInt8], glyphs glyphBytes: [UInt8], imageIDs: Set<UInt32>) {
        guard bytes.count <= 32768 * 32, glyphBytes.count <= 65536 * 16,
              bytes.count.isMultiple(of: 32), glyphBytes.count.isMultiple(of: 16) else { return nil }
        func decode<T>(_ bytes: [UInt8], as: T.Type) -> [T] {
            bytes.withUnsafeBytes { buffer in
                stride(from: 0, to: buffer.count, by: MemoryLayout<T>.stride).map {
                    buffer.loadUnaligned(fromByteOffset: $0, as: T.self)
                }
            }
        }
        commands = decode(bytes, as: canvas.DrawCommand.self)
        glyphs = decode(glyphBytes, as: canvas.GlyphInstance.self)
        func coordinate(_ value: Float) -> Bool { abs(value) <= 1_048_576 }
        guard glyphs.allSatisfy({ $0.fontId == 0 && $0.glyphId <= 65535 && coordinate($0.x) && coordinate($0.y) }) else { return nil }
        var clipDepth = 0
        var nextGlyph = 0
        for c in commands {
            guard coordinate(c.x), coordinate(c.y), coordinate(c.w), coordinate(c.h), coordinate(c.aux),
                  let kind = DrawKind(rawValue: c.kind) else { return nil }
            switch kind {
            case .pushClip:
                clipDepth += 1
                // The native renderer reserves a zero-sized scissor for resetting the clip.
                // Nor a clip fixed to the window: an extension draws inside
                // its own box and has no window to fix anything to.
                guard clipDepth <= 8, c.w > 0, c.h > 0, c.param == 0 else { return nil }
            case .popClip:
                guard clipDepth > 0 else { return nil }
                clipDepth -= 1
            case .rect, .roundedRect:
                guard c.w >= 0, c.h >= 0, c.aux >= 0 else { return nil }
            case .strokedRect:
                guard c.w > 0, c.h > 0, c.aux >= 0, (1...0x00ff_ffff).contains(c.param) else { return nil }
            case .image:
                guard imageIDs.contains(c.param), c.w >= 0, c.h >= 0 else { return nil }
            case .text:
                guard let count = Int(exactly: c.w), count >= 0, Int(c.param) == nextGlyph else { return nil }
                nextGlyph += count
                guard nextGlyph <= glyphs.count else { return nil }
            default: return nil
            }
        }
        guard clipDepth == 0, nextGlyph == glyphs.count else { return nil }
    }
}

extension DrawList {
    /// Captures an immediate-mode paint pass in surface-local coordinates.
    /// A headless Editor.openClient() supplies the producer-side environment.
    public static func captureEmbedded(editor: Editor, scale: Float, paint: (DrawList) -> Void)
        -> (commands: [UInt8], glyphs: [UInt8]) {
        let sink = CapturedFrameSink()
        let list = DrawList(editor: editor, sink: sink)
        list.displayScale = scale
        list.clear()
        paint(list)
        list.publish()
        return sink.embeddedBytes()
    }
}
