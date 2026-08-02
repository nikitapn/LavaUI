import Foundation
import LavaUI
import Observation
import SpotifyCore

private enum SpotifyHistoryDestination {
    case home
    case search
    case library
    case album(Album, tracks: [Track])
    case artist(Artist, albums: [Album])
}

/// Shared navigation + catalog + Connect playback state for LavaSpotify.
///
/// Playback targets Spotify Connect devices (spotifyd when present) via the
/// Web API Player endpoints. That needs a **user** OAuth login — client
/// credentials alone cannot call `/me/player/*`.
@Observable
final class SpotifySession: @unchecked Sendable {
    var nav: SpotifyNav = .home
    var sections: [CatalogSection] = []
    var searchQuery: String = ""
    var searchResults: [Album] = []
    var quickSearchResults: [Track] = []
    var isQuickSearching = false
    var libraryAlbums: [Album] = []
    var isThemePickerPresented = false
    var themePickerSelection = SpotifyTheme.selectedIndex

    var detailAlbum: Album?
    var detailTracks: [Track] = []
    var detailArtist: Artist?
    var artistAlbums: [Album] = []

    var nowPlaying: Track?
    var isPlaying: Bool = false
    /// Playback position, ms. Updated by Connect poll and by the progress slider.
    var progressMs: Int = 0
    /// True while the user is dragging the seek slider (or a seek is in flight).
    var isScrubbing: Bool = false
    /// Active Connect-device volume. Updated immediately while dragging.
    var volumePercent: Int = 50
    var isAdjustingVolume: Bool = false
    var activeDeviceName: String?

    var devices: [SpotifyDevice] = []
    var selectedDeviceId: String?

    var status: String = "Loading catalog…"
    var notice: String?
    var isLoading: Bool = false
    var isLoggedIn: Bool = false

    let client = SpotifyClient()
    let editor: Editor
    /// A larger instance of the media-symbol face for compact player chrome.
    let playerControlFont: UIFont?

    private var pollStop = false
    /// Bumped on every scrub so only the latest seek request is sent.
    private var seekGeneration: UInt64 = 0
    /// Bumped for every slider tick so remote volume writes are coalesced.
    private var volumeGeneration: UInt64 = 0
    /// Latest value sent to Connect. Poll snapshots remain stale for a short
    /// window after the PUT, so they must not overwrite the slider until the
    /// device acknowledges this value (or the guard times out).
    private var pendingVolumePercent: Int?
    private var searchGeneration: UInt64 = 0
    /// Wall time of last Connect snapshot (for local progress extrapolation).
    private var progressAnchor: Date = .distantPast
    private var progressAnchorMs: Int = 0
    private var navigationHistory: [SpotifyHistoryDestination] = []

    init(editor: Editor) {
        self.editor = editor
        if let path = FontStore.symbols?.path,
           let font = UIFont(path: path, pixelSize: 20),
           font.registerWithEngine(editor)
        {
            self.playerControlFont = font
        } else {
            self.playerControlFont = FontStore.symbols
        }
        self.isLoggedIn = client.isUserLoggedIn
    }

    /// Duration of the current track for the seek slider range (at least 1 ms).
    var durationMs: Int {
        max(1, nowPlaying?.durationMs ?? 1)
    }

    /// Binding-friendly progress in 0…durationMs.
    var progressSliderValue: Float {
        get { Float(min(progressMs, durationMs)) }
        set { scrub(toMs: Int(newValue.rounded())) }
    }

    // MARK: - Themes

    func showThemePicker() {
        themePickerSelection = SpotifyTheme.selectedIndex
        isThemePickerPresented = true
        FocusManager.clear()
    }

    func previewTheme(_ index: Int) {
        guard SpotifyTheme.palettes.indices.contains(index) else { return }
        themePickerSelection = index
        // Live preview only — do not write settings until the user commits.
        SpotifyTheme.apply(index, persist: false)
    }

