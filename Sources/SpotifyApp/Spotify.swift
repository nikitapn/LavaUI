import Foundation
import LavaUI
import SpotifyCore

#if canImport(CxxCanvas)

/// LavaSpotify root: sidebar + main + player bar. UI only — no audio.
struct Spotify: View {
    @Bindable var session: SpotifySession

    var body: some View {
        VStack(flexGrow: 1, padding: 0) {
            HStack(flexGrow: 1, padding: 0) {
                sidebar
                mainColumn
            }
            playerBar
        }
        .background(SpotifyTheme.theme.background)
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        VStack(width: .pt(200), padding: 10) {
            Text("LavaSpotify", color: .accent)
                .padding(4)
                .agentId("app-title")

            navRow("Home", selected: isHome, action: { session.goHome() })
                .agentId("nav-home")
            navRow("Search", selected: session.nav == .search, action: { session.goSearch() })
                .agentId("nav-search")
            navRow("Your Library", selected: session.nav == .library, action: { session.goLibrary() })
                .agentId("nav-library")

            Divider()

            Text("Playback", color: .muted)
                .padding(4)
            if session.isLoggedIn {
                Text("  ● Logged in", color: .accent)
                    .agentId("auth-status")
                if let name = session.activeDeviceName
                    ?? session.devices.first(where: { $0.id == session.selectedDeviceId })?.name
                {
                    Text("  \(name)", color: .secondary)
                        .agentId("device-name")
                } else {
                    Text("  No device", color: .dim, onClick: { session.refreshDevices() })
                        .agentId("device-name")
                }
                Text("  Refresh devices", color: .muted, onClick: { session.refreshDevices() })
                    .agentId("refresh-devices")
            } else {
                Text("  Log in to play", color: .accent, onClick: { session.login() })
                    .agentId("auth-status")
            }

            Divider()

            Text("Playlists", color: .muted)
                .padding(4)
            Text("  Liked Songs", color: .secondary, onClick: {
                session.status = "Liked Songs — needs library scopes later"
            })

            Spacer()

            if let notice = session.notice {
                Text(notice, color: .muted)
                    .padding(4)
                    .agentId("notice")
            }
            Text(session.status, color: .dim)
                .padding(4)
                .agentId("status")
        }
        .background(SpotifyTheme.sidebar)
    }

    private var isHome: Bool {
        if case .home = session.nav { return true }
        return false
    }

