import CMpris
import Foundation
import LavaUI
import Observation

/// Live view of the session's MPRIS player, preferring spotifyd.
///
/// sd-bus callbacks run on a private event thread; every snapshot is copied
/// and hopped onto `MainQueue` before touching `@Observable` properties.
///
/// The panel uses the default ranking (spotifyd, then Spotify, then anyone).
/// LavaSpotify passes `spotifydOnly:` so OpenUri cannot land on mpv.
@Observable
public final class MprisSession: @unchecked Sendable {
    public private(set) var present = false
    /// `rs.spotifyd.Controls` is up even when the daemon is not the active
    /// Connect device. OpenUri transfers first in that case.
    public private(set) var controlsPresent = false
    public private(set) var identity = ""
    public private(set) var status = "Stopped"
    public private(set) var title = ""
    public private(set) var artist = ""
    public private(set) var album = ""
    public private(set) var artURL = ""
    public private(set) var trackId = ""
    public private(set) var trackUri = ""
    public private(set) var lengthUs: Int64 = 0
    public private(set) var positionUs: Int64 = 0
    /// Connect mixer, 0…1. Not the Pulse sink.
    public private(set) var volume: Double = 1
    public private(set) var canGoNext = false
    public private(set) var canGoPrevious = false
    public private(set) var canPlay = false
    public private(set) var canPause = false
    public private(set) var canSeek = false
    public private(set) var canControl = false

    public var isPlaying: Bool { status == "Playing" }
    public var positionMs: Int { Int(positionUs / 1000) }
    public var lengthMs: Int { Int(lengthUs / 1000) }
    public var volumePercent: Int { Int((min(1, max(0, volume)) * 100).rounded()) }

    /// What the strip prints when a title has not arrived yet.
    public var stripTitle: String {
        if !title.isEmpty { return title }
        if !identity.isEmpty { return identity }
        return "Music"
    }

    public var artistLine: String {
        if !artist.isEmpty, !album.isEmpty { return "\(artist) — \(album)" }
        if !artist.isEmpty { return artist }
        return album
    }

    private var handle: OpaquePointer?
    private var box: Unmanaged<MprisSession>?
    private var lastSkip: TimeInterval = 0
    /// Fired when the last player leaves the bus, so the panel can drop a
    /// popover that would otherwise keep the input region tall over nothing.
    public var onAbsent: (() -> Void)?
    /// Every snapshot, including position ticks. Hopped to `MainQueue`.
    public var onUpdate: (() -> Void)?

    public init(spotifydOnly: Bool = false) {
        let unmanaged = Unmanaged.passRetained(self)
        box = unmanaged
        let flags: UInt32 = spotifydOnly ? UInt32(LAVA_MPRIS_SPOTIFYD_ONLY) : 0
        handle = lava_mpris_create_with_flags({ user, snap in
            guard let user, let snap else { return }
            let session = Unmanaged<MprisSession>.fromOpaque(user).takeUnretainedValue()
            let copy = Snapshot(c: snap.pointee)
            MainQueue.async { session.apply(copy) }
        }, unmanaged.toOpaque(), flags)

        if handle == nil {
            unmanaged.release()
            box = nil
            FileHandle.standardError.write(
                Data("LavaMpris: session bus unavailable\n".utf8)
            )
        } else {
            let kind = spotifydOnly ? "spotifyd only" : "org.mpris.MediaPlayer2.*"
            FileHandle.standardError.write(
                Data("LavaMpris: watching \(kind)\n".utf8)
            )
        }
    }

    deinit {
        if let handle { lava_mpris_destroy(handle) }
        box?.release()
    }

    public func next() { if let handle { lava_mpris_next(handle) } }
    public func previous() { if let handle { lava_mpris_previous(handle) } }
    public func playPause() { if let handle { lava_mpris_play_pause(handle) } }
    public func play() { if let handle { lava_mpris_play(handle) } }
    public func pause() { if let handle { lava_mpris_pause(handle) } }
    public func stop() { if let handle { lava_mpris_stop(handle) } }
    public func transferPlayback() { if let handle { lava_mpris_transfer_playback(handle) } }