    func moveThemeSelection(_ delta: Int) {
        let count = SpotifyTheme.palettes.count
        guard count > 0 else { return }
        previewTheme((themePickerSelection + delta + count) % count)
    }

    func chooseTheme(_ index: Int) {
        guard SpotifyTheme.palettes.indices.contains(index) else { return }
        themePickerSelection = index
        SpotifyTheme.apply(index, persist: true)
        isThemePickerPresented = false
    }

    func handleThemeKey(_ event: InputEvent) -> Bool {
        guard event.kind == .key, KeyAction.isDown(event.keyAction) else { return false }
        if event.keyCode == KeyCode.t,
           KeyMods.contains(event.keyMods, KeyMods.control)
        {
            if isThemePickerPresented {
                isThemePickerPresented = false
            } else {
                showThemePicker()
            }
            return true
        }
        guard isThemePickerPresented else { return false }
        switch event.keyCode {
        case KeyCode.up:
            moveThemeSelection(-1)
            return true
        case KeyCode.down:
            moveThemeSelection(1)
            return true
        case KeyCode.enter:
            chooseTheme(themePickerSelection)
            return true
        default:
            return false
        }
    }

    // MARK: - Bootstrap

    func start() {
        isLoggedIn = client.isUserLoggedIn
        isLoading = true
        status = client.hasCredentials || isLoggedIn
            ? "Loading from Spotify Web API…"
            : "Loading seed catalog…"
        notice = bootstrapNotice()

        Thread.detachNewThread { [client] in
            do {
                let sections = try client.loadHome()
                MainQueue.async { [weak self] in
                    guard let self else { return }
                    self.sections = sections
                    self.libraryAlbums = sections.flatMap(\.albums)
                    self.isLoading = false
                    let n = self.libraryAlbums.count
                    self.status = (self.client.hasCredentials || self.isLoggedIn)
                        ? "Live catalog · \(n) albums"
                        : "Seed catalog · \(n) albums"
                    self.notice = self.bootstrapNotice()
                }
            } catch {
                MainQueue.async { [weak self] in
                    guard let self else { return }
                    self.isLoading = false
                    self.status = "Failed to load catalog"
                    self.notice = "\(error)"
                    self.report("\(error)")
                }
            }
        }

        if isLoggedIn {
            refreshDevices()
            startPlaybackPolling()
        }
    }

    private func bootstrapNotice() -> String? {
        if !client.hasCredentials && !isLoggedIn {
            return "Seed mode. Set SPOTIFY_CLIENT_ID/SECRET for live catalog; Account → Log in to control spotifyd."
        }
        if client.hasCredentials && !isLoggedIn {
            return "Catalog live. Log in (Account menu) to play through spotifyd / Connect."
        }
        if isLoggedIn && devices.isEmpty {
            return "Logged in, but no Connect devices. Run: spotifyd authenticate && systemctl --user restart spotifyd"
        }
        if let name = activeDeviceName {
            return "Playing via \(name)"
        }
        if let id = selectedDeviceId,
           let dev = devices.first(where: { $0.id == id })
        {
            return "Device: \(dev.name)"
        }
        return nil
    }

    // MARK: - Account / devices

    func login() {
        status = "Waiting for Spotify login in browser…"
        Thread.detachNewThread { [client] in
            do {
                try client.loginInteractive()
                MainQueue.async { [weak self] in
                    guard let self else { return }
                    self.isLoggedIn = true
                    self.status = "Logged in"
                    self.notice = self.bootstrapNotice()
                    self.refreshDevices()
                    self.startPlaybackPolling()
                    // Refresh catalog with user token if we were on seed-only.
                    self.start()
                }
            } catch {
                MainQueue.async { [weak self] in
                    guard let self else { return }
                    self.status = "Login failed"
                    self.notice = "\(error)"
                    self.report("\(error)")
                }
            }
        }
    }

