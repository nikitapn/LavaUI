#if canImport(CxxCanvas)
import CxxCanvas
import CanvasResources
import Foundation
import LavaUI
#if canImport(LavaIDL)
import LavaIDL
import NPRPC
#endif

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
// The control plane is NPRPC over shared memory (`idl/lava.npidl`): the app
// asks the renderer to name a font, hands it the arena to read, and tells it
// when a frame is ready. That last call is `[unreliable]` — fire and forget —
// which is what lets the renderer *block* instead of polling: a shared-memory
// store wakes nobody, so without a nudge the renderer has no way to learn a
// frame arrived.
//
// Built without nprpc checked out, both halves still run: the font id falls
// back to a convention and the renderer polls. That fallback is what this
// looked like before the control plane existed.

let mode = CommandLine.arguments.dropFirst().first ?? "host"
let arenaID = "demo"

let fontPath = (LavaResources.fontsDirectory as NSString)
    .appendingPathComponent("OpenSans-Regular.ttf")
let fontPixelSize: Float = 20

/// Font id the producer stamps into every `GlyphInstance`.
///
/// Answered by `Compositor.RegisterFont` when the control plane is available.
/// The fallback is the convention this demo used before that existed: the
/// renderer registers this face first, so it lands at 0.
nonisolated(unsafe) var sharedFontID: UInt32 = 0

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

#if canImport(LavaIDL)
    // Both the font id and the arena now arrive over RPC, so the renderer
    // registers nothing up front and waits to be told.
    LoopQueue.wake = { [editor] in editor.wakeEventLoop() }
    do {
        rpcRuntime = try startCompositorService(editor: editor)
    } catch {
        FileHandle.standardError.write(Data("control plane failed: \(error)\n".utf8))
        exit(1)
    }

    while editor.isOpen {
        // Blocks until something happens: input, or a client's `Present`
        // waking us through `LoopQueue`/`wakeEventLoop`. No frame clock, no
        // poll — an idle desktop costs nothing.
        editor.pumpEvents(timeout: -1)

        // Servant work first: a `RegisterFont` that arrived while we were
        // parked belongs to the frame about to be drawn.
        LoopQueue.drain()

        // Drain input so the window stays responsive even though nothing here
        // acts on it — forwarding these to the client is the next piece.
        while editor.pollInputEvent() != nil {}

        // Repaint on a published frame, and also on any other wake, since a
        // resize or expose has to redraw what the arena already holds.
        _ = CompositorImpl.takeFrameReady()
        editor.renderFrame()
    }
#else
    // No control plane: the pre-RPC behaviour. Register the face first so it
    // lands at the id the producer assumes, and poll for the arena.
    guard let id = editor.registerFont(path: fontPath, pixelSize: fontPixelSize) else {
        FileHandle.standardError.write(Data("failed to register \(fontPath)\n".utf8))
        exit(1)
    }
    if id != sharedFontID {
        FileHandle.standardError.write(
            Data("warning: font registered as \(id), producer assumes \(sharedFontID)\n".utf8)
        )
    }
    var attached = editor.attachDrawArena(id: arenaID)
    var lastAttempt = Date.distantPast
    while editor.isOpen {
        editor.pumpEvents(timeout: 1.0 / 120.0)
        if !attached, Date().timeIntervalSince(lastAttempt) > 0.5 {
            lastAttempt = Date()
            attached = editor.attachDrawArena(id: arenaID)
        }
        while editor.pollInputEvent() != nil {}
        editor.renderFrame()
    }
#endif
}

// ─── App ─────────────────────────────────────────────────────────────────────

/// Producer-side engine state. File scope rather than borrowed into
/// `FrameWriter`: both are used for the life of the process, and handing a
/// struct a pointer to a local would outlive the local it points at.
nonisolated(unsafe) var arena = canvas.ipc.DrawArena()
nonisolated(unsafe) var font = canvas.Font()

#if canImport(LavaIDL)
/// The `Rpc` owns the transport — the shared-memory listener, its ring
/// buffers, the worker threads. Held at file scope because ARC releases a
/// local at its *last use*, not at end of scope, so binding it to `_` inside a
/// function tears the whole runtime down immediately: the listener stops, the
/// ring buffers are unlinked, and the next call through a proxy that outlived
/// it segfaults.
nonisolated(unsafe) var rpcRuntime: Rpc?
#endif

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

#if canImport(LavaIDL)
    // Order matters: the arena has to exist before `AttachArena`, because the
    // renderer opens what the producer made. Registering the font first is
    // free either way and gets the id every glyph below is stamped with.
    var compositorOpt: Compositor?
    do {
        let (compositor, rpc) = try connectToCompositor()
        rpcRuntime = rpc
        sharedFontID = try blockingCall {
            try await compositor.registerFont(path: fontPath, pixelSize: fontPixelSize)
        }
        try blockingCall { try await compositor.attachArena(arenaId: arenaID) }
        compositorOpt = compositor
        FileHandle.standardError.write(
            Data("control plane up — font id \(sharedFontID)\n".utf8)
        )
    } catch {
        FileHandle.standardError.write(
            Data("no compositor (\(error)) — is the host running?\n".utf8)
        )
        exit(1)
    }
    let compositor = compositorOpt
#endif

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
#if canImport(LavaIDL)
        // Fire and forget. The arena's published sequence already says what is
        // current, so a dropped nudge costs a frame of latency and never a
        // frame of content — which is exactly what `[unreliable]` is for.
        if let compositor {
            // Not awaited: `[unreliable]` has no reply to wait for, and a
            // frame loop should not pay a scheduling round trip to say "go".
            Task.detached { await compositor.present() }
        }
#endif
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
