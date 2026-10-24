import CPulse
import Foundation
import LavaShell
import LavaUI
import Observation

/// Live view of the sound server: outputs, inputs, and what is playing.
///
/// Pulse callbacks run on a private threaded mainloop; every snapshot is
/// copied into Swift values there and hopped onto `MainQueue` before touching
/// `@Observable` properties, so the panel's frame loop stays single-threaded.
@Observable
final class PulseSession: @unchecked Sendable {
    private(set) var sinks: [SoundDevice] = []
    private(set) var sources: [SoundDevice] = []
    private(set) var streams: [SoundStream] = []
    private(set) var defaultSink = ""
    private(set) var defaultSource = ""
    private(set) var isReady: Bool = false

    private var handle: OpaquePointer?
    private var box: Unmanaged<PulseSession>?

    /// Levels this process set, and when. A slider drag writes faster than
    /// the server answers, so a snapshot can arrive saying the level of two
    /// writes ago; believed, it pulls the knob back under the pointer.
    @ObservationIgnored private var held: [String: (value: Float, at: Date)] = [:]
    private static let holdFor: TimeInterval = 0.5

    private static let sink = Int32(LAVA_PULSE_SINK)
    private static let source = Int32(LAVA_PULSE_SOURCE)

    init() {
        let unmanaged = Unmanaged.passRetained(self)
        box = unmanaged
        handle = lava_pulse_create({ user, snapshot in
            guard let user, let snapshot else { return }
            let session = Unmanaged<PulseSession>.fromOpaque(user).takeUnretainedValue()
            let snap = snapshot.pointee
            let sinks = PulseSession.devices(snap.sinks, snap.sink_count)
            let sources = PulseSession.devices(snap.sources, snap.source_count)
            let streams = PulseSession.streams(snap.streams, snap.stream_count)
            let defaultSink = String(cString: snap.default_sink)
            let defaultSource = String(cString: snap.default_source)
            let ready = snap.ready != 0
            MainQueue.async {
                session.adopt(
                    sinks: sinks, sources: sources, streams: streams,
                    defaultSink: defaultSink, defaultSource: defaultSource, ready: ready
                )
            }
        }, unmanaged.toOpaque())

        if handle == nil {
            unmanaged.release()
            box = nil
            FileHandle.standardError.write(
                Data("LavaPanel: PulseAudio unavailable\n".utf8)
            )
        } else {
            FileHandle.standardError.write(
                Data("LavaPanel: PulseAudio connected\n".utf8)
            )
        }
    }

    deinit {
        if let handle { lava_pulse_destroy(handle) }
        box?.release()
    }

    private func adopt(
        sinks: [SoundDevice], sources: [SoundDevice], streams: [SoundStream],
        defaultSink: String, defaultSource: String, ready: Bool
    ) {
        let now = Date()
        held = held.filter { now.timeIntervalSince($0.value.at) < Self.holdFor }
        func keep(_ key: String, _ volume: Float) -> Float { held[key]?.value ?? volume }
        self.sinks = sinks.map { var d = $0; d.volume = keep("sink:" + d.name, d.volume); return d }
        self.sources = sources.map { var d = $0; d.volume = keep("source:" + d.name, d.volume); return d }
        self.streams = streams.map { var s = $0; s.volume = keep("stream:\(s.id)", s.volume); return s }
        self.defaultSink = held["default:sink"] != nil ? self.defaultSink : defaultSink
        self.defaultSource = held["default:source"] != nil ? self.defaultSource : defaultSource
        isReady = ready
        // Paint closures are not observation-tracked; ask for a frame so the
        // speaker glyph and an open window stay live.
        ViewInvalidation.markNeedsRedraw()
    }

    // MARK: - Reading

    var output: SoundDevice? { SoundRoutes.current(sinks, name: defaultSink) }
    var input: SoundDevice? { SoundRoutes.current(sources, name: defaultSource) }
    var outputRoutes: [SoundRoute] { SoundRoutes.routes(sinks, current: defaultSink) }
    var inputRoutes: [SoundRoute] { SoundRoutes.routes(sources, current: defaultSource) }

    /// The default output's level and mute, for the strip's glyph.
    var volume: Float { output?.volume ?? 0 }
    var muted: Bool { output?.muted ?? false }

    /// Percent for chrome (0…100, or higher when soft-boosted).
    var percentLabel: String { Self.percent(volume) }

    static func percent(_ value: Float) -> String { "\(Int((value * 100).rounded()))%" }

    // MARK: - Output

    func setVolume(_ value: Float) {
        guard let output else { return }
        setDevice(Self.sink, output.name, channels: output.channels, volume: value)
    }

    func setMuted(_ muted: Bool) {
        guard let output else { return }
        setDeviceMute(Self.sink, output.name, muted)
    }

    func toggleMute() { setMuted(!muted) }

    func adjustVolume(by delta: Float) { setVolume(min(max(volume + delta, 0), 1.5)) }

    var volumeBinding: Binding<Float> {
        Binding(get: { self.volume }, set: { self.setVolume($0) })
    }

    var mutedBinding: Binding<Bool> {
        Binding(get: { self.muted }, set: { self.setMuted($0) })
    }

    // MARK: - Input

