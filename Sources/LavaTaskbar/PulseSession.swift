import CPulse
import Foundation
import LavaUI
import Observation

/// Live view of the default PulseAudio (or PipeWire-Pulse) sink.
///
/// Pulse callbacks run on a private threaded mainloop; every state change is
/// hopped onto `MainQueue` before touching `@Observable` properties so the
/// panel's frame loop stays single-threaded.
@Observable
final class PulseSession: @unchecked Sendable {
    private(set) var volume: Float = 0
    private(set) var muted: Bool = false
    /// Sink description when Pulse provides one ("Built-in Audio…").
    private(set) var sinkName: String = ""
    private(set) var isReady: Bool = false

    private var handle: OpaquePointer?
    private var box: Unmanaged<PulseSession>?

    init() {
        let unmanaged = Unmanaged.passRetained(self)
        box = unmanaged
        handle = lava_pulse_create({ user, volume, muted, sink, ready in
            guard let user else { return }
            let session = Unmanaged<PulseSession>.fromOpaque(user).takeUnretainedValue()
            let name = sink.map { String(cString: $0) } ?? ""
            MainQueue.async {
                session.volume = volume
                session.muted = muted != 0
                session.sinkName = name
                session.isReady = ready != 0
                // Paint closures are not observation-tracked; ask for a frame
                // so the speaker glyph and open popover stay live.
                ViewInvalidation.markNeedsRedraw()
            }
        }, unmanaged.toOpaque())

        if handle == nil {
            unmanaged.release()
            box = nil
            FileHandle.standardError.write(
                Data("LavaTaskbar: PulseAudio unavailable\n".utf8)
            )
        } else {
            FileHandle.standardError.write(
                Data("LavaTaskbar: PulseAudio connected\n".utf8)
            )
        }
    }

    deinit {
        if let handle { lava_pulse_destroy(handle) }
        box?.release()
    }

    func setVolume(_ value: Float) {
        guard let handle else { return }
        lava_pulse_set_volume(handle, value)
    }

    func setMuted(_ muted: Bool) {
        guard let handle else { return }
        lava_pulse_set_mute(handle, muted ? 1 : 0)
    }

    func toggleMute() {
        guard let handle else { return }
        lava_pulse_toggle_mute(handle)
    }

    func adjustVolume(by delta: Float) {
        guard let handle else { return }
        lava_pulse_adjust_volume(handle, delta)
    }

    var volumeBinding: Binding<Float> {
        Binding(get: { self.volume }, set: { self.setVolume($0) })
    }

    var mutedBinding: Binding<Bool> {
        Binding(get: { self.muted }, set: { self.setMuted($0) })
    }

    /// Percent for chrome (0…100, or higher when soft-boosted).
    var percentLabel: String {
        "\(Int((volume * 100).rounded()))%"
    }
}
