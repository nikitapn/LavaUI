import CxxCanvas
import Foundation
import LavaIDL
import LavaUI
import NPRPC

// The app's half of the compositor control plane.
//
// Everything here is the side that *asks*: find the compositor, get ids for
// the resources it owns, take a surface, read its input. The serving half
// stays with whoever is the renderer.
//
// Kept out of `LavaUI` itself, and not by accident: NPRPC builds with
// `.unsafeFlags`, which SwiftPM propagates to every dependent and permits only
// for path dependencies, so a LavaUI that linked it could not be used as a
// GitHub dependency. The control plane belongs above the UI framework anyway.


/// The wire event, disambiguated from `LavaUI.InputEvent`.
///
/// They are field-for-field the same shape — that congruence is the point, and
/// it is also why neither module's name wins on its own. Spelling the wire one
/// out keeps every conversion site saying which side of the boundary it is on.
public typealias WireInputEvent = LavaIDL.InputEvent

/// Where the renderer publishes its object reference, and the client reads it.
///
/// A file rather than a nameserver: this is one machine, one desktop session,
/// and requiring a separate `npnameserver` process to start before the
/// compositor would be a deployment step in exchange for nothing. The IOR
/// string already carries the endpoint.
public enum ControlPlane {
    public static var referencePath: String {
        let base = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? "/tmp"
        return (base as NSString).appendingPathComponent("lava-compositor.ior")
    }
}

