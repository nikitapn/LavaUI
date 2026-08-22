import CMpris
import Foundation
import LavaUI
import Observation

/// Live view of the session's MPRIS player, preferring spotifyd.
///
/// sd-bus callbacks run on a private event thread; every snapshot is copied
/// and hopped onto `MainQueue` before touching `@Observable` properties.
@Observable
final class MprisSession: @unchecked Sendable {
    private(set) var present = false
    private(set) var identity = ""
    private(set) var status = "Stopped"
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var album = ""
    private(set) var artURL = ""
    private(set) var canGoNext = false
    private(set) var canGoPrevious = false
    private(set) var canPlay = false
    private(set) var canPause = false

    var isPlaying: Bool { status == "Playing" }

    /// What the strip prints when a title has not arrived yet.
    var stripTitle: String {
        if !title.isEmpty { return title }
        if !identity.isEmpty { return identity }
        return "Music"
    }

    var artistLine: String {
        if !artist.isEmpty, !album.isEmpty { return "\(artist) — \(album)" }
        if !artist.isEmpty { return artist }
        return album
    }

    private var handle: OpaquePointer?
    private var box: Unmanaged<MprisSession>?
    private var lastSkip: TimeInterval = 0
    /// Fired when the last player leaves the bus, so the panel can drop a
    /// popover that would otherwise keep the input region tall over nothing.
    var onAbsent: (() -> Void)?

    init() {
        let unmanaged = Unmanaged.passRetained(self)
        box = unmanaged
        handle = lava_mpris_create({ user, snap in
            guard let user, let snap else { return }
            let session = Unmanaged<MprisSession>.fromOpaque(user).takeUnretainedValue()
            let copy = Snapshot(c: snap.pointee)
            MainQueue.async { session.apply(copy) }
        }, unmanaged.toOpaque())

        if handle == nil {
            unmanaged.release()
            box = nil
            FileHandle.standardError.write(
                Data("LavaTaskbar: MPRIS unavailable\n".utf8)
            )
        } else {
            FileHandle.standardError.write(
                Data("LavaTaskbar: MPRIS watching org.mpris.MediaPlayer2.*\n".utf8)
            )
        }
    }

    deinit {
        if let handle { lava_mpris_destroy(handle) }
        box?.release()
    }

    func next() { if let handle { lava_mpris_next(handle) } }
    func previous() { if let handle { lava_mpris_previous(handle) } }
    func playPause() { if let handle { lava_mpris_play_pause(handle) } }

    /// One skip per detent, not per trackpad pixel. A flick would otherwise
    /// walk half the album.
    func skipByWheel(dy: Float) {
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
        present = snap.present
        identity = snap.identity
        status = snap.status
        title = snap.title
        artist = snap.artist
        album = snap.album
        artURL = snap.artURL
        canGoNext = snap.canGoNext
        canGoPrevious = snap.canGoPrevious
        canPlay = snap.canPlay
        canPause = snap.canPause
        if gone { onAbsent?() }
        if playerChanged {
            FileHandle.standardError.write(
                Data("LavaTaskbar: MPRIS player \(snap.identity)\n".utf8)
            )
        }
        ViewInvalidation.markNeedsRedraw()
    }

    private struct Snapshot {
        var present: Bool
        var identity: String
        var status: String
        var title: String
        var artist: String
        var album: String
        var artURL: String
        var canGoNext: Bool
        var canGoPrevious: Bool
        var canPlay: Bool
        var canPause: Bool

        init(c: LavaMprisSnapshot) {
            present = c.present != 0
            identity = c.identity.map { String(cString: $0) } ?? ""
            status = c.status.map { String(cString: $0) } ?? "Stopped"
            title = c.title.map { String(cString: $0) } ?? ""
            artist = c.artist.map { String(cString: $0) } ?? ""
            album = c.album.map { String(cString: $0) } ?? ""
            artURL = c.art_url.map { String(cString: $0) } ?? ""
            canGoNext = c.can_go_next != 0
            canGoPrevious = c.can_go_previous != 0
            canPlay = c.can_play != 0
            canPause = c.can_pause != 0
        }
    }
}
