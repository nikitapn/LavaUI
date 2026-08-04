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

/// The wire event, disambiguated from `LavaUI.InputEvent`.
///
/// They are field-for-field the same shape — that congruence is the point, and
/// it is also why neither module's name wins on its own. Spelling the wire one
/// out keeps every conversion site saying which side of the boundary it is on.
typealias WireInputEvent = LavaIDL.InputEvent

/// Transport the control plane runs over.
///
/// Shared memory is where this belongs and what it ships on: 7 µs a call
/// against TCP's 75 µs, nothing reachable from off-box, and access control
/// that is already the filesystem's.
///
/// WebSocket is here for one reason, and it is not deployment. NPRPC only
/// routes *server-initiated* stream chunks into a client's stream manager
/// where the client side of the connection is a full `Session` — which today
/// means WebSocket and QUIC. Over shm (and over TCP) a client connection is a
/// request/response read loop with no path for a chunk nobody asked for, so
/// `SubscribeInput` opens, the renderer writes, and the events land nowhere.
/// See `docs/nprpc-client-stream-gap.md`.
///
/// Switching this line is how you tell "the reverse channel is wrong" from
/// "the reverse channel has no road": on `.webSocket` everything below works
/// end to end, unchanged.
enum ControlTransport {
    case sharedMemory
    case webSocket
}

let controlTransport: ControlTransport = .sharedMemory

/// Only read when `controlTransport` is `.webSocket`. The certificates are
/// nprpc's own test pair — a compositor has no business terminating TLS, and
/// needing them at all is part of why shm is the destination.
let webSocketPort: UInt16 = 24243
let webSocketCertDirectory = "/home/nikita/projects/nprpc/certs/out"

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

/// Fans the window's input out to whoever is subscribed.
///
/// The renderer owns the window, so it owns the only mouse and keyboard in
/// the system; an app that draws into shared memory has no other way to learn
/// a pointer moved. This is the seam between the loop thread, which produces
/// events, and the RPC tasks, which write them out — the exact mirror of
/// `LoopQueue` going the other way.
///
/// Deliberately not a queue per event with a wakeup per event: a subscriber
/// gets an `AsyncStream`, which already has a buffer, a consumer that
/// suspends when it is empty, and a policy for what to do when it is full.
enum InputBroker {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var subscribers:
        [UInt64: AsyncStream<WireInputEvent>.Continuation] = [:]
    nonisolated(unsafe) private static var nextID: UInt64 = 1
    nonisolated(unsafe) private static var nextSerial: UInt32 = 0
    /// Replayed to every new subscriber — see `subscribe`.
    nonisolated(unsafe) private static var latestResize: WireInputEvent?
    nonisolated(unsafe) private static var boundArena: String?
    nonisolated(unsafe) private static var lastAck: UInt32 = 0

    /// A subscriber this far behind is not going to catch up by being sent
    /// more, and the newest pointer position is worth more than the oldest —
    /// so the buffer drops from the front. Four seconds of continuous motion
    /// at 120 Hz, which no client that is merely busy will ever reach.
    private static let bufferedEvents = 512

    static func bind(arenaId: String) {
        lock.lock()
        boundArena = arenaId
        lock.unlock()
    }

    static func isBound(_ arenaId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return boundArena == arenaId
    }

    /// Called on the loop thread, once per polled event.
    static func post(_ event: LavaUI.InputEvent) {
        lock.lock()
        nextSerial &+= 1
        let wire = WireInputEvent(
            serial: nextSerial, kind: event.kind.rawValue,
            x: event.x, y: event.y, button: event.button, mods: event.mods
        )
        if event.kind == .resize { latestResize = wire }
        let targets = Array(subscribers.values)
        lock.unlock()
        for target in targets { target.yield(wire) }
    }