    func logout() {
        client.logout()
        isLoggedIn = false
        devices = []
        selectedDeviceId = nil
        activeDeviceName = nil
        isPlaying = false
        notice = bootstrapNotice()
        status = "Logged out"
        pollStop = true
    }

    func refreshDevices() {
        guard isLoggedIn else {
            status = "Log in first (Account menu)"
            return
        }
        Thread.detachNewThread { [client] in
            do {
                let list = try client.listDevices()
                let preferred = try? client.resolvePlaybackDevice(among: list)
                MainQueue.async { [weak self] in
                    guard let self else { return }
                    self.devices = list
                    if let preferred {
                        self.selectedDeviceId = preferred.id
                    } else if self.selectedDeviceId == nil {
                        self.selectedDeviceId = list.first?.id
                    }
                    let names = list.map { "\($0.name)\($0.isActive ? "*" : "")" }
                        .joined(separator: ", ")
                    if list.isEmpty {
                        self.status = "No Connect devices on account"
                        self.notice = SpotifyClient.emptyDevicesHint
                        self.report(SpotifyClient.emptyDevicesHint)
                    } else {
                        self.status = "Devices: \(names)"
                        self.notice = self.bootstrapNotice()
                        if let preferred {
                            self.report(
                                "using device “\(preferred.name)” "
                                    + "(\(preferred.type)"
                                    + (preferred.looksLikeSpotifyd ? ", looks like spotifyd" : "")
                                    + ")"
                            )
                        }
                    }
                }
            } catch {
                MainQueue.async { [weak self] in
                    guard let self else { return }
                    self.notice = "\(error)"
                    self.status = "Device list failed"
                    self.report("\(error)")
                }
            }
        }
    }

    // MARK: - Navigation

    func goHome() {
        guard nav != .home else { return }
        rememberCurrentDestination()
        showHome()
    }

    private func showHome() {
        nav = .home
        detailAlbum = nil
        detailTracks = []
        detailArtist = nil
        artistAlbums = []
    }

    func goSearch() {
        guard nav != .search else { return }
        rememberCurrentDestination()
        nav = .search
        detailAlbum = nil
        detailTracks = []
        detailArtist = nil
        artistAlbums = []
    }

    func goLibrary() {
        guard nav != .library else { return }
        rememberCurrentDestination()
        nav = .library
        detailAlbum = nil
        detailTracks = []
        detailArtist = nil
        artistAlbums = []
    }

    func openAlbum(_ album: Album, rememberingCurrent: Bool = true) {
        if rememberingCurrent { rememberCurrentDestination() }
        nav = .album(album.id)
        detailAlbum = album
        detailArtist = nil
        artistAlbums = []
        if !client.hasCredentials && !isLoggedIn {
            detailTracks = SeedCatalog.tracks(for: album.id, album: album)
            isLoading = false
            status = "\(album.name) · \(detailTracks.count) tracks"
            return
        }
        detailTracks = []
        status = "Loading \(album.name)…"
        isLoading = true
        let id = album.id
        Thread.detachNewThread { [client] in
            do {
                let (full, tracks) = try client.albumDetail(id: id)
                MainQueue.async { [weak self] in
                    guard let self, self.nav == .album(id) else { return }
                    self.detailAlbum = full
                    self.detailTracks = tracks
                    self.isLoading = false
                    self.status = "\(full.name) · \(tracks.count) tracks"
                }
            } catch {
                MainQueue.async { [weak self] in
                    guard let self, self.nav == .album(id) else { return }
                    self.isLoading = false
                    self.notice = "\(error)"
                    self.status = "Could not open album"
                    self.report("\(error)")
                }
            }
        }
    }

