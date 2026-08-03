#if canImport(CxxCanvas)
import CxxCanvas
import CanvasResources
import Foundation
import LavaUI

// One renderer process, one app process, one shared arena between them.
//
//   terminal 1:  swift run -c release ArenaDemo host
//   terminal 2:  swift run -c release ArenaDemo produce
//
// The producer owns no GPU, no window and no Vulkan. It shapes text with
// HarfBuzz — which is why `canvas::Font` deliberately "doesn't know Vulkan
// exists" — writes draw commands straight into shared memory, and publishes.
// The renderer maps the same memory and draws it. Nothing is copied on either
// side of the boundary: the bytes the producer writes are the bytes the
// renderer reads.
//
// What this slice does *not* have yet is a control plane, and the seam shows
// in exactly one place: both processes have to agree on a font id. The
// renderer registers the face first so it gets id 0, and the producer assumes
// that. Everything else — geometry, colour, glyph positions — is carried in
// the arena itself.

let mode = CommandLine.arguments.dropFirst().first ?? "host"
let arenaID = "demo"

/// The one thing the two processes agree on out of band. A `registerFont`
/// round trip over the control plane replaces this.
let fontPath = (LavaResources.fontsDirectory as NSString)
    .appendingPathComponent("OpenSans-Regular.ttf")
let fontPixelSize: Float = 20
let sharedFontID: UInt32 = 0

// ─── Renderer ────────────────────────────────────────────────────────────────

func runHost() {
    guard let editor = Editor.open(
        assetsRoot: CanvasResources.engineRoot,
        width: 720, height: 480,
        title: "ArenaDemo · renderer"
    ) else {
        FileHandle.standardError.write(Data("failed to open the window\n".utf8))
        exit(1)
    }

    // First registration, so this face is id 0 — the number the producer
    // assumes. The renderer rasterizes and atlases these glyphs on demand;
    // the producer only ever names them.
    guard let id = editor.registerFont(path: fontPath, pixelSize: fontPixelSize) else {
        FileHandle.standardError.write(Data("failed to register \(fontPath)\n".utf8))
        exit(1)
    }
    if id != sharedFontID {
        FileHandle.standardError.write(
            Data("warning: font registered as \(id), producer assumes \(sharedFontID)\n".utf8)
        )
    }

    // The producer has to have created the arena first — attaching is the
    // side that opens, not the side that makes.
    var attached = editor.attachDrawArena(id: arenaID)
    if !attached {
        FileHandle.standardError.write(
            Data("waiting for a producer on arena '\(arenaID)'…\n".utf8)
        )
    }

    var lastAttempt = Date.distantPast
    while editor.isOpen {
        // Poll rather than block: the producer's publish is a shared-memory
        // store, and nothing about it wakes GLFW. A frame-paced tick is the
        // honest placeholder until the control plane can carry a wakeup.
        editor.pumpEvents(timeout: 1.0 / 120.0)

        if !attached, Date().timeIntervalSince(lastAttempt) > 0.5 {
            lastAttempt = Date()
            attached = editor.attachDrawArena(id: arenaID)
            if attached {
                FileHandle.standardError.write(Data("producer attached\n".utf8))
            }
        }

        // Drain input so the window stays responsive even though nothing here
        // acts on it — the reverse channel that would forward these to the
        // producer is the next piece of work.
        while editor.pollInputEvent() != nil {}

        editor.renderFrame()
    }
}

// ─── App ─────────────────────────────────────────────────────────────────────

/// Producer-side engine state. File scope rather than borrowed into
/// `FrameWriter`: both are used for the life of the process, and handing a
/// struct a pointer to a local would outlive the local it points at.
nonisolated(unsafe) var arena = canvas.ipc.DrawArena()
nonisolated(unsafe) var font = canvas.Font()