    func setInputVolume(_ value: Float) {
        guard let input else { return }
        setDevice(Self.source, input.name, channels: input.channels, volume: value)
    }

    func setInputMuted(_ muted: Bool) {
        guard let input else { return }
        setDeviceMute(Self.source, input.name, muted)
    }

    var inputVolumeBinding: Binding<Float> {
        Binding(get: { self.input?.volume ?? 0 }, set: { self.setInputVolume($0) })
    }

    // MARK: - Switching

    func selectOutput(_ route: SoundRoute) { select(Self.sink, route) }
    func selectInput(_ route: SoundRoute) { select(Self.source, route) }

    private func select(_ kind: Int32, _ route: SoundRoute) {
        guard let handle else { return }
        // Say so now: the server's answer is a refresh away, and a row that
        // does not light up on click reads as a click that missed.
        if kind == Self.sink { defaultSink = route.device } else { defaultSource = route.device }
        hold(kind == Self.sink ? "default:sink" : "default:source", 0)
        if let port = route.port { setActivePort(kind, route.device, port) }
        lava_pulse_set_default(handle, kind, route.device, route.port)
    }

    private func setActivePort(_ kind: Int32, _ device: String, _ port: String) {
        func update(_ list: inout [SoundDevice]) {
            if let i = list.firstIndex(where: { $0.name == device }) { list[i].activePort = port }
        }
        if kind == Self.sink { update(&sinks) } else { update(&sources) }
    }

    // MARK: - Streams

    func setStreamVolume(_ stream: SoundStream, _ value: Float) {
        guard let handle else { return }
        hold("stream:\(stream.id)", value)
        if let i = streams.firstIndex(where: { $0.id == stream.id }) { streams[i].volume = value }
        lava_pulse_set_stream_volume(handle, stream.id, Int32(stream.channels), value)
    }

    func setStreamMuted(_ stream: SoundStream, _ muted: Bool) {
        guard let handle else { return }
        if let i = streams.firstIndex(where: { $0.id == stream.id }) { streams[i].muted = muted }
        lava_pulse_set_stream_mute(handle, stream.id, muted ? 1 : 0)
    }

    func streamVolumeBinding(_ stream: SoundStream) -> Binding<Float> {
        Binding(
            get: { self.streams.first { $0.id == stream.id }?.volume ?? stream.volume },
            set: { self.setStreamVolume(stream, $0) }
        )
    }

    // MARK: - Pieces

    private func setDevice(_ kind: Int32, _ name: String, channels: Int, volume: Float) {
        guard let handle else { return }
        let value = min(max(volume, 0), 1.5)
        let sink = kind == Self.sink
        hold((sink ? "sink:" : "source:") + name, value)
        func update(_ list: inout [SoundDevice]) {
            if let i = list.firstIndex(where: { $0.name == name }) { list[i].volume = value }
        }
        if sink { update(&sinks) } else { update(&sources) }
        lava_pulse_set_device_volume(handle, kind, name, Int32(channels), value)
        ViewInvalidation.markNeedsRedraw()
    }

    private func setDeviceMute(_ kind: Int32, _ name: String, _ muted: Bool) {
        guard let handle else { return }
        func update(_ list: inout [SoundDevice]) {
            if let i = list.firstIndex(where: { $0.name == name }) { list[i].muted = muted }
        }
        if kind == Self.sink { update(&sinks) } else { update(&sources) }
        lava_pulse_set_device_mute(handle, kind, name, muted ? 1 : 0)
        ViewInvalidation.markNeedsRedraw()
    }

    private func hold(_ key: String, _ value: Float) { held[key] = (value, Date()) }

    // MARK: - Copying out of C

    private static func string(_ p: UnsafePointer<CChar>?) -> String {
        p.map { String(cString: $0) } ?? ""
    }

    private static func devices(_ base: UnsafePointer<LavaPulseDevice>?, _ count: Int) -> [SoundDevice] {
        guard let base, count > 0 else { return [] }
        return UnsafeBufferPointer(start: base, count: count).map { d in
            let ports: [SoundPort] = d.ports.map { ports in
                UnsafeBufferPointer(start: ports, count: d.port_count).map { port in
                    SoundPort(
                        name: string(port.name), description: string(port.description),
                        availability: port.available == Int32(LAVA_PULSE_PORT_YES) ? .yes
                            : port.available == Int32(LAVA_PULSE_PORT_NO) ? .no : .unknown
                    )
                }
            } ?? []
            return SoundDevice(
                name: string(d.name), description: string(d.description),
                card: string(d.card), bus: string(d.bus),
                volume: d.volume, muted: d.muted != 0, channels: Int(d.channels),
                ports: ports, activePort: string(d.active_port)
            )
        }
    }

    private static func streams(_ base: UnsafePointer<LavaPulseStream>?, _ count: Int) -> [SoundStream] {
        guard let base, count > 0 else { return [] }
        return UnsafeBufferPointer(start: base, count: count).map { s in
            SoundStream(
                id: s.index, sink: s.sink, app: string(s.app), media: string(s.media),
                icon: string(s.icon), binary: string(s.binary),
                volume: s.volume, muted: s.muted != 0, channels: Int(s.channels),
                corked: s.corked != 0
            )
        }
    }
}
