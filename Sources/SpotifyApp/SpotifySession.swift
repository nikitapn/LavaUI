import Foundation
import LavaUI
import Observation
import SpotifyCore

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
    var libraryAlbums: [Album] = []

    var detailAlbum: Album?
    var detailTracks: [Track] = []

    var nowPlaying: Track?
    var isPlaying: Bool = false
    var progressMs: Int = 0
    var activeDeviceName: String?

    var devices: [SpotifyDevice] = []
    var selectedDeviceId: String?

    var status: String = "Loading catalog…"
    var notice: String?
    var isLoading: Bool = false
    var isLoggedIn: Bool = false

    let client = SpotifyClient()
    let editor: Editor

    private var pollStop = false

    init(editor: Editor) {
        self.editor = editor
        self.isLoggedIn = client.isUserLoggedIn
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
        nav = .home
        detailAlbum = nil
        detailTracks = []
    }

    func goSearch() {
        nav = .search
        detailAlbum = nil
        detailTracks = []
    }

    func goLibrary() {
        nav = .library
        detailAlbum = nil
        detailTracks = []
    }

    func openAlbum(_ album: Album) {
        nav = .album(album.id)
        detailAlbum = album
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
                    guard let self else { return }
                    self.detailAlbum = full
                    self.detailTracks = tracks
                    self.isLoading = false
                    self.status = "\(full.name) · \(tracks.count) tracks"
                }
            } catch {
                MainQueue.async { [weak self] in
                    guard let self else { return }
                    self.isLoading = false
                    self.notice = "\(error)"
                    self.status = "Could not open album"
                    self.report("\(error)")
                }
            }
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

    // MARK: - Playback → spotifyd / Connect

    func selectTrack(_ track: Track) {
        nowPlaying = track
        guard isLoggedIn else {
            isPlaying = false
            status = "Log in to play (Account → Log in to Spotify)"
            notice = bootstrapNotice()
            return
        }
        status = "Starting “\(track.name)”…"
        let deviceId = selectedDeviceId
        Thread.detachNewThread { [client] in
            do {
                // Prefer named device; refresh list if we have no id yet.
                if deviceId == nil {
                    let list = try client.listDevices()
                    let device = try client.resolvePlaybackDevice(among: list)
                    try client.play(track: track, deviceId: device.id)
                    MainQueue.async { [weak self] in
                        self?.devices = list
                        self?.selectedDeviceId = device.id
                        self?.activeDeviceName = device.name
                        self?.isPlaying = true
                        self?.status = "▶ \(track.name) @ \(device.name)"
                        self?.notice = self?.bootstrapNotice()
                    }
                } else {
                    try client.play(track: track, deviceId: deviceId)
                    MainQueue.async { [weak self] in
                        self?.isPlaying = true
                        let name = self?.devices.first(where: { $0.id == deviceId })?.name
                            ?? self?.activeDeviceName
                            ?? "device"
                        self?.status = "▶ \(track.name) @ \(name)"
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
        if let first = detailTracks.first {
            selectTrack(first)
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

    // MARK: - Poll Connect state

    private func startPlaybackPolling() {
        pollStop = false
        Thread.detachNewThread { [weak self] in
            while let self, !self.pollStop {
                Thread.sleep(forTimeInterval: 1.5)
                guard self.isLoggedIn else { continue }
                do {
                    let snap = try self.client.currentPlayback()
                    MainQueue.async { [weak self] in
                        guard let self else { return }
                        if let snap {
                            self.isPlaying = snap.isPlaying
                            self.progressMs = snap.progressMs
                            if let t = snap.track, t.isPlayableSpotifyId {
                                self.nowPlaying = t
                            }
                            if let d = snap.device {
                                self.activeDeviceName = d.name
                                self.selectedDeviceId = d.id
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