/// Connects to the compositor. Returns the proxy plus the `Rpc` that owns its
/// transport, which the caller must keep alive.
public func connectToCompositor() throws -> (Compositor, Rpc) {
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

/// The client's end of resource naming: LavaUI asks, the compositor answers.
///
/// Install it on the editor once, before anything loads, and every font id and
/// texture id the app stamps into a frame becomes one the renderer will
/// resolve to the same thing:
///
/// ```swift
/// guard let editor = LavaClient.open(title: "My App") else { exit(1) }
/// editor.resources = CompositorResources(compositor)
/// ```
///
/// Nothing above that line changes. `FontStore` and `ImageStore` keep their
/// caches, their budget and their eviction, because none of that was ever
/// about who owns the GPU — only the ids were, and this is the whole of that
/// difference. See `GPUResourceHost`.
public final class CompositorResources: GPUResourceHost, @unchecked Sendable {
    private let compositor: Compositor

    /// Texture id per image, so a release can name what registration returned.
    /// Small and short-lived; the real cache is `ImageStore`'s, and this only
    /// exists because `releaseImage` speaks in keys and the wire speaks in ids.
    private let lock = NSLock()
    private var idsByKey: [String: UInt32] = [:]
    /// Keys the compositor has already refused.
    ///
    /// A path that will not decode — a `.ico`, an `.xpm`, a file that is not
    /// an image at all — is asked for again on the very next frame, because
    /// nothing else remembers the answer. That is a round trip *and* a decode
    /// attempt on the compositor's event loop, per broken icon, per frame,
    /// for as long as the window is open. A launcher showing four hundred
    /// applications finds a handful of these on any real machine.
    ///
    /// Remembered for the life of the process rather than retried: a file that
    /// could not be decoded a moment ago is not going to decode now, and a
    /// client that outlives the file being fixed can be restarted.
    private var refusedKeys: Set<String> = []

    public init(_ compositor: Compositor) { self.compositor = compositor }

    public func registerFont(
        path: String, pixelSize26_6: UInt32, faceIndex: UInt32,
        rasterFlags: UInt32
    ) -> UInt32? {
        do {
            return try blockingCall { [compositor] in
                try await compositor.registerFont(
                    path: path, pixelSize26_6: pixelSize26_6,
                    faceIndex: faceIndex, rasterFlags: rasterFlags
                )
            }
        } catch {
            FileHandle.standardError.write(
                Data("RegisterFont(\(path)) failed: \(error)\n".utf8)
            )
            return nil
        }
    }

    public func registerImage(path: String, maxPixelSize: UInt32) -> UIImage? {
        let key = ImageStore.key(path: path, maxPixelSize: maxPixelSize)
        lock.lock()
        let alreadyRefused = refusedKeys.contains(key)
        lock.unlock()
        if alreadyRefused { return nil }

        let info: ImageInfo
        do {
            info = try blockingCall(timeout: 10) { [compositor] in
                // Longer than the default: this one decodes and uploads a
                // file on the far side, where `RegisterFont` only opens one.
                try await compositor.registerImage(
                    path: path, maxPixelSize: maxPixelSize
                )
            }
        } catch {
            // Said once. The `refusedKeys` entry is what makes it once — see
            // above; without it this line is printed every frame.
            FileHandle.standardError.write(
                Data("RegisterImage(\(path)) failed: \(error)\n".utf8)
            )
            lock.lock()
            refusedKeys.insert(key)
            lock.unlock()
            return nil
        }
        lock.lock()
        idsByKey[key] = info.id
        lock.unlock()
        return UIImage(
            path: path, cacheKey: key, textureId: info.id,
            pixelWidth: Float(info.width), pixelHeight: Float(info.height)
        )
    }

    public func registerImage(data: [UInt8], maxPixelSize: UInt32) -> UIImage? {
        let info: ImageInfo
        do {
            info = try blockingCall(timeout: 10) { [compositor] in
                // Same budget as the path form, and it buys the same thing:
                // a decode and an upload on the far side. The transfer itself
                // is a memcpy into a ring the compositor is already mapped to.
                try await compositor.registerImageData(
                    bytes: data, maxPixelSize: maxPixelSize
                )
            }
        } catch {
            FileHandle.standardError.write(
                Data("RegisterImageData(\(data.count) bytes) failed: \(error)\n".utf8)
            )
            return nil
        }
        // Derived, not returned: the compositor computes the same key from the
        // same bytes, so sending it back would be sending something the client
        // can check. The `UIImage` has to carry it because `ImageStore` looks
        // entries up by it.
        let key = ImageStore.contentKey(data: data, maxPixelSize: maxPixelSize)
        lock.lock()
        idsByKey[key] = info.id
        lock.unlock()
        return UIImage(
            path: key, cacheKey: key, textureId: info.id,
            pixelWidth: Float(info.width), pixelHeight: Float(info.height)
        )
    }

    public func releaseImage(key: String) {
        lock.lock()
        let id = idsByKey.removeValue(forKey: key)
        lock.unlock()
        guard let id else { return }
        // Fire and forget. A failed release costs the renderer a texture until
        // the client exits, which is not worth stalling an eviction over —
        // and eviction runs inside a frame.
        Task.detached { [compositor] in try? await compositor.releaseImage(id: id) }
    }

    // `registerImageAsync` comes from the protocol's default: the call is a
    // round trip that touches nothing local, so a worker thread and a hop back
    // to the main queue is the whole of it. The local host overrides that
    // because its decode and its upload belong on different threads.
}

/// The app's end of `SubscribeInput`: an async stream on one side, a frame
/// loop that is not async on the other.
///
/// Same shape as `LoopQueue` in the other direction and for the same reason —
/// events arrive on an NPRPC thread, and the only thread allowed to touch the
/// arena is the one writing frames into it.
public final class InputChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [WireInputEvent] = []
    private var ended = false
    private let acks: AsyncStream<UInt32>.Continuation

    public init(stream: NPRPCBidiStream<InputAck, WireInputEvent>) {
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

    /// Ends the lease cleanly from this side.
    ///
    /// Finishes the ack stream so the writer closes, which is what the
    /// compositor treats as "the surface is gone" when `DestroySurface` is
    /// not used first. Cheap if already closed.
    public func close() {
        acks.finish()
        finish()
    }

    /// Called on the NPRPC thread the moment something arrives, for a client
    /// whose frame loop parks rather than polls.
    ///
    /// A LavaUI client blocks in `pumpEvents` until something happens, and an
    /// input that only becomes
    /// visible on the next tick would be an input that arrives when the next
    /// tick happens to be — which for an idle app is never.
    public var onArrival: (@Sendable () -> Void)?

    private func enqueue(_ event: WireInputEvent) {
        lock.lock()
        queue.append(event)
        let notify = onArrival
        lock.unlock()
        notify?()
    }

    private func finish() {
        lock.lock()
        ended = true
        lock.unlock()
    }

    /// True once the renderer has gone away — the app's cue to stop drawing
    /// frames nobody will read.
    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended
    }

    /// Everything that arrived since the last call. Acknowledges the batch,
    /// which is the honest moment to do it: the serial now means "consumed",
    /// not "received".
    public func drain() -> [WireInputEvent] {
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
public func blockingCall<T>(
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

public enum ControlPlaneError: Error, CustomStringConvertible {
    case badReference(String)
    case noEndpoint(String)
    case classMismatch
    case timedOut

    public var description: String {
        switch self {
        case .badReference(let s): return "not a usable object reference: \(s)"
        case .noEndpoint(let urls): return "no usable endpoint among: \(urls)"
        case .classMismatch: return "reference is not a lava.Compositor"
        case .timedOut: return "the compositor did not answer"
        }
    }
}
