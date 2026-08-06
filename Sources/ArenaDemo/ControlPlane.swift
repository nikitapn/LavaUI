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
/// Nothing the renderer owns is thread-safe — the Vulkan device least of all —
/// so work that touches it has to reach the loop thread. This is the same
/// shape as LavaUI's `MainQueue`, and it exists separately here because
/// `ArenaDemo`'s host runs its own loop rather than `LavaApp.run`.
///
/// It is also the POA's dispatch target (see `PoaExecutor` and
/// `startCompositorService`), which is what makes the servant methods below
/// plain code: they are *already* on the loop by the time they run, and the
/// queueing is NPRPC's rather than something each of them has to remember.
///
/// Nothing here waits. There used to be a `sync` — enqueue plus a semaphore —
/// and every caller of it has become either a servant method (already on the
/// loop) or a teardown that has no reason to watch the window close. Waiting
/// on the loop from a Task is also the one shape that can deadlock now that
/// the loop can wait on the concurrency pool; see `SurfaceRegistry.destroy`.
enum LoopQueue {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [@Sendable () -> Void] = []
    nonisolated(unsafe) static var wake: (@Sendable () -> Void)?
    /// Set once, by the loop itself. Only read to answer "am I already
    /// there?" — see `LoopExecutor.isRunningOnExecutor`.
    nonisolated(unsafe) static var loopThread: Thread?