    func openArtist(_ artist: ArtistRef, rememberingCurrent: Bool = true) {
        dismissQuickSearch()
        if rememberingCurrent { rememberCurrentDestination() }
        nav = .artist(artist.id)
        detailAlbum = nil
        detailTracks = []
        detailArtist = Artist(id: artist.id, name: artist.name)
        artistAlbums = []
        status = "Loading \(artist.name)…"
        isLoading = true
        let id = artist.id
        Thread.detachNewThread { [client] in
            do {
                let result = try client.artistDetail(id: id, fallbackName: artist.name)
                MainQueue.async { [weak self] in
                    guard let self, self.nav == .artist(id) else { return }
                    self.detailArtist = result.artist
                    self.artistAlbums = result.albums
                    self.isLoading = false
                    self.status = "\(result.artist.name) · \(result.albums.count) releases"
                }
            } catch {
                MainQueue.async { [weak self] in
                    guard let self, self.nav == .artist(id) else { return }
                    self.isLoading = false
                    self.notice = "\(error)"
                    self.status = "Could not open artist"
                    self.report("artist: \(error)")
                }
            }
        }
    }

    func goBack() {
        guard let destination = navigationHistory.popLast() else {
            showHome()
            return
        }
        switch destination {
        case .home:
            showHome()
        case .search:
            nav = .search
            detailAlbum = nil
            detailTracks = []
            detailArtist = nil
            artistAlbums = []
        case .library:
            nav = .library
            detailAlbum = nil
            detailTracks = []
            detailArtist = nil
            artistAlbums = []
        case .album(let album, let tracks):
            nav = .album(album.id)
            detailAlbum = album
            detailTracks = tracks
            detailArtist = nil
            artistAlbums = []
            isLoading = false
            status = "\(album.name) · \(tracks.count) tracks"
        case .artist(let artist, let albums):
            nav = .artist(artist.id)
            detailAlbum = nil
            detailTracks = []
            detailArtist = artist
            artistAlbums = albums
            isLoading = false
            status = "\(artist.name) · \(albums.count) releases"
        }
    }

    private func rememberCurrentDestination() {
        let destination: SpotifyHistoryDestination?
        switch nav {
        case .home:
            destination = .home
        case .search:
            destination = .search
        case .library:
            destination = .library
        case .album(let id):
            let album = detailAlbum
                ?? Album(id: id, name: "Album", artists: [], images: [])
            destination = .album(album, tracks: detailTracks)
        case .artist(let id):
            let artist = detailArtist ?? Artist(id: id, name: "Artist")
            destination = .artist(artist, albums: artistAlbums)
        }
        if let destination { navigationHistory.append(destination) }
    }

    /// Opens the album represented by the player footer. Locally selected
    /// tracks may inherit their album from the current detail page; remote
    /// Connect snapshots normally carry the album directly.
    func openNowPlayingAlbum() {
        guard let track = nowPlaying else { return }
        if let album = track.album {
            openAlbum(album)
            return
        }
        if let album = detailAlbum,
           detailTracks.contains(where: { $0.id == track.id })
        {
            openAlbum(album)
        }
    }

    func runSearch() {
        let q = searchQuery
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        isLoading = true
        status = "Searching “\(q)”…"
        Thread.detachNewThread { [client] in
            do {
                let hits = try client.search(query: q)
                MainQueue.async { [weak self] in
                    guard let self else { return }
                    self.searchResults = hits
                    self.isLoading = false
                    self.status = "\(hits.count) results for “\(q)”"
                }
            } catch {
                MainQueue.async { [weak self] in
                    guard let self else { return }
                    self.isLoading = false
                    self.notice = "\(error)"
                    self.status = "Search failed"
                    self.report("\(error)")
                }
            }
        }
    }