    /// Synthesises a `Resize` without one having happened. The window has a
    /// size from the moment it opens, but GLFW only reports one when it
    /// changes — so without this a client would draw at a guessed size until
    /// the user happened to drag a border.
    static func postCurrentSize(width: Float, height: Float) {
        post(LavaUI.InputEvent(kind: .resize, x: width, y: height, button: 0, mods: 0))
    }

    /// The new subscriber's first event is the last `Resize` seen, so it
    /// learns its size from the stream rather than from a separate call that
    /// could race the first one.
    static func subscribe() -> (id: UInt64, events: AsyncStream<WireInputEvent>) {
        nonisolated(unsafe) var id: UInt64 = 0
        nonisolated(unsafe) var seed: WireInputEvent?
        let events = AsyncStream<WireInputEvent>(
            bufferingPolicy: .bufferingNewest(bufferedEvents)
        ) { continuation in
            // Runs synchronously inside the initializer, which is what makes
            // reading `id`/`seed` back out below well-defined.
            lock.lock()
            id = nextID
            nextID += 1
            subscribers[id] = continuation
            seed = latestResize
            lock.unlock()
            if let seed { continuation.yield(seed) }
        }
        return (id, events)
    }

    /// Idempotent: both halves of a subscription call this to tear the other
    /// one down, and whichever loses the race must be harmless.
    static func unsubscribe(_ id: UInt64) {
        lock.lock()
        let continuation = subscribers.removeValue(forKey: id)
        lock.unlock()
        continuation?.finish()
    }

    static func noteAck(_ serial: UInt32) {
        lock.lock()
        if serial > lastAck { lastAck = serial }
        lock.unlock()
    }

    /// Events sent but not yet acknowledged. The whole point of the reverse
    /// direction: without it "the app is idle" and "the app is wedged" look
    /// identical from here.
    static var lag: UInt32 {
        lock.lock()
        defer { lock.unlock() }
        return nextSerial &- lastAck
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
        let ok: Bool = LoopQueue.sync { [editor] in
            editor.attachDrawArena(id: arenaId)
        }
        guard ok else {
            var ex = ArenaNotFound()
            ex.arenaId = arenaId
            throw ex
        }
        // Input follows the arena: the window is now this client's surface, so
        // `SubscribeInput` will accept this id and refuse any other.
        InputBroker.bind(arenaId: arenaId)
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

    /// The reverse channel. Runs for as long as the client keeps the stream
    /// open, on NPRPC's own task, never on the loop.
    ///
    /// Both directions have to be serviced concurrently and neither may
    /// outlive the other. Reading is not optional even though the payload is
    /// nearly empty: consuming the reader is what returns window credits, so
    /// a servant that only wrote would stall at zero credits and never send
    /// another event.
    override func subscribeInput(
        arenaId: String, stream: NPRPCBidiStream<WireInputEvent, InputAck>
    ) async {
        guard InputBroker.isBound(arenaId) else {
            // A stream has no reply message to put an exception in, so the
            // failure has to be the stream's own: the client's `for try await`
            // throws instead of hanging on a subscription that will never
            // produce anything.
            stream.writer.abort()
            return
        }
        let (id, events) = InputBroker.subscribe()
        FileHandle.standardError.write(
            Data("SubscribeInput(\(arenaId)) — subscription \(id)\n".utf8)
        )

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    // Credit-gated: this suspends rather than queues when the
                    // client stops reading, which is what stops a slow app
                    // from turning into unbounded memory over here.
                    for await event in events {
                        try await stream.writer.write(event)
                    }
                    stream.writer.close()
                } catch {
                    stream.writer.abort()
                }
            }
            group.addTask {
                do {
                    for try await ack in stream.reader {
                        InputBroker.noteAck(ack.serial)
                    }
                } catch {
                    // A dead client throws here; that is the disconnect
                    // notice, not an error worth reporting.
                }
            }

