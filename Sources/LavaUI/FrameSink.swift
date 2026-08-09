import CxxCanvas
import Foundation

/// Element counts for one frame — used both for "how much fits" and for "how
/// much was written", because those two are compared constantly and one type
/// makes the comparison a line rather than four.
public struct FrameCapacity: Equatable, Sendable {
    public var commands = 0
    public var glyphs = 0
    public var meshVertices = 0
    public var spatialVertices = 0

    public init(
        commands: Int = 0, glyphs: Int = 0,
        meshVertices: Int = 0, spatialVertices: Int = 0
    ) {
        self.commands = commands
        self.glyphs = glyphs
        self.meshVertices = meshVertices
        self.spatialVertices = spatialVertices
    }
}

/// Where the frame being built actually lives.
public struct FrameBuffers {
    public var commands: UnsafeMutablePointer<canvas.DrawCommand>
    public var glyphs: UnsafeMutablePointer<canvas.GlyphInstance>
    public var meshVertices: UnsafeMutablePointer<canvas.MeshVertex>
    public var spatialVertices: UnsafeMutablePointer<canvas.SpatialVertex>
    public var capacity: FrameCapacity

    public init(
        commands: UnsafeMutablePointer<canvas.DrawCommand>,
        glyphs: UnsafeMutablePointer<canvas.GlyphInstance>,
        meshVertices: UnsafeMutablePointer<canvas.MeshVertex>,
        spatialVertices: UnsafeMutablePointer<canvas.SpatialVertex>,
        capacity: FrameCapacity
    ) {
        self.commands = commands
        self.glyphs = glyphs
        self.meshVertices = meshVertices
        self.spatialVertices = spatialVertices
        self.capacity = capacity
    }
}

/// Where a `DrawList` writes its frame, and who it hands the frame to.
///
/// Those are one question rather than two, and that is the whole point: the
/// property worth keeping is that a draw command is written **once**, into the
/// memory its consumer will read it from. A sink that only received a finished
/// list would have to copy it, and a 1 MB copy is 0.3 ms — 2% of a frame, for
/// something that should cost nothing. So a sink hands out the buffers first
/// and is told what was filled in afterwards.
///
/// Two of them, and the shapes match closely enough that `DrawList` needed no
/// new concepts to support the second:
///
/// - **In-process.** The buffers are the engine's own per-window vectors, and
///   `commit` is a submission the renderer picks up on its next repaint.
/// - **Shared memory.** The buffers are a slot in a `DrawArena` another
///   process reads, and `commit` publishes it. See `ArenaFrameSink`.
///
/// The mid-frame growth is not an optimization either, in either case: how
/// many commands a frame needs is not known when it starts, because `DrawList`
/// grows *during* emit as the tree turns out to be bigger than last time.
public protocol FrameSink: AnyObject {
    /// Claims buffers for a new frame with at least `minimum` room.
    ///
    /// Returns nil if none could be claimed, which `DrawList` treats as a
    /// frame that draws nothing rather than as an error — the next one will
    /// try again, and refusing to emit is better than emitting into memory
    /// somebody else is reading.
    func beginFrame(minimum: FrameCapacity) -> FrameBuffers?

    /// Enlarges mid-frame, preserving the `written` prefix and returning
    /// where it now lives.
    ///
    /// Takes `written` rather than reading it from anywhere because a growth
    /// may move the storage, and the part already filled in has to come with
    /// it. Returns nil if the sink could not grow, leaving the caller with
    /// the buffers it already had — a frame that has to finish smaller than
    /// it wanted, not a frame that is abandoned halfway.
    func grow(to wanted: FrameCapacity, written: FrameCapacity) -> FrameBuffers?

    /// Publishes what was written.
    func commit(_ written: FrameCapacity)
}

// ─── In-process ──────────────────────────────────────────────────────────────

/// The engine's own per-window buffers: what every windowed app uses, and the
/// default for any `DrawList` built against an `Editor`.
public final class EngineFrameSink: FrameSink {
    private unowned let editor: Editor
    private let window: WindowID
    /// The engine's vectors outlive a frame, so the pointers are re-read only
    /// when a growth may have reallocated them.
    private var buffers: FrameBuffers?

    public init(editor: Editor, window: WindowID) {
        self.editor = editor
        self.window = window
    }

    public func beginFrame(minimum: FrameCapacity) -> FrameBuffers? {
        if let buffers, buffers.capacity.fits(minimum) { return buffers }
        return refresh(ensuring: minimum)
    }

    public func grow(to wanted: FrameCapacity, written: FrameCapacity) -> FrameBuffers? {
        // `written` is not needed: `ensureDrawListCapacity` resizes vectors
        // that already hold the prefix, so nothing has to be carried across.
        // It stays in the signature because the shared-memory sink cannot make
        // that assumption, and a protocol shaped around the easy case would
        // not fit the one it exists for.
        refresh(ensuring: wanted)
    }

