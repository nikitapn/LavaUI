#if canImport(CxxCanvas) && canImport(LavaIDL)
import Foundation
import LavaClient
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
    /// Set once, by the loop itself. Only read to answer "am I already
    /// there?" — see `sync`.
    nonisolated(unsafe) static var loopThread: Thread?

    /// Runs `body` on the loop thread and returns its result. Blocks the
    /// calling (RPC) thread, never the loop.
    static func sync<T>(_ body: @escaping () -> T) -> T {
        // Called *from* the loop, this has to run inline. Queueing would wait
        // for a drain that cannot happen until we return — a deadlock. It is
        // reachable for real: destroying a surface takes this path both from
        // an RPC thread and from the loop, when the user closes the window.
        if Thread.current === loopThread { return body() }

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

/// Fans one window's input out to whoever is subscribed to that surface.
///
/// The renderer owns the window, so it owns the only mouse and keyboard in
/// the system; an app that draws into shared memory has no other way to learn
/// a pointer moved. This is the seam between the loop thread, which produces
/// events, and the RPC tasks, which write them out — the exact mirror of
/// `LoopQueue` going the other way.
///
/// One per surface rather than one global: coordinates are window-relative,
/// so an event only means anything alongside the window it came from. A
/// shared broker would have to stamp every event with a surface id and make
/// every client filter — paying, on every client, to undo a mixing that never
/// needed to happen.
///
/// Deliberately not a queue per event with a wakeup per event: a subscriber
/// gets an `AsyncStream`, which already has a buffer, a consumer that
/// suspends when it is empty, and a policy for what to do when it is full.
final class InputBroker: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UInt64: AsyncStream<WireInputEvent>.Continuation] = [:]
    private var nextID: UInt64 = 1
    private var nextSerial: UInt32 = 0
    /// Replayed to every new subscriber — see `subscribe`.
    private var latestResize: WireInputEvent?
    private var lastAck: UInt32 = 0

    /// A subscriber this far behind is not going to catch up by being sent
    /// more, and the newest pointer position is worth more than the oldest —
    /// so the buffer drops from the front. Four seconds of continuous motion
    /// at 120 Hz, which no client that is merely busy will ever reach.
    private static let bufferedEvents = 512

    /// Called on the loop thread, once per polled event.
    func post(_ event: LavaUI.InputEvent) {
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
    func postCurrentSize(width: Float, height: Float) {
        post(LavaUI.InputEvent(kind: .resize, x: width, y: height, button: 0, mods: 0))
    }

    /// The new subscriber's first event is the last `Resize` seen, so it
    /// learns its size from the stream rather than from a separate call that
    /// could race the first one.
    func subscribe() -> (id: UInt64, events: AsyncStream<WireInputEvent>) {
        nonisolated(unsafe) var id: UInt64 = 0
        nonisolated(unsafe) var seed: WireInputEvent?
        let events = AsyncStream<WireInputEvent>(
            bufferingPolicy: .bufferingNewest(Self.bufferedEvents)
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
    func unsubscribe(_ id: UInt64) {
        lock.lock()
        let continuation = subscribers.removeValue(forKey: id)
        lock.unlock()
        continuation?.finish()
    }

    /// Ends every subscription at once — the surface is going away, so the
    /// streams that lease it end with it.
    func finishAll() {
        lock.lock()
        let all = Array(subscribers.values)
        subscribers.removeAll()
        lock.unlock()
        for continuation in all { continuation.finish() }
    }

    func noteAck(_ serial: UInt32) {
        lock.lock()
        if serial > lastAck { lastAck = serial }
        lock.unlock()
    }

    /// Events sent but not yet acknowledged. The whole point of the reverse
    /// direction: without it "the app is idle" and "the app is wedged" look
    /// identical from here.
    var lag: UInt32 {
        lock.lock()
        defer { lock.unlock() }
        return nextSerial &- lastAck
    }
}

/// One client's window: an arena to read from, a window to draw it in, and an
/// input stream going back.
final class Surface: @unchecked Sendable {
    let id: UInt32
    let window: WindowID
    let arenaId: String
    let title: String
    let input = InputBroker()
    /// Windows open hidden and are shown after their first frame — presenting
    /// a swapchain image that has never been rendered shows uninitialised
    /// memory, which looks like a flash of garbage. So a client that never
    /// publishes never gets a visible window, which is the right answer too.
    var shown = false

    init(id: UInt32, window: WindowID, arenaId: String, title: String) {
        self.id = id
        self.window = window
        self.arenaId = arenaId
        self.title = title
    }
}

/// Every surface this compositor has handed out.
///
/// Bookkeeping only — nothing here touches the engine, so it can be locked
/// briefly and called from any thread. The engine work (opening a window,
/// closing one) is `LoopQueue.sync`'d by the callers below.
enum SurfaceRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var surfaces: [UInt32: Surface] = [:]
    nonisolated(unsafe) private static var byWindow: [WindowID: UInt32] = [:]
    nonisolated(unsafe) private static var nextID: UInt32 = 1
    /// Windows whose contents have changed and need `renderFrame`. A set, not
    /// a count: two `Present`s between repaints are one frame's worth of work,
    /// because the arena only ever hands out the newest.
    nonisolated(unsafe) private static var dirty: Set<WindowID> = []
    /// Set once at startup. The registry needs it to close windows.
    nonisolated(unsafe) static var editor: Editor?

    static func allocateID() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    static func add(_ surface: Surface) {
        lock.lock()
        surfaces[surface.id] = surface
        byWindow[surface.window] = surface.id
        lock.unlock()
    }

    static func surface(id: UInt32) -> Surface? {
        lock.lock()
        defer { lock.unlock() }
        return surfaces[id]
    }

    static func surface(window: WindowID) -> Surface? {
        lock.lock()
        defer { lock.unlock() }
        guard let id = byWindow[window] else { return nil }
        return surfaces[id]
    }

    static var all: [Surface] {
        lock.lock()
        defer { lock.unlock() }
        return surfaces.values.sorted { $0.id < $1.id }
    }

    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return surfaces.count
    }

    /// Marks a surface's window for repaint, by surface id rather than by
    /// window.
    ///
    /// The resolve and the insert are one locked step on purpose. `Present`
    /// runs on an RPC thread while the loop can be destroying the same
    /// surface, and a two-step "look it up, then mark it" loses that race:
    /// the window closes in between and the loop renders a window that no
    /// longer exists. Under X that is not a soft failure — the request fails
    /// with `BadWindow` and Xlib's default handler exits the process.
    static func markDirty(surfaceId: UInt32) {
        lock.lock()
        if let surface = surfaces[surfaceId] { dirty.insert(surface.window) }
        lock.unlock()
    }

    /// Drained once per loop iteration. Whatever is in here gets redrawn.
    static func takeDirty() -> Set<WindowID> {
        lock.lock()
        defer { lock.unlock() }
        let was = dirty
        dirty.removeAll()
        return was
    }

    /// Ends a surface: its input streams finish, its window closes, its arena
    /// is released.
    ///
    /// Idempotent and callable from any thread, because it is reached three
    /// ways that can race: the client asking, the client's input stream
    /// ending, and the user closing the window.
    @discardableResult
    static func destroy(id: UInt32) -> Bool {
        lock.lock()
        guard let surface = surfaces.removeValue(forKey: id) else {
            lock.unlock()
            return false
        }
        byWindow.removeValue(forKey: surface.window)
        dirty.remove(surface.window)
        lock.unlock()

        // Ends the servant's `subscribeInput`, which is how the client hears
        // about it: its `for try await` finishes and its frame loop stops.
        surface.input.finishAll()

        if let editor {
            LoopQueue.sync {
                editor.detachDrawArena(window: surface.window)
                editor.closeWindow(surface.window)
            }
        }
        FileHandle.standardError.write(
            Data("surface \(id) (\(surface.title)) destroyed\n".utf8)
        )
        return true
    }
}