            // Whichever side ends first ends the other: the writer stops when
            // its event stream finishes, the reader when its continuation is
            // cancelled. Cancelling the group would not do it — neither loop
            // is suspended at a cancellation-aware point.
            await group.next()
            InputBroker.unsubscribe(id)
            stream.reader.cancel()
            await group.waitForAll()
        }

        FileHandle.standardError.write(
            Data("SubscribeInput(\(arenaId)) — subscription \(id) ended\n".utf8)
        )
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
    // Exactly one listener, whichever `controlTransport` names. Advertising
    // both would settle nothing: a client offered a choice always takes shm,
    // so "use WebSocket" has to mean "publish only WebSocket".
    let rpc: Rpc
    switch controlTransport {
    case .sharedMemory:
        rpc = try RpcBuilder().setLogLevel(.warn).build()
    case .webSocket:
        rpc = try RpcBuilder().setLogLevel(.warn).withHostname("localhost")
            .withHttp(webSocketPort)
            .ssl(certFile: "\(webSocketCertDirectory)/localhost.crt",
                 keyFile: "\(webSocketCertDirectory)/localhost.key")
            .build()
    }
    try rpc.startThreadPool(2)

    let poa = try rpc.createPoa(
        maxObjects: 8, lifetime: .Persistent, idPolicy: .userSupplied
    )
    let servant = CompositorImpl(editor: editor)
    let oid = try poa.activateObjectWithId(
        objectId: 0, servant: servant,
        flags: controlTransport == .sharedMemory ? [.shm] : [.ws]
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

/// The app's end of `SubscribeInput`: an async stream on one side, a frame
/// loop that is not async on the other.
///
/// Same shape as `LoopQueue` in the other direction and for the same reason —
/// events arrive on an NPRPC thread, and the only thread allowed to touch the
/// arena is the one writing frames into it.
final class InputChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [WireInputEvent] = []
    private var ended = false
    private var received = false
    private let acks: AsyncStream<UInt32>.Continuation

    init(stream: NPRPCBidiStream<InputAck, WireInputEvent>) {
        // Depth one, because an ack is cumulative: "I have consumed through
        // N" makes every earlier ack redundant. Coalescing here is what keeps
        // a 120 Hz frame loop from putting 120 writes a second on the wire to
        // say something one write already said.
        let (serials, continuation) = AsyncStream<UInt32>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        acks = continuation

        Task.detached { [self] in
            do {
                for try await event in stream.reader { enqueue(event) }
            } catch {
                FileHandle.standardError.write(
                    Data("input stream ended: \(error)\n".utf8)
                )
            }
            finish()
            continuation.finish()
        }

        Task.detached {
            for await serial in serials {
                try? await stream.writer.write(InputAck(serial: serial))
            }
            stream.writer.close()
        }
    }

    private func enqueue(_ event: WireInputEvent) {
        lock.lock()
        queue.append(event)
        received = true
        lock.unlock()
    }

    /// False if not one event has ever arrived. Worth asking, because the
    /// difference between "nobody has touched the mouse" and "this transport
    /// has no route for server-initiated chunks" is otherwise invisible from
    /// here — the subscription opens either way. See `ControlTransport`.
    var hasReceivedAnything: Bool {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    private func finish() {
        lock.lock()
        ended = true
        lock.unlock()
    }

    /// True once the renderer has gone away — the app's cue to stop drawing
    /// frames nobody will read.
    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended
    }

    /// Everything that arrived since the last call. Acknowledges the batch,
    /// which is the honest moment to do it: the serial now means "consumed",
    /// not "received".
    func drain() -> [WireInputEvent] {
        lock.lock()
        let events = queue
        queue.removeAll(keepingCapacity: true)
        lock.unlock()
        if let last = events.last { acks.yield(last.serial) }
        return events
    }
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
    // wedged. Every servant method here hops to the render loop, so "no
    // answer" means the loop is stuck, and a client that waits forever for
    // that just becomes a second stuck process.
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
