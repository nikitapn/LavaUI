import CLavaVideo
import CMpv
import Foundation
import LavaUI

/// mpv, and the frames it draws on their way to the screen.
///
/// Three threads meet here and the split between them is the design:
///
///   * **mpv's render thread** (`lava-video`, in C) draws a frame and calls
///     `present`. In dma-buf mode that is answered right there — the frame is
///     named to the compositor from that thread, and its reply is what frees
///     the buffer — so a frame never waits for the UI loop to come round.
///   * **mpv's own threads** say "there are events" through `wakeup`, which
///     only posts to the main queue.
///   * **the main thread** reads the events, keeps the state the views show,
///     and draws whatever frame is newest.
///
/// What crosses between them is one locked slot, `latest`: the render thread
/// writes the newest frame, the paint closure reads it. Nothing else is shared.
final class Player: @unchecked Sendable {
    /// What mpv says, as the main thread last heard it. Applied to the session
    /// by `onState`; the player itself keeps no opinion about it.
    struct State: Equatable {
        var position: Double?
        var duration: Double?
        var paused = false
        var volume: Double = 100
        var muted = false
        var title: String?
        var eofReached = false
        var idle = true
        var videoWidth: Int = 0
        var videoHeight: Int = 0
    }

    /// The frame to draw: a texture the renderer already holds.
    enum Frame {
        /// In the compositor, by id. Nothing to release: the buffer it was
        /// copied from is ours, and its texture lives as long as the buffer.
        case video(VideoFrame)
        /// Uploaded from memory, as a texture of its own that must be
        /// released when it is replaced.
        case pixels(UIImage)

        var textureId: UInt32 {
            switch self {
            case .video(let frame): frame.textureId
            case .pixels(let image): image.textureId
            }
        }

        var size: (width: Float, height: Float) {
            switch self {
            case .video(let frame): (Float(frame.width), Float(frame.height))
            case .pixels(let image): (image.pixelWidth, image.pixelHeight)
            }
        }
    }

    private let host: any GPUResourceHost
    private let videoHost: (any VideoFrameHost)?
    private var video: OpaquePointer?
    private var mpv: OpaquePointer?

    private let lock = NSLock()
    private var latest: Frame?
    /// Pixel frames already replaced, kept for one more frame before release:
    /// the window's last presented draw list may still name the one before.
    private var retiring: [UIImage] = []
    /// A pixel frame copied off the render thread and not yet uploaded. Only
    /// the newest is kept — a main thread that falls behind skips frames
    /// rather than queueing them.
    private var pendingPixels: (bytes: [UInt8], width: UInt32, height: UInt32, stride: UInt32)?

    private(set) var state = State()
    var onState: ((State) -> Void)?
    var onEndOfFile: (() -> Void)?
    var onError: ((String) -> Void)?

    /// Whether frames reach the renderer as dma-bufs. False is the software
    /// path: correct, and several times the CPU.
    private(set) var usesDmabuf = false

    init(host: any GPUResourceHost) {
        self.host = host
        self.videoHost = host as? any VideoFrameHost
    }

    /// Brings mpv up. False with a reason on stderr when even the software
    /// path will not start — mpv itself refusing to initialise.
    func start() -> Bool {
        let target = videoHost?.videoTarget()
        let context = Unmanaged.passUnretained(self).toOpaque()
        var callbacks = LavaVideoCallbacks()
        callbacks.ctx = context
        if videoHost != nil {
            callbacks.attach = { ctx, buffer in
                guard let ctx, let buffer else { return 0 }
                let player = Unmanaged<Player>.fromOpaque(ctx).takeUnretainedValue()
                return player.attach(buffer.pointee)
            }
            callbacks.detach = { ctx, handle in
                guard let ctx else { return }
                let player = Unmanaged<Player>.fromOpaque(ctx).takeUnretainedValue()
                player.videoHost?.detachVideoBuffer(handle)
            }
            callbacks.present = { ctx, handle in
                guard let ctx else { return }
                Unmanaged<Player>.fromOpaque(ctx).takeUnretainedValue().present(handle)
            }
        }
        callbacks.present_pixels = { ctx, pixels, width, height, stride in
            guard let ctx, let pixels else { return }
            Unmanaged<Player>.fromOpaque(ctx).takeUnretainedValue()
                .presentPixels(pixels, width: width, height: height, stride: stride)
        }
        callbacks.wakeup = { ctx in
            guard let ctx else { return }
            let player = Unmanaged<Player>.fromOpaque(ctx).takeUnretainedValue()
            MainQueue.async { player.drainEvents() }
        }

        var error = [CChar](repeating: 0, count: 256)
        let options: [String?] = Self.options()
        // The trailing nil only keeps the array non-empty; the count says
        // where it ends.
        let made: OpaquePointer? = withCStrings(options + [nil]) { optionPointers in
            if let target {
                return target.renderNode.withCString { node in
                    target.modifiers.withUnsafeBufferPointer { modifiers in
                        let wanted = LavaVideoTarget(
                            render_node: node, modifiers: modifiers.baseAddress,
                            modifier_count: modifiers.count
                        )
                        return lava_video_create(
                            wanted, callbacks, optionPointers, options.count,
                            &error, error.count
                        )
                    }
                }
            }
            return lava_video_create(
                LavaVideoTarget(render_node: nil, modifiers: nil, modifier_count: 0),
                callbacks, optionPointers, options.count, &error, error.count
            )
        }
        guard let made else {
            FileHandle.standardError.write(
                Data("LavaPlayer: mpv would not start: \(String(decoding: error.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self))\n".utf8)
            )
            return false
        }
        video = made
        mpv = lava_video_mpv(made)
        usesDmabuf = lava_video_uses_dmabuf(made) != 0
        FileHandle.standardError.write(Data(
            "LavaPlayer: \(usesDmabuf ? "dma-buf frames on \(target?.renderNode ?? "?")" : "software frames")\n".utf8
        ))
        observe()
        return true
    }