/// Serves `lava.Compositor` on behalf of the renderer.
final class CompositorImpl: CompositorServant, @unchecked Sendable {
    private let editor: Editor

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

    /// Opens, decodes and uploads the file itself — the client sends a path
    /// and never a bitmap.
    ///
    /// On the loop thread because the upload touches the Vulkan device. That
    /// makes a big first decode a stall in the compositor's frame, which is
    /// the honest cost of doing it here and is why `ImageStore` asks off the
    /// client's own critical path.
    override func registerImage(path: String, maxPixelSize: UInt32) throws -> ImageInfo {
        let key = ImageStore.key(path: path, maxPixelSize: maxPixelSize)

        // Idempotent per (path, maxPixelSize), answered without a decode or a
        // hop. That is not just an optimization: a desktop's second client
        // asking for an asset the first already has is the normal case, and
        // it should cost a lookup.
        imageKeyLock.lock()
        if let known = infoByKey[key] {
            usersByKey[key, default: 0] += 1
            imageKeyLock.unlock()
            return known
        }
        imageKeyLock.unlock()

        // Decoded *here*, on the RPC thread, and this is the point of the
        // split. `decodeImage` is documented thread-safe and touches no
        // device — it is also nearly all of the cost: measured at 5–17 ms per
        // cover against a round trip of about 7 µs. Doing it on the loop
        // meant a connecting client stalling the compositor's own window for
        // as long as it took to read its art.
        guard let decoded = Editor.decodeImage(path: path, maxPixelSize: maxPixelSize)
        else {
            var ex = ImageNotFound()
            ex.path = path
            throw ex
        }

        // Only the upload needs the device, so only the upload hops.
        let image: UIImage? = LoopQueue.sync { [editor] in
            editor.uploadImage(
                key: key, path: path, pixels: decoded.pixels,
                width: decoded.width, height: decoded.height
            )
        }
        guard let image else {
            var ex = ImageNotFound()
            ex.path = path
            throw ex
        }

        var info = ImageInfo()
        info.id = image.textureId
        info.width = UInt32(image.pixelWidth)
        info.height = UInt32(image.pixelHeight)

        imageKeyLock.lock()
        infoByKey[key] = info
        usersByKey[key, default: 0] += 1
        // Keyed by the id the client will use, so `ReleaseImage` needs no
        // agreement between the two sides about how a cache key is spelled.
        keysByImageID[info.id] = key
        imageKeyLock.unlock()

        let line = "RegisterImage(\(URL(fileURLWithPath: path).lastPathComponent), "
            + "max \(maxPixelSize)) → \(info.id) \(info.width)×\(info.height)\n"
        FileHandle.standardError.write(Data(line.utf8))
        return info
    }