func runProducer() {
    guard font.load(std.string(fontPath), fontPixelSize).has_value() else {
        FileHandle.standardError.write(Data("failed to load \(fontPath)\n".utf8))
        exit(1)
    }

    // Deliberately tiny, so the growth path runs in the first few seconds
    // rather than only under a pathological UI. A real producer would start
    // at `kDefaultArenaCapacity`.
    var capacity = canvas.ipc.ArenaCapacity()
    capacity.commands = 8
    capacity.glyphs = 64
    capacity.meshVertices = 8
    capacity.spatialVertices = 8
    guard arena.create(std.string(arenaID), capacity) else {
        FileHandle.standardError.write(
            Data("failed to create arena '\(arenaID)' — is one already running?\n".utf8)
        )
        exit(1)
    }
    FileHandle.standardError.write(
        Data("arena '\(arenaID)' created (\(arena.mappedBytes() / 1024) KiB)\n".utf8)
    )

    let start = Date()
    var frame = 0
    while true {
        let t = Float(Date().timeIntervalSince(start))
        var writer = FrameWriter()
        guard writer.begin() else { break }

        writer.rect(x: 0, y: 0, w: 720, h: 480, color: 0xff2b2b33)

        // A bar chart whose bar count grows with time, so the command count
        // climbs past the initial capacity and forces the arena to grow
        // mid-frame — the case a ring buffer cannot serve, and the reason
        // this is a mapping.
        let bars = 3 + Int(t) % 22
        for i in 0..<bars {
            let phase = t * 1.6 + Float(i) * 0.35
            let h = 40 + 120 * (0.5 + 0.5 * sin(phase))
            let x = 40 + Float(i) * 28
            writer.rect(x: x, y: 400 - h, w: 20, h: h, color: barColor(i))
        }

        writer.text("draw list written by pid \(getpid())", x: 40, y: 60)
        writer.text("frame \(frame) · \(bars) bars · generation \(arena.generation())",
                    x: 40, y: 92)
        writer.text("this process has no GPU and no window", x: 40, y: 124)

        writer.commit()
        frame += 1
        if frame % 120 == 0 {
            let line = "frame \(frame): generation \(arena.generation()), "
                + "\(arena.mappedBytes() / 1024) KiB\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        Thread.sleep(forTimeInterval: 1.0 / 60.0)
    }
}

private func barColor(_ i: Int) -> UInt32 {
    let palette: [UInt32] = [
        0xff7dd3fc, 0xffa78bfa, 0xfff9a8d4, 0xfffcd34d, 0xff86efac,
    ]
    return palette[i % palette.count]
}

/// Writes one frame into the arena, growing it when an append does not fit.
///
/// The growth check is per append rather than up front for the same reason
/// `DrawList` grows during emit: how many commands a frame needs is not known
/// until it has been emitted.
private struct FrameWriter {
    var frame = canvas.ipc.ArenaFrame()
    var commands = 0
    var glyphs = 0

    mutating func begin() -> Bool {
        frame = arena.beginFrame()
        return frame.valid
    }

    /// Asks for room for `moreCommands`/`moreGlyphs`, growing if needed.
    /// Returns false only when growth itself failed, in which case the caller
    /// silently drops what would not fit.
    private mutating func reserve(commands moreCommands: Int, glyphs moreGlyphs: Int) -> Bool {
        let needCommands = UInt32(commands + moreCommands)
        let needGlyphs = UInt32(glyphs + moreGlyphs)
        if needCommands <= frame.capacity.commands, needGlyphs <= frame.capacity.glyphs {
            return true
        }
        var atLeast = canvas.ipc.ArenaCapacity()
        atLeast.commands = needCommands
        atLeast.glyphs = needGlyphs
        var written = canvas.ipc.ArenaCapacity()
        written.commands = UInt32(commands)
        written.glyphs = UInt32(glyphs)
        return arena.growFrame(&frame, atLeast, written)
    }

    mutating func rect(x: Float, y: Float, w: Float, h: Float, color: UInt32) {
        guard reserve(commands: 1, glyphs: 0) else { return }
        var cmd = canvas.DrawCommand()
        cmd.kind = 0  // Rect
        cmd.x = x
        cmd.y = y
        cmd.w = w
        cmd.h = h
        cmd.color = color
        frame.commands[commands] = cmd
        commands += 1
    }

    /// Shapes and appends a run. The renderer never sees the string — only
    /// glyph ids and pen positions, which is what lets it rasterize into a
    /// shared atlas without knowing what any client is saying.
    mutating func text(_ string: String, x: Float, y: Float, color: UInt32 = 0xffe8e8ef) {
        let n = Int(font.prepareShape(std.string(string)))
        guard n > 0 else { return }
        var shaped = [canvas.PositionedGlyph](
            repeating: canvas.PositionedGlyph(), count: n
        )
        let written = shaped.withUnsafeMutableBufferPointer {
            Int(font.copyShapedGlyphs($0.baseAddress, Int32(n)))
        }
        guard written > 0 else { return }
        guard reserve(commands: 1, glyphs: written) else { return }

        let first = glyphs
        for i in 0..<written {
            var gi = canvas.GlyphInstance()
            gi.glyphId = shaped[i].glyphId
            gi.fontId = sharedFontID
            gi.x = x + shaped[i].x
            gi.y = y + shaped[i].y
            frame.glyphs[first + i] = gi
        }
        glyphs += written

        var cmd = canvas.DrawCommand()
        cmd.kind = 2  // Text
        cmd.param = UInt32(first)
        cmd.w = Float(written)
        cmd.color = color
        frame.commands[commands] = cmd
        commands += 1
    }

    mutating func commit() {
        var written = canvas.ipc.ArenaCapacity()
        written.commands = UInt32(commands)
        written.glyphs = UInt32(glyphs)
        arena.commitFrame(frame, written)
    }
}

switch mode {
case "host": runHost()
case "produce", "producer": runProducer()
default:
    FileHandle.standardError.write(Data("usage: ArenaDemo [host|produce]\n".utf8))
    exit(2)
}
#else
print("ArenaDemo needs the CxxCanvas engine.")
#endif