    /// mpv options from `LAVA_PLAYER_MPV="hwdec=no profile=fast"`, for trying
    /// one without a rebuild. Space-separated `name=value`.
    private static func options() -> [String] {
        let raw = ProcessInfo.processInfo.environment["LAVA_PLAYER_MPV"] ?? ""
        return raw.split(separator: " ").map(String.init).filter { $0.contains("=") }
    }

    func stop() {
        guard let video else { return }
        self.video = nil
        mpv = nil
        // Joins the render thread, which may be inside a `present` waiting on
        // the compositor: bounded by the RPC timeout, never by the main
        // thread, which this is.
        lava_video_destroy(video)
        lock.lock()
        let old = latest
        let gone = retiring
        latest = nil
        retiring = []
        lock.unlock()
        if case .pixels(let image) = old { host.releaseImage(key: image.cacheKey) }
        for image in gone { host.releaseImage(key: image.cacheKey) }
    }

    // MARK: - Frames

    private func attach(_ buffer: LavaVideoBuffer) -> UInt32 {
        let layout = VideoBufferLayout(
            width: buffer.width, height: buffer.height, fourcc: buffer.fourcc,
            modifier: buffer.modifier, offset: buffer.offset, stride: buffer.stride
        )
        return videoHost?.attachVideoBuffer(fd: buffer.fd, layout: layout) ?? 0
    }

    /// Render thread. The compositor copies, replies, and then the frame is
    /// ours to show.
    private func present(_ handle: UInt32) {
        guard let frame = videoHost?.showVideoBuffer(handle) else { return }
        lock.lock()
        latest = .video(frame)
        lock.unlock()
        MainQueue.async { ViewInvalidation.markNeedsRedraw() }
    }

    /// Render thread, software path. Copied out, because the bytes belong to
    /// the bridge and are rewritten by the next frame; uploaded on the main
    /// thread, because the built-in renderer's device is that thread's alone.
    private func presentPixels(
        _ pixels: UnsafeRawPointer, width: UInt32, height: UInt32, stride: UInt32
    ) {
        let count = Int(stride) * Int(height)
        let bytes = [UInt8](UnsafeRawBufferPointer(start: pixels, count: count))
        lock.lock()
        let first = pendingPixels == nil
        pendingPixels = (bytes, width, height, stride)
        lock.unlock()
        if first { MainQueue.async { [self] in uploadPending() } }
    }

    private func uploadPending() {
        lock.lock()
        let pending = pendingPixels
        pendingPixels = nil
        lock.unlock()
        guard let pending else { return }
        let image = pending.bytes.withUnsafeBytes { raw in
            host.uploadPixels(
                raw, width: pending.width, height: pending.height,
                stride: pending.stride, format: .rgbx8
            )
        }
        guard let image else { return }
        lock.lock()
        let gone = retiring
        if case .pixels(let previous) = latest { retiring = [previous] } else { retiring = [] }
        latest = .pixels(image)
        lock.unlock()
        for old in gone { host.releaseImage(key: old.cacheKey) }
        ViewInvalidation.markNeedsRedraw()
    }

    /// The newest frame, for the paint closure.
    func currentFrame() -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// The box the video is drawn in, in pixels. mpv renders at this size,
    /// so subtitles are drawn at screen resolution and scaling uses mpv's own
    /// filters rather than the compositor's bilinear one. Every paint calls
    /// it; only a change costs anything.
    func setSize(width: Float, height: Float) {
        guard let video else { return }
        lava_video_set_size(
            video, UInt32(max(0, width.rounded())), UInt32(max(0, height.rounded()))
        )
    }

    // MARK: - Commands

    func load(_ path: String) {
        command(["loadfile", path, "replace"])
        // A file that ended paused would start paused; nobody opening a file
        // wants that.
        setFlag("pause", false)
    }

    func togglePause() {
        if state.eofReached {
            // At the end, play means from the start — what every player does.
            command(["seek", "0", "absolute"])
            setFlag("pause", false)
            return
        }
        command(["cycle", "pause"])
    }