    public func openUri(_ uri: String) {
        guard let handle, !uri.isEmpty else { return }
        uri.withCString { lava_mpris_open_uri(handle, $0) }
    }

    public func seek(offsetUs: Int64) {
        if let handle { lava_mpris_seek(handle, offsetUs) }
    }

    public func setPosition(us: Int64) {
        if let handle { lava_mpris_set_position(handle, max(0, us)) }
    }

    public func setVolume(_ value: Double) {
        if let handle { lava_mpris_set_volume(handle, min(1, max(0, value))) }
    }

    /// One skip per detent, not per trackpad pixel. A flick would otherwise
    /// walk half the album.
    public func skipByWheel(dy: Float) {
        let now = Date().timeIntervalSince1970
        guard now - lastSkip > 0.25 else { return }
        lastSkip = now
        if dy > 0 {
            next()
        } else if dy < 0 {
            previous()
        }
    }

    private func apply(_ snap: Snapshot) {
        let gone = present && !snap.present
        let playerChanged = snap.present && identity != snap.identity
        let chromeChanged =
            present != snap.present
            || controlsPresent != snap.controlsPresent
            || identity != snap.identity
            || status != snap.status
            || title != snap.title
            || artist != snap.artist
            || album != snap.album
            || artURL != snap.artURL
            || canGoNext != snap.canGoNext
            || canGoPrevious != snap.canGoPrevious
            || canPlay != snap.canPlay
            || canPause != snap.canPause

        present = snap.present
        controlsPresent = snap.controlsPresent
        identity = snap.identity
        status = snap.status
        title = snap.title
        artist = snap.artist
        album = snap.album
        artURL = snap.artURL
        trackId = snap.trackId
        trackUri = snap.trackUri
        lengthUs = snap.lengthUs
        positionUs = snap.positionUs
        volume = snap.volume
        canGoNext = snap.canGoNext
        canGoPrevious = snap.canGoPrevious
        canPlay = snap.canPlay
        canPause = snap.canPause
        canSeek = snap.canSeek
        canControl = snap.canControl

        if gone { onAbsent?() }
        if playerChanged {
            FileHandle.standardError.write(
                Data("LavaMpris: player \(snap.identity)\n".utf8)
            )
        }
        // Position ticks must not redraw the panel; Observation invalidates
        // only views that actually read position/volume.
        if chromeChanged { ViewInvalidation.markNeedsRedraw() }
        onUpdate?()
    }

    private struct Snapshot {
        var present: Bool
        var controlsPresent: Bool
        var identity: String
        var status: String
        var title: String
        var artist: String
        var album: String
        var artURL: String
        var trackId: String
        var trackUri: String
        var lengthUs: Int64
        var positionUs: Int64
        var volume: Double
        var canGoNext: Bool
        var canGoPrevious: Bool
        var canPlay: Bool
        var canPause: Bool
        var canSeek: Bool
        var canControl: Bool

        init(c: LavaMprisSnapshot) {
            present = c.present != 0
            controlsPresent = c.controls_present != 0
            identity = c.identity.map { String(cString: $0) } ?? ""
            status = c.status.map { String(cString: $0) } ?? "Stopped"
            title = c.title.map { String(cString: $0) } ?? ""
            artist = c.artist.map { String(cString: $0) } ?? ""
            album = c.album.map { String(cString: $0) } ?? ""
            artURL = c.art_url.map { String(cString: $0) } ?? ""
            trackId = c.track_id.map { String(cString: $0) } ?? ""
            trackUri = c.track_uri.map { String(cString: $0) } ?? ""
            lengthUs = c.length_us
            positionUs = c.position_us
            volume = c.volume
            canGoNext = c.can_go_next != 0
            canGoPrevious = c.can_go_previous != 0
            canPlay = c.can_play != 0
            canPause = c.can_pause != 0
            canSeek = c.can_seek != 0
            canControl = c.can_control != 0
        }
    }
}