    override func releaseImage(id: UInt32) {
        // An id this compositor never handed out, or has already released, is
        // a client that lost track rather than an error — see the IDL.
        imageKeyLock.lock()
        guard let key = keysByImageID[id] else {
            imageKeyLock.unlock()
            return
        }
        // Counted, because the registration above hands two clients the same
        // id without uploading twice — so the engine's own refcount saw one
        // user where there are two, and the first release would free a
        // texture the second is still drawing. Counting here is where the
        // policy belongs: sharing between clients is the compositor's
        // business, not the engine's.
        //
        // A client that registers twice and releases once leaks its texture
        // until it exits. That is the safe direction to be wrong in, and
        // fixing it properly means per-client accounting, which wants the
        // surface identity this call does not carry.
        let remaining = (usersByKey[key] ?? 1) - 1
        usersByKey[key] = max(0, remaining)
        guard remaining <= 0 else {
            imageKeyLock.unlock()
            return
        }
        usersByKey.removeValue(forKey: key)
        infoByKey.removeValue(forKey: key)
        keysByImageID.removeValue(forKey: id)
        imageKeyLock.unlock()
        LoopQueue.sync { [editor] in editor.releaseImage(key: key) }
    }

    /// Texture id → the cache key the engine knows it by. Touched from RPC
    /// threads, so it carries its own lock; the engine calls it guards are
    /// still made on the loop.
    private let imageKeyLock = NSLock()
    private var keysByImageID: [UInt32: String] = [:]
    /// What has already been registered, and how many clients hold it.
    private var infoByKey: [String: ImageInfo] = [:]
    private var usersByKey: [String: Int] = [:]