    /// Enqueues work and wakes the loop to run it.
    static func post(_ body: @escaping @Sendable () -> Void) {
        lock.lock()
        pending.append(body)
        let wake = Self.wake
        lock.unlock()
        // Outside the lock: the wake reaches into GLFW, and holding a lock
        // across it would let an RPC thread block on the loop's own use of it.
        wake?()
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

/// `LoopQueue` as NPRPC sees it.
///
/// An object rather than the enum because the POA holds a reference; there is
/// no state here beyond the identity. See `PoaExecutor` — the contract is
/// exactly what `LoopQueue` already did for its own callers: enqueue, wake,
/// and answer honestly whether we are already on the loop.
final class LoopExecutor: PoaExecutor {
    static let shared = LoopExecutor()
    private init() {}

    func post(_ work: @escaping @Sendable () -> Void) { LoopQueue.post(work) }
    var isRunningOnExecutor: Bool { Thread.current === LoopQueue.loopThread }
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
/// closing one) happens on the loop: for the servant methods because that is
/// where they run, and for `destroy` because it posts.
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

        // Posted, not waited on. Nobody needs the window gone before this
        // returns — the bookkeeping above already happened, so the surface is
        // unreachable and `markDirty` can no longer name it — and one of the
        // three callers is a Task on the concurrency pool. Blocking a pool
        // thread on the loop is what would let a busy teardown and a new
        // `SubscribeInput` wait on each other: stream dispatch parks the loop
        // until its body starts, and its body needs a pool thread to start on.
        if let editor {
            LoopQueue.post {
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
///
/// Every method here runs **on the render loop** — that is the POA's dispatch
/// policy, not a convention (see `startCompositorService`). So the engine can
/// be called directly, and the thing that used to be easy to get wrong is now
/// impossible to express.
///
/// The cost is stated where it lands, in `registerImage`: work that does *not*
/// need the device no longer has a thread to go to, because dispatch placement
/// is a property of the POA and not of the method.
final class CompositorImpl: CompositorServant, @unchecked Sendable {
    private let editor: Editor

    init(editor: Editor) {
        self.editor = editor
        super.init()
    }

    override func registerFont(path: String, pixelSize: Float) throws -> UInt32 {
        let id = editor.registerFont(path: path, pixelSize: pixelSize)
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
    /// The one method that pays for the POA's dispatch policy. A decode is
    /// 5–17 ms per cover, needs no device, and used to run on the RPC thread
    /// while the loop kept drawing; now it runs on the loop, because the loop
    /// is where this method runs and a servant cannot hand part of itself to
    /// another thread without blocking for the answer anyway.
    ///
    /// What keeps that from mattering is the lookup below: a decode happens
    /// the first time this compositor ever sees an asset, and never again. A
    /// desktop pays a few dropped frames once per image per boot, and every
    /// subsequent client — the normal case — gets a dictionary lookup.
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

        guard let decoded = Editor.decodeImage(path: path, maxPixelSize: maxPixelSize)
        else {
            var ex = ImageNotFound()
            ex.path = path
            throw ex
        }

        let image = editor.uploadImage(
            key: key, path: path, pixels: decoded.pixels,
            width: decoded.width, height: decoded.height
        )
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
        editor.releaseImage(key: key)
    }

    /// Texture id → the cache key the engine knows it by.
    ///
    /// The lock is uncontended now that both methods that touch these run on
    /// the loop, and it stays because that is a fact about the POA rather than
    /// about this class — the day one of them is answered somewhere else, the
    /// bookkeeping should not be what breaks.
    private let imageKeyLock = NSLock()
    private var keysByImageID: [UInt32: String] = [:]
    /// What has already been registered, and how many clients hold it.
    private var infoByKey: [String: ImageInfo] = [:]
    private var usersByKey: [String: Int] = [:]

    /// Opens a window for this client and points it at the client's arena.
    ///
    /// The window and the attach are one step: a window with no arena has
    /// nothing to draw, and there is no useful state between the two for
    /// anyone to observe. Being on the loop is what lets them stay one step.
    override func createSurface(
        arenaId: String, width: UInt32, height: UInt32, title: String
    ) throws -> UInt32 {
        let opened: WindowID? = {
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
        }()
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
        let size = editor.framebufferSize(window: window)
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

    /// The display server's selection, read on the loop like everything else.
    ///
    /// `editor.clipboardText` goes to GLFW, which goes to X11, and on X11 a
    /// read is a round trip to whichever process owns the selection — so this
    /// can park the render loop for as long as that process takes to answer.
    /// Acceptable because a paste is a keystroke, not a frame, and it is the
    /// reason the IDL says not to call it per frame. If it ever becomes a
    /// problem the answer is a cached selection updated on focus change, not
    /// moving this off the loop: GLFW is not thread-safe.
    override func getClipboard(surfaceId: UInt32) throws -> String {
        try requireSurface(surfaceId)
        return editor.clipboardText
    }

    override func setClipboard(surfaceId: UInt32, text: String) throws {
        try requireSurface(surfaceId)
        editor.clipboardText = text
    }

    /// Checks the caller still owns a surface, for the calls that do not
    /// otherwise need one.
    ///
    /// Not a formality. A client that has lost its surface has lost its
    /// window, and a windowless process quietly reading the user's selection
    /// is the thing Wayland changed from X11 specifically to prevent. This is
    /// where that check goes when it grows teeth — today it only proves the
    /// surface exists, not that it is focused.
    private func requireSurface(_ surfaceId: UInt32) throws {
        guard SurfaceRegistry.surface(id: surfaceId) != nil else {
            var ex = SurfaceNotFound()
            ex.surfaceId = surfaceId
            throw ex
        }
    }

    /// `[unreliable]` — no reply. Marks a window dirty; the loop renders it
    /// later in the very iteration this runs in, since servant work is drained
    /// before anything is drawn.
    ///
    /// The wake that used to be here is the executor's now: `post` wakes the
    /// loop to run this at all, so waking again from inside it would be asking
    /// twice for the same thing.
    ///
    /// An unknown surface is dropped rather than reported: there is no reply
    /// to report it in, and it is what a client racing its own
    /// `DestroySurface` legitimately produces.
    override func present(surfaceId: UInt32) {
        SurfaceRegistry.markDirty(surfaceId: surfaceId)
    }

    /// The reverse channel. Runs for as long as the client keeps the stream
    /// open, on NPRPC's own task, never on the loop.
    ///
    /// The *dispatch* is on the loop like everything else here, and unlike
    /// everything else here that costs something: stream init starts this body
    /// on the concurrency pool and parks the loop until it either throws or
    /// first touches the stream, so a frame waits on a task hop. It is
    /// bounded, and it is why nothing below may wait on the loop in turn —
    /// that would close the circle. Guaranteed by construction: everything
    /// this body touches before its first stream access is a lock.
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

    // Servants land on the render loop, not on the shared-memory ring thread.
    //
    // Which is the whole of what this compositor's servant code used to do by
    // hand, and the reason it is worth having as a policy instead: the rule
    // "anything touching the device runs on the loop" is now a property of the
    // POA rather than something each method has to remember, and forgetting it
    // used to mean touching Vulkan from an RPC thread — which fails late,
    // rarely, and nowhere near the mistake.
    //
    // It also frees the ring immediately: `CreateSurface` builds a swapchain
    // and takes ~86 ms, and that used to be 86 ms during which nothing else
    // from that client — its input acks included — could be read.
    let poa = try rpc.createPoa(
        maxObjects: 8, lifetime: .Persistent, idPolicy: .userSupplied,
        dispatch: .loop(LoopExecutor.shared)
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