    /// `exact: false` lands on a keyframe near `seconds` and shows it at once;
    /// `exact: true` decodes on from that keyframe to the frame itself.
    func seek(to seconds: Double, exact: Bool) {
        command(["seek", String(max(0, seconds)), exact ? "absolute+exact" : "absolute+keyframes"])
    }

    func seek(by seconds: Double) {
        command(["seek", String(seconds), "relative"])
    }

    func setVolume(_ volume: Double) {
        setDouble("volume", min(130, max(0, volume)))
    }

    func toggleMute() { command(["cycle", "mute"]) }

    func stepFrame(_ direction: Int) {
        command([direction < 0 ? "frame-back-step" : "frame-step"])
    }

    private func command(_ arguments: [String]) {
        guard let mpv else { return }
        _ = withCStrings(arguments + [nil]) { pointers in
            mpv_command_async(mpv, 0, UnsafeMutablePointer(mutating: pointers))
        }
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let mpv else { return }
        var flag: Int32 = value ? 1 : 0
        mpv_set_property_async(mpv, 0, name, MPV_FORMAT_FLAG, &flag)
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard let mpv else { return }
        var number = value
        mpv_set_property_async(mpv, 0, name, MPV_FORMAT_DOUBLE, &number)
    }

    // MARK: - Events

    private enum Watched: UInt64, CaseIterable {
        case position = 1, duration, pause, volume, mute, title, eof, idle,
             width, height

        var name: String {
            switch self {
            case .position: "time-pos"
            case .duration: "duration"
            case .pause: "pause"
            case .volume: "volume"
            case .mute: "mute"
            case .title: "media-title"
            case .eof: "eof-reached"
            case .idle: "idle-active"
            case .width: "dwidth"
            case .height: "dheight"
            }
        }

        var format: mpv_format {
            switch self {
            case .position, .duration, .volume: MPV_FORMAT_DOUBLE
            case .pause, .mute, .eof, .idle: MPV_FORMAT_FLAG
            case .title: MPV_FORMAT_STRING
            case .width, .height: MPV_FORMAT_INT64
            }
        }
    }

    private func observe() {
        guard let mpv else { return }
        for property in Watched.allCases {
            mpv_observe_property(mpv, property.rawValue, property.name, property.format)
        }
    }

    /// Main thread. Everything mpv has to say since the last wakeup.
    private func drainEvents() {
        guard let mpv else { return }
        var next = state
        var ended = false
        while let event = mpv_wait_event(mpv, 0), event.pointee.event_id != MPV_EVENT_NONE {
            switch event.pointee.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let data = event.pointee.data else { break }
                let change = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                apply(change, id: event.pointee.reply_userdata, to: &next)
            case MPV_EVENT_END_FILE:
                guard let data = event.pointee.data else { break }
                let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                if end.reason == MPV_END_FILE_REASON_ERROR {
                    onError?(String(cString: mpv_error_string(end.error)))
                }
            case MPV_EVENT_SHUTDOWN:
                return
            default:
                break
            }
        }
        if next.eofReached && !state.eofReached { ended = true }
        if next != state {
            state = next
            onState?(next)
        }
        if ended { onEndOfFile?() }
    }

    private func apply(_ change: mpv_event_property, id: UInt64, to state: inout State) {
        guard let which = Watched(rawValue: id) else { return }
        // MPV_FORMAT_NONE means "unavailable" — no file, or not yet known.
        let present = change.format != MPV_FORMAT_NONE && change.data != nil
        func double() -> Double? {
            present ? change.data.assumingMemoryBound(to: Double.self).pointee : nil
        }
        func flag() -> Bool {
            present ? change.data.assumingMemoryBound(to: Int32.self).pointee != 0 : false
        }
        func int() -> Int {
            present ? Int(change.data.assumingMemoryBound(to: Int64.self).pointee) : 0
        }
        switch which {
        // Quarter seconds: `time-pos` changes every frame, and every change is
        // a body pass for the readout and the slider. Four a second is as
        // fine as either can show.
        case .position: state.position = double().map { ($0 * 4).rounded(.down) / 4 }
        case .duration: state.duration = double()
        case .pause: state.paused = flag()
        case .volume: state.volume = double() ?? state.volume
        case .mute: state.muted = flag()
        case .eof: state.eofReached = flag()
        case .idle: state.idle = flag()
        case .width: state.videoWidth = int()
        case .height: state.videoHeight = int()
        case .title:
            state.title = present
                ? change.data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee
                    .map { String(cString: $0) }
                : nil
        }
    }
}

/// `body` with a NUL-terminated `char *` array built from `strings`; a nil
/// element stays NULL, which is how mpv's argument lists end.
private func withCStrings<R>(
    _ strings: [String?], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R
) -> R {
    let duplicated = strings.map { $0.map { UnsafePointer(strdup($0)!) } }
    defer { for pointer in duplicated { free(UnsafeMutablePointer(mutating: pointer)) } }
    return duplicated.withUnsafeBufferPointer { body($0.baseAddress!) }
}