    /// Opens a window for this client and points it at the client's arena.
    ///
    /// The window and the attach happen together, under one hop to the loop:
    /// a window with no arena has nothing to draw, and there is no useful
    /// state between the two for anyone to observe.
    override func createSurface(
        arenaId: String, width: UInt32, height: UInt32, title: String
    ) throws -> UInt32 {
        let opened: WindowID? = LoopQueue.sync { [editor] in
            guard let window = editor.openWindow(
                width: Float(width), height: Float(height), title: title
            ) else { return nil }
            guard editor.attachDrawArena(id: arenaId, window: window) else {
                // The arena is the whole reason for the window, so a window
                // that cannot have one must not outlive the attempt.
                editor.closeWindow(window)
                return nil
            }
            return window
        }
        guard let window = opened else {
            var ex = ArenaNotFound()
            ex.arenaId = arenaId
            throw ex
        }

        let surface = Surface(
            id: SurfaceRegistry.allocateID(), window: window,
            arenaId: arenaId, title: title
        )
        // Seeded before anyone can subscribe, so the first event a client ever
        // sees is its real size rather than the size it asked for — which the
        // window manager was free to ignore.
        let size = LoopQueue.sync { [editor] in editor.framebufferSize(window: window) }
        surface.input.postCurrentSize(width: size.w, height: size.h)
        SurfaceRegistry.add(surface)

        let line = "CreateSurface(\(arenaId), \"\(title)\") → surface \(surface.id) "
            + "at \(Int(size.w))×\(Int(size.h))\n"
        FileHandle.standardError.write(Data(line.utf8))
        return surface.id
    }

    override func destroySurface(surfaceId: UInt32) throws {
        guard SurfaceRegistry.destroy(id: surfaceId) else {
            var ex = SurfaceNotFound()
            ex.surfaceId = surfaceId
            throw ex
        }
    }

    /// `[unreliable]` — no reply, so this must not block. It only marks a
    /// window dirty and unblocks the loop, both of which are safe off-thread
    /// (`wakeEventLoop` is documented thread-safe).
    ///
    /// An unknown surface is dropped rather than reported: there is no reply
    /// to report it in, and it is what a client racing its own
    /// `DestroySurface` legitimately produces.
    override func present(surfaceId: UInt32) {
        SurfaceRegistry.markDirty(surfaceId: surfaceId)
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
        surfaceId: UInt32, stream: NPRPCBidiStream<WireInputEvent, InputAck>
    ) async throws {
        // Thrown *before* the stream is touched, which is what makes it a
        // stream-initialization failure: the client's `subscribeInput` call
        // itself throws `SurfaceNotFound`, rather than the caller discovering
        // one chunk later that the subscription it just built is dead.
        guard let surface = SurfaceRegistry.surface(id: surfaceId) else {
            var ex = SurfaceNotFound()
            ex.surfaceId = surfaceId
            throw ex
        }
        let broker = surface.input
        let (id, events) = broker.subscribe()
        FileHandle.standardError.write(
            Data("SubscribeInput(surface \(surfaceId)) — subscription \(id)\n".utf8)
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
                        broker.noteAck(ack.serial)
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
            broker.unsubscribe(id)
            stream.reader.cancel()
            await group.waitForAll()
        }

        FileHandle.standardError.write(
            Data("SubscribeInput(surface \(surfaceId)) — subscription \(id) ended\n".utf8)
        )

        // The subscription was the surface's lease, so it ends with it. This
        // is the path a crashed client takes: nobody calls `DestroySurface`,
        // the stream simply stops, and the window goes rather than staying on
        // screen with nothing left to draw into it.
        //
        // Harmless when the surface is already gone — `destroy` is idempotent,
        // and the common case is that this *is* the teardown that ended us.
        SurfaceRegistry.destroy(id: surfaceId)
    }
}

/// Starts the control plane and publishes the reference. Returns the `Rpc` so
/// the caller keeps it alive for the process's lifetime.
func startCompositorService(editor: Editor) throws -> Rpc {
    SurfaceRegistry.editor = editor
    let rpc: Rpc = try RpcBuilder().setLogLevel(.warn).build()
    // One thread per concurrent client conversation, plus room for the input
    // streams, which run for as long as their surfaces do.
    try rpc.startThreadPool(4)

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

#endif