    public func commit(_ written: FrameCapacity) {
        editor.commitFrame(written, window: window)
    }

    private func refresh(ensuring wanted: FrameCapacity) -> FrameBuffers? {
        editor.ensureDrawListCapacity(
            commands: wanted.commands, glyphs: wanted.glyphs,
            meshVertices: wanted.meshVertices,
            spatialVertices: wanted.spatialVertices, window: window
        )
        let storage = editor.drawListStorage(window: window)
        let next = FrameBuffers(
            commands: storage.commands, glyphs: storage.glyphs,
            meshVertices: storage.meshVertices,
            spatialVertices: storage.spatialVertices,
            capacity: FrameCapacity(
                commands: storage.commandCapacity, glyphs: storage.glyphCapacity,
                meshVertices: storage.meshVertexCapacity,
                spatialVertices: storage.spatialVertexCapacity
            )
        )
        buffers = next
        return next
    }
}

// ─── Shared memory ───────────────────────────────────────────────────────────

/// Publishes frames into a `DrawArena` for a renderer in another process.
///
/// The producer creates the arena and the renderer attaches to it, so a client
/// makes one of these before asking for a surface — the compositor opens what
/// the producer made, which is what keeps the arena's capacity and geometry
/// the producer's business alone.
///
/// `onPublish` is called after each commit, on the frame loop's own thread.
/// It exists because a shared-memory store wakes nobody: the arena's published
/// sequence is the authority on what is current, but somebody still has to say
/// "come and look". That is `Compositor.Present`, and it stays out of here
/// because LavaUI does not know what a compositor is.
public final class ArenaFrameSink: FrameSink {
    private var arena = canvas.ipc.DrawArena()
    private var frame = canvas.ipc.ArenaFrame()
    private let onPublish: () -> Void

    /// Creates the arena named `id`. Returns nil if one by that name already
    /// exists, which is what stops two producers from writing over each other.
    public init?(
        id: String,
        capacity: FrameCapacity = FrameCapacity(
            commands: 1024, glyphs: 4096, meshVertices: 1024, spatialVertices: 1024
        ),
        onPublish: @escaping () -> Void = {}
    ) {
        self.onPublish = onPublish
        guard arena.create(std.string(id), capacity.arenaCapacity) else { return nil }
    }

    /// Name the renderer attaches by, and what the arena has grown to — both
    /// only for logging and tests.
    public var generation: UInt32 { arena.generation() }
    public var mappedBytes: Int { arena.mappedBytes() }

    public func beginFrame(minimum: FrameCapacity) -> FrameBuffers? {
        frame = arena.beginFrame()
        guard frame.valid else { return nil }
        guard let buffers = current else { return nil }
        guard !buffers.capacity.fits(minimum) else { return buffers }
        return grow(to: minimum, written: FrameCapacity())
    }

    public func grow(to wanted: FrameCapacity, written: FrameCapacity) -> FrameBuffers? {
        guard arena.growFrame(&frame, wanted.arenaCapacity, written.arenaCapacity)
        else { return nil }
        return current
    }

    public func commit(_ written: FrameCapacity) {
        guard frame.valid else { return }
        arena.commitFrame(frame, written.arenaCapacity)
        frame = canvas.ipc.ArenaFrame()
        onPublish()
    }

    /// The current slot as `FrameBuffers`. Nil only if the arena handed back a
    /// frame with a null array, which would be a bug in `DrawArena` rather
    /// than a state a producer can reach.
    private var current: FrameBuffers? {
        guard let commands = frame.commands, let glyphs = frame.glyphs,
              let mesh = frame.meshVertices, let spatial = frame.spatialVertices
        else { return nil }
        return FrameBuffers(
            commands: commands, glyphs: glyphs,
            meshVertices: mesh, spatialVertices: spatial,
            capacity: FrameCapacity(
                commands: Int(frame.capacity.commands),
                glyphs: Int(frame.capacity.glyphs),
                meshVertices: Int(frame.capacity.meshVertices),
                spatialVertices: Int(frame.capacity.spatialVertices)
            )
        )
    }
}

extension FrameCapacity {
    /// Element-wise "fits inside".
    public func fits(_ limit: FrameCapacity) -> Bool {
        commands >= limit.commands && glyphs >= limit.glyphs
            && meshVertices >= limit.meshVertices
            && spatialVertices >= limit.spatialVertices
    }

    var arenaCapacity: canvas.ipc.ArenaCapacity {
        var c = canvas.ipc.ArenaCapacity()
        c.commands = UInt32(max(0, commands))
        c.glyphs = UInt32(max(0, glyphs))
        c.meshVertices = UInt32(max(0, meshVertices))
        c.spatialVertices = UInt32(max(0, spatialVertices))
        return c
    }
}