    /// Debounced Home search. Generation checks make stale network responses
    /// harmless when the user types faster than Spotify replies.
    func updateQuickSearch(_ query: String) {
        searchQuery = query
        searchGeneration &+= 1
        let generation = searchGeneration
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            quickSearchResults = []
            isQuickSearching = false
            return
        }
        isQuickSearching = true
        Thread.detachNewThread { [client] in
            Thread.sleep(forTimeInterval: 0.22)
            do {
                let tracks = try client.searchTracks(query: trimmed, limit: 8)
                MainQueue.async { [weak self] in
                    guard let self, self.searchGeneration == generation else { return }
                    self.quickSearchResults = tracks
                    self.isQuickSearching = false
                }
            } catch {
                MainQueue.async { [weak self] in
                    guard let self, self.searchGeneration == generation else { return }
                    self.quickSearchResults = []
                    self.isQuickSearching = false
                    self.notice = "Search failed: \(error)"
                }
            }
        }
    }

    func selectQuickSearchResult(_ track: Track) {
        searchQuery = ""
        quickSearchResults = []
        searchGeneration &+= 1
        selectTrack(track)
    }

    func dismissQuickSearch() {
        quickSearchResults = []
        isQuickSearching = false
        searchGeneration &+= 1
    }

    // MARK: - Playback → spotifyd / Connect

    func selectTrack(_ track: Track) {
        // Prefer the open album row as parent context so Connect continues
        // through the disc even if the Track value was built without .album.
        let playTrack: Track = {
            if track.album == nil, let detail = detailAlbum,
               detailTracks.contains(where: { $0.id == track.id })
            {
                var t = track
                t.album = detail
                return t
            }
            return track
        }()
        nowPlaying = playTrack
        guard isLoggedIn else {
            isPlaying = false
            status = "Log in to play (Account → Log in to Spotify)"
            notice = bootstrapNotice()
            return
        }
        status = "Starting “\(playTrack.name)”…"
        let deviceId = selectedDeviceId
        // Rest of the open album (or whatever list we have) for URI-queue fallback.
        let queue: [Track] = {
            if detailTracks.contains(where: { $0.id == playTrack.id }) {
                return detailTracks
            }
            return [playTrack]
        }()
        Thread.detachNewThread { [client] in
            do {
                if deviceId == nil {
                    let list = try client.listDevices()
                    let device = try client.resolvePlaybackDevice(among: list)
                    try client.play(track: playTrack, queue: queue, deviceId: device.id)
                    MainQueue.async { [weak self] in
                        self?.devices = list
                        self?.selectedDeviceId = device.id
                        self?.activeDeviceName = device.name
                        self?.isPlaying = true
                        self?.status = "▶ \(playTrack.name) @ \(device.name)"
                        self?.notice = self?.bootstrapNotice()
                    }
                } else {
                    try client.play(track: playTrack, queue: queue, deviceId: deviceId)
                    MainQueue.async { [weak self] in
                        self?.isPlaying = true
                        let name = self?.devices.first(where: { $0.id == deviceId })?.name
                            ?? self?.activeDeviceName
                            ?? "device"
                        self?.status = "▶ \(playTrack.name) @ \(name)"
                        self?.notice = self?.bootstrapNotice()
                    }
                }
            } catch {
                MainQueue.async { [weak self] in
                    guard let self else { return }
                    self.isPlaying = false
                    self.status = "Play failed"
                    self.notice = "\(error)"
                    self.report("\(error)")
                }
            }
        }
    }

    func playAlbum(_ album: Album) {
        // Start at track 1 with full album context (auto-advance through disc).
        if let first = detailTracks.first {
            var t = first
            t.album = album
            selectTrack(t)
            return
        }
        guard isLoggedIn else {
            status = "Log in to play"
            return
        }
        Thread.detachNewThread { [client] in
            do {
                let device = try client.resolvePlaybackDevice()
                try client.playAlbum(album, deviceId: device.id)
                MainQueue.async { [weak self] in
                    self?.selectedDeviceId = device.id
                    self?.activeDeviceName = device.name
                    self?.isPlaying = true
                    self?.status = "▶ \(album.name) @ \(device.name)"
                }
            } catch {
                MainQueue.async { [weak self] in
                    self?.status = "Play failed"
                    self?.notice = "\(error)"
                    self?.report("\(error)")
                }
            }
        }
    }

    func togglePlay() {
        guard isLoggedIn else {
            status = "Log in to control playback"
            return
        }
        let shouldPause = isPlaying
        Thread.detachNewThread { [client] in
            do {
                if shouldPause {
                    try client.pause()
                } else {
                    try client.resume()
                }
                MainQueue.async { [weak self] in
                    self?.isPlaying = !shouldPause
                    self?.status = shouldPause ? "Paused" : "Playing"
                }
            } catch {
                MainQueue.async { [weak self] in
                    self?.status = "Transport failed"
                    self?.notice = "\(error)"
                    self?.report("\(error)")
                }
            }
        }
    }

    func playNext() {
        guard isLoggedIn else {
            // Local list fallback when not logged in.
            localSkip(+1)
            return
        }
        Thread.detachNewThread { [client] in
            do {
                try client.skipNext()
                MainQueue.async { [weak self] in self?.status = "Skipped →" }
            } catch {
                MainQueue.async { [weak self] in
                    self?.notice = "\(error)"
                    self?.report("\(error)")
                }
            }
        }
    }

    func playPrevious() {
        guard isLoggedIn else {
            localSkip(-1)
            return
        }
        Thread.detachNewThread { [client] in
            do {
                try client.skipPrevious()
                MainQueue.async { [weak self] in self?.status = "Skipped ←" }
            } catch {
                MainQueue.async { [weak self] in
                    self?.notice = "\(error)"
                    self?.report("\(error)")
                }
            }
        }
    }

    private func localSkip(_ delta: Int) {
        guard let current = nowPlaying else { return }
        let list = detailTracks
        guard let idx = list.firstIndex(where: { $0.id == current.id }) else { return }
        let next = idx + delta
        guard list.indices.contains(next) else { return }
        nowPlaying = list[next]
        status = "Selected · \(list[next].name)"
    }

    // MARK: - Seek

    /// Called by the progress slider on every jump (track click) and drag tick.
    /// Updates the UI immediately and debounces the Player API seek so a drag
    /// does not fire one request per pixel — same press-to-jump model as the
    /// HelloWorld `Slider` demo.
    func scrub(toMs ms: Int) {
        let clamped = min(max(0, ms), durationMs)
        progressMs = clamped
        isScrubbing = true
        progressAnchor = Date()
        progressAnchorMs = clamped
        seekGeneration &+= 1
        let gen = seekGeneration
        let deviceId = selectedDeviceId
        guard isLoggedIn else {
            isScrubbing = false
            return
        }
        Thread.detachNewThread { [client, weak self] in
            // Short debounce: a click still seeks quickly; a drag coalesces.
            Thread.sleep(forTimeInterval: 0.12)
            guard let self, gen == self.seekGeneration else { return }
            do {
                try client.seek(positionMs: clamped, deviceId: deviceId)
                MainQueue.async { [weak self] in
                    guard let self, gen == self.seekGeneration else { return }
                    // Hold scrub lock briefly so the next Connect poll cannot
                    // snap the knob back to a pre-seek sample.
                    self.progressAnchor = Date()
                    self.progressAnchorMs = clamped
                    self.progressMs = clamped
                }
                Thread.sleep(forTimeInterval: 0.35)
                MainQueue.async { [weak self] in
                    guard let self, gen == self.seekGeneration else { return }
                    self.isScrubbing = false
                }
            } catch {
                MainQueue.async { [weak self] in
                    guard let self else { return }
                    self.isScrubbing = false
                    self.notice = "\(error)"
                    self.report("seek: \(error)")
                }
            }
        }
    }

    // MARK: - Volume

    /// Updates the local control immediately and coalesces a drag into the
    /// latest Spotify Connect volume request.
    func setVolume(to percent: Int) {
        let clamped = min(100, max(0, percent))
        volumePercent = clamped
        isAdjustingVolume = true
        pendingVolumePercent = clamped
        volumeGeneration &+= 1
        let gen = volumeGeneration
        let deviceId = selectedDeviceId
        guard isLoggedIn else {
            pendingVolumePercent = nil
            isAdjustingVolume = false
            return
        }

        Thread.detachNewThread { [client, weak self] in
            Thread.sleep(forTimeInterval: 0.10)
            guard let self, gen == self.volumeGeneration else { return }
            do {
                try client.setVolume(percent: clamped, deviceId: deviceId)
                MainQueue.async { [weak self] in
                    guard let self, gen == self.volumeGeneration else { return }
                    self.volumePercent = clamped
                }
                // A Player snapshot may already be in flight with the old
                // volume. Keep the optimistic value authoritative long enough
                // for a subsequent poll to observe spotifyd's new value.
                Thread.sleep(forTimeInterval: 2.0)
                MainQueue.async { [weak self] in
                    guard let self, gen == self.volumeGeneration else { return }
                    self.pendingVolumePercent = nil
                    self.isAdjustingVolume = false
                }
            } catch {
                MainQueue.async { [weak self] in
                    guard let self, gen == self.volumeGeneration else { return }
                    self.pendingVolumePercent = nil
                    self.isAdjustingVolume = false
                    self.notice = "\(error)"
                    self.report("volume: \(error)")
                }
            }
        }
    }

    // MARK: - Poll Connect state

    private func startPlaybackPolling() {
        pollStop = false
        Thread.detachNewThread { [weak self] in
            var ticks = 0
            while let self, !self.pollStop {
                Thread.sleep(forTimeInterval: 0.25)
                ticks += 1
                guard self.isLoggedIn else { continue }

                // Smooth the bar between API samples while playing, unless the
                // user is dragging the seek knob.
                MainQueue.async { [weak self] in
                    guard let self, !self.isScrubbing, self.isPlaying else { return }
                    let elapsed = Int(Date().timeIntervalSince(self.progressAnchor) * 1000)
                    let next = min(self.durationMs, self.progressAnchorMs + max(0, elapsed))
                    if next != self.progressMs { self.progressMs = next }
                }

                // Full Connect snapshot ~every second.
                guard ticks % 4 == 0 else { continue }
                do {
                    let snap = try self.client.currentPlayback()
                    MainQueue.async { [weak self] in
                        guard let self else { return }
                        if let snap {
                            self.isPlaying = snap.isPlaying
                            if !self.isScrubbing {
                                self.progressMs = snap.progressMs
                                self.progressAnchor = Date()
                                self.progressAnchorMs = snap.progressMs
                            }
                            if let t = snap.track, t.isPlayableSpotifyId {
                                let changed = self.nowPlaying?.id != t.id
                                self.nowPlaying = t
                                if changed {
                                    if !self.isScrubbing {
                                        self.progressMs = snap.progressMs
                                        self.progressAnchor = Date()
                                        self.progressAnchorMs = snap.progressMs
                                    }
                                    if snap.isPlaying {
                                        let where_ = self.activeDeviceName
                                            ?? self.devices.first(where: {
                                                $0.id == self.selectedDeviceId
                                            })?.name
                                        if let where_ {
                                            self.status = "▶ \(t.name) @ \(where_)"
                                        } else {
                                            self.status = "▶ \(t.name)"
                                        }
                                    }
                                }
                            }
                            if let d = snap.device {
                                self.activeDeviceName = d.name
                                self.selectedDeviceId = d.id
                                if let volume = d.volumePercent {
                                    if let pending = self.pendingVolumePercent {
                                        // Ignore stale snapshots, but release
                                        // the guard as soon as Connect echoes
                                        // the value we most recently sent.
                                        if volume == pending {
                                            self.volumePercent = volume
                                            self.pendingVolumePercent = nil
                                            self.isAdjustingVolume = false
                                        }
                                    } else if !self.isAdjustingVolume {
                                        self.volumePercent = volume
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    // Transient — don't spam the status line every poll.
                }
            }
        }
    }

    private func report(_ message: String) {
        FileHandle.standardError.write(Data("LavaSpotify: \(message)\n".utf8))
    }
}
