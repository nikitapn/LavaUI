import Foundation
import LavaHost
import LavaPlayerCore
import LavaUI
import Observation

/// What the window shows, and the things a button can ask for.
///
/// Observed, so a change to anything here rebuilds the bars. The frame itself
/// is not here: it changes every video frame, and the paint closure reads it
/// from `Player` directly — a body pass per frame to move a texture id would
/// be pure waste.
@Observable
final class PlayerSession: @unchecked Sendable {
    enum Dialog {
        case about
        case settings
    }

    private static let recentFilesKey = "recentFiles"
    private static let resumePlaybackKey = "resumePlayback"

    private(set) var playlist = Playlist()
    private(set) var state = Player.State()
    private(set) var error: String?
    private(set) var recentFiles = Array(
        (AppSettings.value(forKey: recentFilesKey, as: [String].self) ?? []).prefix(10)
    )
    private(set) var resumePlayback = AppSettings.bool(forKey: resumePlaybackKey) ?? false
    private(set) var mpvVersion: String?
    var dialog: Dialog?
    @ObservationIgnored private var lastCheckpoint = FrameScheduler.now()

    /// Whether the window covers the screen. The bars hide while it does,
    /// and come back while the pointer moves.
    private(set) var fullscreen = false
    /// When the pointer last moved over the video, for the bars' auto-hide.
    @ObservationIgnored private var lastPointerMove: Double = 0
    /// Whether the pointer is on the floating bar, from its `onHover`. A
    /// pointer resting there sends the video no moves at all, so without this
    /// the bar would hide from under the hand using it.
    @ObservationIgnored private var pointerOnBar = false
    /// The video box's width, which the floating bar is laid out from —
    /// observed, so a change rebuilds the bar. It changes only when the
    /// screen does.
    private(set) var screenWidth: Float = 0

    /// From paint, every frame; only a change does anything.
    func noteScreen(width: Float) {
        if width != screenWidth {
            screenWidth = width
            ViewInvalidation.markDirty()
        }
    }
    private(set) var barsVisible = true
    @ObservationIgnored private var subtitleMargin = PlayerSession.defaultSubtitleMargin
    static let defaultSubtitleMargin = 22

    @ObservationIgnored let player: Player

    init(host: any GPUResourceHost, playlist: Playlist) {
        player = Player(host: host)
        self.playlist = playlist
        player.onState = { [unowned self] next in
            let justPaused = next.paused && !state.paused
            state = hasMedia ? next : Player.State(volume: next.volume, muted: next.muted)
            // Client windows can be closed by the compositor without
            // returning through the app's main loop.
            if justPaused || FrameScheduler.now() - lastCheckpoint >= 10 {
                savePlaybackPosition(wait: false)
            }
        }
        player.onEndOfFile = { [unowned self] in endOfFile() }
        player.onError = { [unowned self] message in
            guard hasMedia else { return }
            error = "Could not play \(currentName): \(message)"
        }
    }

    func start() -> Bool {
        guard player.start(resumePlayback: resumePlayback) else { return false }
        mpvVersion = player.version
        if let current = playlist.current {
            player.load(current)
            rememberOpenedFile()
        }
        return true
    }

    // MARK: - Reading

    var currentName: String {
        guard let path = playlist.current else { return "LavaPlayer" }
        if path.contains("://") { return state.title ?? path }
        return (path as NSString).lastPathComponent
    }

    var hasMedia: Bool { playlist.current != nil }
    var currentFile: String? {
        guard let path = playlist.current, path.hasPrefix("/") else { return nil }
        return path
    }
    var hasVideo: Bool { state.videoWidth > 0 && state.videoHeight > 0 }

    /// Where the seek bar is being dragged to, 0…1; nil when it is not.
    ///
    /// While set, the bar and the clock show this rather than mpv's position.
    /// A drag seeks to keyframes, so mpv reports the keyframe it landed on —
    /// and a knob that followed that would jump back from under the pointer.
    private(set) var scrub: Float?
    /// The seek bar is held. `scrub` is nil until the first value arrives.
    @ObservationIgnored private var scrubbing = false

    /// 0…1 along the seek bar; 0 when the length is not known.
    var progress: Float {
        if let scrub { return scrub }
        guard let duration = state.duration, duration > 0,
              let position = state.position
        else { return 0 }
        return Float(min(1, max(0, position / duration)))
    }

    // MARK: - Opening