    private func navRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Text(
            selected ? "● \(title)" : "  \(title)",
            color: selected ? .accent : .primary,
            onClick: action
        )
        .padding(6)
        .hoverBackground(SpotifyTheme.cardHover)
        .cornerRadius(4)
    }

    // MARK: - Main

    @ViewBuilder
    private var mainColumn: some View {
        VStack(flexGrow: 1, padding: 0) {
            switch session.nav {
            case .home:
                homeView
            case .search:
                searchView
            case .library:
                libraryView
            case .album:
                albumDetailView
            }
        }
        .background(SpotifyTheme.theme.background)
        .flexGrow(1)
    }

    // MARK: Home

    @ViewBuilder
    private var homeView: some View {
        VStack(flexGrow: 1, padding: 12) {
            Text(greeting, color: .primary)
                .padding(4)
                .agentId("greeting")

            if session.isLoading && session.sections.isEmpty {
                Text("Loading covers…", color: .secondary)
                    .agentId("loading")
            }

            ScrollView(.vertical) {
                VStack(padding: 8) {
                    ForEach(session.sections) { section in
                        sectionRow(section)
                    }
                }
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        if hour < 18 { return "Good afternoon" }
        return "Good evening"
    }

    @ViewBuilder
    private func sectionRow(_ section: CatalogSection) -> some View {
        VStack(padding: 6) {
            Text(section.title, color: .primary)
                .padding(2)
                .agentId("section-\(section.id)")

            ScrollView(.horizontal, showsIndicator: false) {
                HStack(padding: 6) {
                    ForEach(section.albums) { album in
                        albumCard(album, size: 140)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func albumCard(_ album: Album, size: Float) -> some View {
        VStack(width: .pt(size + 12), padding: 6) {
            CoverArt(
                album.preferredCover,
                size: size,
                cornerRadius: 6,
                editor: session.editor,
                onClick: { session.openAlbum(album) }
            )
            Text(album.name, color: .primary, onClick: { session.openAlbum(album) })
            Text(album.artistLine, color: .secondary)
        }
        .background(SpotifyTheme.theme.panel)
        .hoverBackground(SpotifyTheme.cardHover)
        .cornerRadius(8)
        .agentId("album-\(album.id)")
    }

    // MARK: Search

    @ViewBuilder
    private var searchView: some View {
        VStack(flexGrow: 1, padding: 12) {
            HStack(padding: 6) {
                Text("Search", color: .primary)
                TextField(text: $session.searchQuery, placeholder: "Albums, artists…")
                    .agentId("search-field")
                Button("Go") { session.runSearch() }
                    .agentId("search-go")
            }

            ScrollView(.vertical) {
                albumGrid(session.searchResults, size: 128)
            }
        }
    }

    // MARK: Library

    @ViewBuilder
    private var libraryView: some View {
        VStack(flexGrow: 1, padding: 12) {
            Text("Your Library", color: .primary)
            Text(
                session.client.hasCredentials
                    ? "Local cache of albums from this session"
                    : "Seed albums (connect API for your real library later)",
                color: .secondary
            )
            ScrollView(.vertical) {
                albumGrid(session.libraryAlbums, size: 120)
            }
        }
    }

    @ViewBuilder
    private func albumGrid(_ albums: [Album], size: Float) -> some View {
        let perRow = 5
        VStack(padding: 6) {
            ForEach(gridRows(albums, perRow: perRow)) { row in
                HStack(padding: 6) {
                    ForEach(row.albums) { album in
                        albumCard(album, size: size)
                    }
                    Spacer()
                }
            }
        }
    }

    private struct GridRow: Identifiable {
        let id: Int
        let albums: [Album]
    }

    private func gridRows(_ albums: [Album], perRow: Int) -> [GridRow] {
        var out: [GridRow] = []
        var i = 0
        while i < albums.count {
            let end = min(i + perRow, albums.count)
            out.append(GridRow(id: i, albums: Array(albums[i..<end])))
            i = end
        }
        return out
    }

    // MARK: Album detail

    @ViewBuilder
    private var albumDetailView: some View {
        VStack(flexGrow: 1, padding: 12) {
            HStack(padding: 8) {
                Text("← Back", color: .accent, onClick: { session.goHome() })
                    .agentId("back")
                Spacer()
            }

            if let album = session.detailAlbum {
                HStack(padding: 12) {
                    CoverArt(
                        album.preferredCover,
                        size: 200,
                        cornerRadius: 4,
                        editor: session.editor
                    )
                    VStack(padding: 6) {
                        Text("ALBUM", color: .muted)
                        Text(album.name, color: .primary)
                            .agentId("detail-title")
                        Text(album.artistLine, color: .secondary)
                        if let date = album.releaseDate {
                            Text(date, color: .dim)
                        }
                        Text("\(session.detailTracks.count) songs", color: .dim)
                        Button("Play") {
                            session.playAlbum(album)
                        }
                        .agentId("play-album")
                    }
                    Spacer()
                }

                ScrollView(.vertical) {
                    VStack(padding: 4) {
                        ForEach(session.detailTracks) { track in
                            trackRow(track)
                        }
                    }
                }
            } else {
                Text("Opening…", color: .secondary)
            }
        }
    }

    @ViewBuilder
    private func trackRow(_ track: Track) -> some View {
        let selected = session.nowPlaying?.id == track.id
        HStack(padding: 6) {
            Text(String(format: "%2d", track.trackNumber), color: .dim)
                .frame(width: .pt(28))
            Text(
                track.name,
                color: selected ? .accent : .primary,
                onClick: { session.selectTrack(track) }
            )
            Spacer()
            Text(track.durationLabel, color: .dim)
        }
        .hoverBackground(SpotifyTheme.cardHover)
        .cornerRadius(4)
        .agentId("track-\(track.id)")
    }

    // MARK: Player bar

    @ViewBuilder
    private var playerBar: some View {
        HStack(height: .pt(72), padding: 10) {
            // Now playing
            HStack(width: .pt(280), padding: 4) {
                if let track = session.nowPlaying {
                    CoverArt(
                        track.album?.preferredCover ?? session.detailAlbum?.preferredCover,
                        size: 48,
                        cornerRadius: 4,
                        editor: session.editor
                    )
                    VStack(padding: 2) {
                        Text(track.name, color: .primary)
                            .agentId("np-title")
                        Text(track.artistLine, color: .secondary)
                    }
                } else {
                    Text("Nothing playing", color: .dim)
                        .agentId("np-empty")
                }
                Spacer()
            }

            // Transport
            VStack(flexGrow: 1, padding: 4) {
                HStack(padding: 6) {
                    Spacer()
                    Text("⏮", color: .secondary, onClick: { session.playPrevious() })
                        .agentId("prev")
                    Text(
                        session.isPlaying ? "⏸" : "▶",
                        color: .primary,
                        onClick: { session.togglePlay() }
                    )
                    .padding(8)
                    .background(SpotifyTheme.green.opacity(0.15))
                    .cornerRadius(20)
                    .agentId("play-pause")
                    Text("⏭", color: .secondary, onClick: { session.playNext() })
                        .agentId("next")
                    Spacer()
                }
                HStack(padding: 2) {
                    Text(progressLabel, color: .dim)
                    Text(progressBar, color: .muted)
                    Text(session.nowPlaying?.durationLabel ?? "0:00", color: .dim)
                }
                Text(deviceFooter, color: .dim)
                    .agentId("player-footer")
            }

            HStack(width: .pt(160), padding: 4) {
                Spacer()
                Text("🔊  ────●──", color: .secondary)
            }
        }
        .background(SpotifyTheme.playerBar)
        .agentId("player-bar")
    }

    private var progressLabel: String {
        let total = max(0, session.progressMs / 1000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var progressBar: String {
        let dur = max(1, session.nowPlaying?.durationMs ?? 1)
        let frac = min(1.0, Double(session.progressMs) / Double(dur))
        let width = 28
        let filled = Int((frac * Double(width)).rounded())
        let left = String(repeating: "─", count: max(0, filled))
        let right = String(repeating: "─", count: max(0, width - filled))
        return left + "●" + right
    }

    private var deviceFooter: String {
        if !session.isLoggedIn {
            return "Log in to play via spotifyd / Connect"
        }
        if let name = session.activeDeviceName
            ?? session.devices.first(where: { $0.id == session.selectedDeviceId })?.name
        {
            return "Connect · \(name)"
        }
        return "Connect · no device (start spotifyd)"
    }
}

#endif
