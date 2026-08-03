#if canImport(CxxCanvas) && canImport(LavaIDL)
import Foundation
import LavaIDL
import LavaUI
import NPRPC

// The compositor's control plane: everything about a frame that is not the
// frame. Pixels go through the shared arena; this names the resources those
// pixels refer to, wires a window to a client's arena, and says when a frame
// is ready.
//
// Shared-memory NPRPC does a round trip in ~7 µs. Against a 16.7 ms frame that
// is 0.04%, which is why it is worth having a real interface here instead of
// inventing a protocol: the cost of a call is far below the cost of getting
// the hand-rolled version wrong.

/// Transport the control plane runs over Shared Memory

/// Loopback only. A compositor's control plane has no business being
/// reachable from off-box.
let controlPlanePort: UInt16 = 24242

/// Where the renderer publishes its object reference, and the client reads it.
///
/// A file rather than a nameserver: this is one machine, one desktop session,
/// and requiring a separate `npnameserver` process to start before the
/// compositor would be a deployment step in exchange for nothing. The IOR
/// string already carries the endpoint.
enum ControlPlane {
    static var referencePath: String {
        let base = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? "/tmp"
        return (base as NSString).appendingPathComponent("lava-compositor.ior")
    }
}

// ─── Renderer side ───────────────────────────────────────────────────────────

/// Work handed to the render loop from an NPRPC worker thread.
///
/// NPRPC dispatches on its own thread pool, and nothing the renderer owns is
/// thread-safe — the Vulkan device least of all. So a servant method does not
/// *do* anything; it queues the work, wakes the loop out of `pumpEvents`, and
/// waits for the answer. This is the same shape as LavaUI's `MainQueue`, which
/// exists for exactly this hazard, and the reason it has to exist here too is
/// that `ArenaDemo`'s host runs its own loop rather than `LavaApp.run`.
enum LoopQueue {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [() -> Void] = []
    nonisolated(unsafe) static var wake: (@Sendable () -> Void)?

    /// Runs `body` on the loop thread and returns its result. Blocks the
    /// calling (RPC) thread, never the loop.
    static func sync<T>(_ body: @escaping () -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        // `nonisolated(unsafe)` box: written on the loop thread, read here
        // after the semaphore, which is the ordering that makes it safe.
        nonisolated(unsafe) var result: T?
        lock.lock()
        pending.append {
            result = body()
            done.signal()
        }
        let wake = Self.wake
        lock.unlock()
        // Outside the lock: the wake reaches into GLFW, and holding a lock
        // across it would let an RPC thread block on the loop's own use of it.
        wake?()
        done.wait()
        return result!
    }

    /// Drained once per loop iteration, before anything is rendered.
    static func drain() {
        lock.lock()
        let work = pending
        pending.removeAll()
        lock.unlock()
        for item in work { item() }
    }
}

/// Serves `lava.Compositor` on behalf of the renderer.
final class CompositorImpl: CompositorServant, @unchecked Sendable {
    private let editor: Editor
    /// Set by `Present`, cleared by the loop. Not a count: two publishes
    /// between repaints are one frame's worth of work, because the arena only
    /// ever hands out the newest.
    nonisolated(unsafe) private static var frameReady = false
    private static let readyLock = NSLock()

    init(editor: Editor) {
        self.editor = editor
        super.init()
    }

    override func registerFont(path: String, pixelSize: Float) throws -> UInt32 {
        let id: UInt32? = LoopQueue.sync { [editor] in
            editor.registerFont(path: path, pixelSize: pixelSize)
        }
        guard let id else {
            var ex = FontNotFound()
            ex.path = path
            throw ex
        }
        let line = "RegisterFont(\(URL(fileURLWithPath: path).lastPathComponent), "
            + "\(pixelSize)) → \(id)\n"
        FileHandle.standardError.write(Data(line.utf8))
        return id
    }

    override func attachArena(arenaId: String) throws {
        FileHandle.standardError.write(Data("TRACE attachArena enter\n".utf8))
        let ok: Bool = LoopQueue.sync { [editor] in
            FileHandle.standardError.write(Data("TRACE attachArena on loop\n".utf8))
            return editor.attachDrawArena(id: arenaId)
        }
        guard ok else {
            var ex = ArenaNotFound()
            ex.arenaId = arenaId
            throw ex
        }
        FileHandle.standardError.write(Data("AttachArena(\(arenaId)) ok\n".utf8))
    }