    /// A drop or a command line. Subtitle files among the paths are loaded
    /// into what is playing instead: dropping `Movie.srt` on a playing
    /// `Movie.mkv` means "with these", never "play this text file".
    func open(paths: [String]) {
        let subtitles = paths.filter(MediaFormats.isSubtitle(path:))
        let media = paths.filter { !MediaFormats.isSubtitle(path: $0) }
        if media.isEmpty {
            guard hasMedia else { return }
            for path in subtitles { player.addSubtitles(path) }
            return
        }
        openMedia(media)
    }

    private func openMedia(_ paths: [String]) {
        let next = Playlist.from(paths: paths)
        guard let current = next.current else { return }
        savePlaybackPosition()
        playlist = next
        error = nil
        player.load(current)
        rememberOpenedFile()
    }

    private func rememberOpenedFile() {
        guard let path = currentFile else { return }
        var updated: [String] = []
        AppSettings.update([String].self, forKey: Self.recentFilesKey) { stored in
            updated = Array(([path] + (stored ?? []).filter { $0 != path }).prefix(10))
            return updated
        }
        recentFiles = updated
        LavaHost.noteOpened(path, appId: "LavaPlayer")
    }

    func openRecentFile(_ path: String) {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory),
              !directory.boolValue else {
            error = "File no longer exists: \((path as NSString).lastPathComponent)"
            return
        }
        openMedia([path])
    }

    func clearRecentFiles() {
        recentFiles = []
        AppSettings.set(recentFiles, forKey: Self.recentFilesKey)
    }

    func revealCurrentFile() {
        guard let path = currentFile else { return }
        let folder = (path as NSString).deletingLastPathComponent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xdg-open", folder]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            guard process.terminationStatus != 0 else { return }
            MainQueue.async { [weak self] in
                self?.error = "Could not open file location"
            }
        }
        do {
            try process.run()
        } catch {
            self.error = "Could not open file location"
        }
    }

    func closeMedia() {
        guard hasMedia else { return }
        savePlaybackPosition()
        player.unload()
        playlist = Playlist()
        state = Player.State(volume: state.volume, muted: state.muted)
        error = nil
        scrub = nil
        scrubbing = false
        closeTrackMenu()
        leaveFullscreen()
    }

    func openDialog() {
        let urls = FileDialog.openFiles(
            title: "Open Video",
            filters: [.init(name: "Media", extensions: MediaFormats.dialogExtensions)]
        )
        guard !urls.isEmpty else { return }
        open(paths: urls.map(\.path))
    }

    func openSubtitlesDialog() {
        guard hasMedia else { return }
        let urls = FileDialog.openFiles(
            title: "Load Subtitles",
            filters: [.init(name: "Subtitles", extensions: MediaFormats.subtitles.sorted())]
        )
        for url in urls { player.addSubtitles(url.path) }
    }

    func step(_ by: Int) {
        let next = playlist.stepped(by: by)
        guard next.index != playlist.index, let current = next.current else { return }
        savePlaybackPosition()
        playlist = next
        error = nil
        player.load(current)
    }

    private func endOfFile() {
        guard state.path == playlist.current else { return }
        if let path = currentFile { player.forgetPlaybackPosition(path) }
        if playlist.playsThrough, playlist.hasNext { step(1) }
    }

    func setResumePlayback(_ enabled: Bool) {
        resumePlayback = enabled
        AppSettings.set(enabled, forKey: Self.resumePlaybackKey)
        player.setResumePlayback(enabled)
        if enabled { savePlaybackPosition() }
    }

    func savePlaybackPosition(wait: Bool = true) {
        guard resumePlayback, let path = currentFile, state.path == path,
              let position = state.position, position > 0, !state.eofReached else { return }
        player.savePlaybackPosition(wait: wait)
        lastCheckpoint = FrameScheduler.now()
    }

    // MARK: - Transport

    func togglePause() { player.togglePause() }
    /// What the clock reads: the drag target while scrubbing.
    var shownPosition: Double? {
        if let scrub, let duration = state.duration { return Double(scrub) * duration }
        return state.position
    }

    /// From the seek bar. While it is held, a keyframe seek per move: mpv
    /// shows the nearest keyframe at once, where an exact seek decodes from
    /// that keyframe up to the frame and is cancelled by the next move before
    /// it gets there. The exact seek happens once, on release — so a click,
    /// which is a press and a release, still lands on the frame.
    func seek(fraction: Float) {
        guard let duration = state.duration, duration > 0 else { return }
        guard scrubbing else {
            player.seek(to: Double(fraction) * duration, exact: true)
            return
        }
        // Pointer moves outnumber pixels of travel; a seek to where mpv is
        // already going is work it would only throw away.
        guard fraction != scrub else { return }
        scrub = fraction
        player.seek(to: Double(fraction) * duration, exact: false)
    }

    func seekBarEditing(_ editing: Bool) {
        scrubbing = editing
        guard !editing, let target = scrub else { return }
        scrub = nil
        if let duration = state.duration, duration > 0 {
            player.seek(to: Double(target) * duration, exact: true)
        }
    }
    func seek(by seconds: Double) { player.seek(by: seconds) }
    func setVolume(_ volume: Float) { player.setVolume(Double(volume)) }
    func nudgeVolume(_ by: Double) { player.setVolume(state.volume + by) }
    func toggleMute() { player.toggleMute() }
    func stepFrame(_ direction: Int) { player.stepFrame(direction) }

    // MARK: - Tracks

    var subtitleTracks: [Track] { state.tracks.of(.subtitle) }
    var audioTracks: [Track] { state.tracks.of(.audio) }
    var selectedSubtitle: Int? { state.tracks.selected(.subtitle) }

    func selectSubtitles(_ id: Int?) { player.select(.subtitle, id: id) }
    func selectAudio(_ id: Int) { player.select(.audio, id: id) }
    func cycleSubtitles(backwards: Bool = false) { player.cycleSubtitles(backwards: backwards) }
    /// The next audio track, wrapping. Not mpv's `cycle audio`, which steps
    /// onto "no audio" on the way round.
    func cycleAudio() {
        if let next = state.tracks.next(.audio) { player.select(.audio, id: next) }
    }
    var selectedAudio: Track? { audioTracks.first(where: \.isSelected) }
    func toggleSubtitlesVisible() { player.toggleSubtitlesVisible() }

    /// Which track button's list is open, if either. Holds the floating bar
    /// up while it is: a menu whose button hid from under it would be left
    /// pointing at nothing.
    private(set) var trackMenu: Track.Kind?
    func toggleTrackMenu(_ kind: Track.Kind) {
        trackMenu = trackMenu == kind ? nil : kind
        noteActivity()
    }
    func closeTrackMenu() {
        guard trackMenu != nil else { return }
        trackMenu = nil
        noteActivity()
    }
    func nudgeSubtitleDelay(_ seconds: Double) { player.nudgeSubtitleDelay(seconds) }

    // MARK: - Fullscreen and the bars

    static let barsLinger: Double = 2.5

    func toggleFullscreen() {
        guard let set = WindowBridge.setFullscreen else {
            WindowBridge.toggleMaximize?()
            return
        }
        fullscreen.toggle()
        set(fullscreen)
        noteActivity()
    }

    func leaveFullscreen() {
        guard fullscreen else { return }
        toggleFullscreen()
    }

    /// The pointer moved: show the bars, and look again when they are due to
    /// go. `requestRedraw`, not `requestWake` — nothing else will dirty the
    /// window when the pointer stops, and the deadline *is* the event.
    func noteBarHover(_ inside: Bool) {
        pointerOnBar = inside
        // Leaving the bar is activity too: the pointer is on the video now,
        // and the bars owe it the full linger before they go.
        noteActivity()
    }

    func noteActivity() {
        lastPointerMove = FrameScheduler.now()
        if !barsVisible { barsVisible = true }
        if fullscreen { FrameScheduler.requestRedraw(in: Self.barsLinger + 0.05) }
    }

    /// From paint: hide the bars once the pointer has rested long enough.
    /// Only in fullscreen, and never while paused — a paused video with no
    /// controls on it looks like a frozen one.
    func updateBars() {
        let wanted = !fullscreen || state.paused || !hasMedia || pointerOnBar
            || trackMenu != nil
            || FrameScheduler.now() - lastPointerMove < Self.barsLinger
        if wanted != barsVisible {
            barsVisible = wanted
            ViewInvalidation.markDirty()
        }
    }

    /// From paint, with the video box's height. While the floating bar is
    /// up, subtitles move above it — what mpv's own controller does — and
    /// back down when it goes. Only text subtitles, and ASS ones only where
    /// their style leaves the margin to the player.
    func placeSubtitles(screenHeight: Float) {
        var margin = Self.defaultSubtitleMargin
        if fullscreen, barsVisible, screenHeight > 0 {
            let clear = TransportBar.floatingInset + TransportBar.height + 8
            margin = max(margin, Int((clear * 720 / screenHeight).rounded(.up)))
        }
        guard margin != subtitleMargin else { return }
        subtitleMargin = margin
        player.setSubtitleMargin(margin)
    }

    /// No pointer over a fullscreen video once its controls have gone, the
    /// way every player does it; the next move brings both back.
    var hidesCursor: Bool { fullscreen && !barsVisible }

    func dismissError() { error = nil }

    func shutdown() {
        savePlaybackPosition()
        player.stop()
    }
}