    /// `[unreliable]` — no reply, so this must not block. It only flips a flag
    /// and unblocks the loop, both of which are safe off-thread
    /// (`wakeEventLoop` is documented thread-safe).
    override func present() {
        Self.readyLock.lock()
        Self.frameReady = true
        Self.readyLock.unlock()
        editor.wakeEventLoop()
    }

    /// Consumes the pending-frame flag. Called on the loop thread.
    static func takeFrameReady() -> Bool {
        readyLock.lock()
        defer { readyLock.unlock() }
        let was = frameReady
        frameReady = false
        return was
    }
}

/// Starts the control plane and publishes the reference. Returns the `Rpc` so
/// the caller keeps it alive for the process's lifetime.
func startCompositorService(editor: Editor) throws -> Rpc {
    // Shared memory only: no TCP listener, no TLS, nothing on the network.
    // A compositor's control plane has no business being reachable from
    // off-box, and shm is both the fastest transport here and the one whose
    // access control is already the filesystem's.
    let rpc = try RpcBuilder().setLogLevel(.warn).build()
    try rpc.startThreadPool(2)

    let poa = try rpc.createPoa(
        maxObjects: 8, lifetime: .Persistent, idPolicy: .userSupplied
    )
    let servant = CompositorImpl(editor: editor)
    let oid = try poa.activateObjectWithId(
        objectId: 0, servant: servant,
        flags: [.shm]
    )

    // The reference as a string: everything a client needs to reach this
    // object, including the shared-memory endpoint, in one line of text.
    guard let ior = NPRPCObject.fromObjectId(oid)?.toString() else {
        throw ControlPlaneError.classMismatch
    }
    try ior.write(
        toFile: ControlPlane.referencePath, atomically: true, encoding: .utf8
    )
    FileHandle.standardError.write(
        Data("compositor listening — reference at \(ControlPlane.referencePath)\n".utf8)
    )
    return rpc
}

// ─── App side ────────────────────────────────────────────────────────────────

/// Connects to the compositor. Returns the proxy plus the `Rpc` that owns its
/// transport, which the caller must keep alive.
func connectToCompositor() throws -> (Compositor, Rpc) {
    let ior = try String(contentsOfFile: ControlPlane.referencePath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let rpc = try RpcBuilder().setLogLevel(.warn).build()
    try rpc.startThreadPool(2)

    guard let object = NPRPCObject.fromString(ior) else {
        throw ControlPlaneError.badReference(ior)
    }
    // `fromString` hands back a reference with no endpoint chosen, unlike
    // `fromObjectId` which selects one for you.
    guard object.selectEndpoint() else {
        throw ControlPlaneError.noEndpoint(object.urls)
    }
    guard let compositor = narrow(object, to: Compositor.self) else {
        throw ControlPlaneError.classMismatch
    }
    return (compositor, rpc)
}

/// Runs an async RPC call to completion from synchronous code.
///
/// A render loop is not an async workflow and should not become one just to
/// make a call — but there is a sharper reason than taste. The generated
/// proxies are `async`, and `await`ing one from `main.swift`'s top level parks
/// the process on Swift's async-main executor. The continuation is then
/// resumed from an NPRPC worker thread and never gets to run, so the call
/// hangs forever: the request is delivered, the servant executes, and the
/// reply is stranded with nobody to hand it to. It looks exactly like a
/// broken transport, which is what makes it worth a comment.
///
/// `Task.detached` puts the await on the global concurrency pool, where
/// resuming it needs nobody's cooperation, and the semaphore hands the answer
/// back to the calling thread.
func blockingCall<T>(
    timeout: TimeInterval = 2, _ body: @escaping @Sendable () async throws -> T
) throws -> T {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var outcome: Result<T, Error>?
    Task.detached {
        do { outcome = .success(try await body()) }
        catch { outcome = .failure(error) }
        done.signal()
    }
    // Bounded, because a client must not be hostage to a compositor that is
    // wedged — and because it currently can be: over shared memory the
    // request is delivered and the servant runs, but the reply does not come
    // back. See the note on `connectToCompositor`.
    guard done.wait(timeout: .now() + timeout) == .success else {
        throw ControlPlaneError.timedOut
    }
    return try outcome!.get()
}

enum ControlPlaneError: Error, CustomStringConvertible {
    case badReference(String)
    case noEndpoint(String)
    case classMismatch
    case timedOut

    var description: String {
        switch self {
        case .badReference(let s): return "not a usable object reference: \(s)"
        case .noEndpoint(let urls): return "no usable endpoint among: \(urls)"
        case .classMismatch: return "reference is not a lava.Compositor"
        case .timedOut: return "the compositor did not answer"
        }
    }
}
#endif
