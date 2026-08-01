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
            quickSearch
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

    @ViewBuilder
    private var quickSearch: some View {
        let presented = Binding(
            get: { session.isQuickSearching || !session.quickSearchResults.isEmpty },
            set: { if !$0 { session.dismissQuickSearch() } }
        )
        HStack(height: .pt(48), padding: 6, alignment: .center) {
            Text("Search", color: .accent)
            TextField(
                text: Binding(
                    get: { session.searchQuery },
                    set: { session.updateQuickSearch($0) }
                ),
                placeholder: "Search songs, artists, albums…"
            )
            .flexGrow(1)
            .agentId("home-search-field")
            if !session.searchQuery.isEmpty {
                Text("Clear", color: .muted, onClick: {
                    session.updateQuickSearch("")
                })
                .agentId("home-search-clear")
            }
        }
        .background(SpotifyTheme.theme.inset)
        .cornerRadius(10)
        .overlay(
            isPresented: presented,
            alignment: .below,
            style: OverlayStyle(padding: 6, minWidth: 680)
        ) {
            VStack(width: .pt(680), padding: 2) {
                if session.isQuickSearching && session.quickSearchResults.isEmpty {
                    Text("Searching Spotify…", color: .muted)
                        .padding(10)
                }
                ForEach(session.quickSearchResults) { track in
                    quickSearchRow(track)
                }
            }
        }
        .agentId("home-search")
    }

    @ViewBuilder
    private func quickSearchRow(_ track: Track) -> some View {
        // Transparent outer padding is the row gap; keeping it outside the
        // interactive HStack prevents adjacent hover surfaces from touching.
        VStack(padding: 3) {
            HStack(height: .pt(62), padding: 7, alignment: .center, onClick: {
                session.selectQuickSearchResult(track)
            }) {
                CoverArt(
                    track.album?.preferredCover,
                    size: 48,
                    cornerRadius: 5,
                    editor: session.editor
                )
                VStack(flexGrow: 1, padding: 2) {
                    Text(compact(track.name, limit: 56), color: .primary)
                    Text(track.artistLine, color: .secondary)
                }
                Text(track.durationLabel, color: .dim)
            }
            .hoverBackground(SpotifyTheme.cardHover)
            .cornerRadius(7)
            .agentId("search-track-\(track.id)")
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
                HStack(padding: 6, alignment: .start) {
                    ForEach(section.albums) { album in
                        spacedAlbumCard(album, size: 140)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func albumCard(_ album: Album, size: Float) -> some View {
        VStack(
            width: .pt(size + 12), height: .pt(size + 93), padding: 6,
            onClick: { session.openAlbum(album) }
        ) {
            CoverArt(
                album.preferredCover,
                size: size,
                cornerRadius: 6,
                editor: session.editor,
                onClick: nil
            )
            Text(compact(album.name, limit: 26), color: .primary)
            Text(compact(album.artistLine, limit: 24), color: .secondary)
        }
        .background(SpotifyTheme.theme.panel)
        .hoverBackground(SpotifyTheme.cardHover)
        .cornerRadius(8)
        .agentId("album-\(album.id)")
    }

    @ViewBuilder
    private func spacedAlbumCard(_ album: Album, size: Float) -> some View {
        // Stack padding is inside its background. This transparent wrapper is
        // intentional: it creates real breathing room between card surfaces.
        VStack(padding: 4) {
            albumCard(album, size: size)
        }
    }

    // MARK: Search

    @ViewBuilder
    private var searchView: some View {
        VStack(flexGrow: 1, padding: 12) {
            HStack(padding: 6, alignment: .center) {
                Text("Search", color: .primary)
                TextField(text: $session.searchQuery, placeholder: "Albums, artists…")
                    .flexGrow(1)
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
                HStack(padding: 6, alignment: .start) {
                    ForEach(row.albums) { album in
                        spacedAlbumCard(album, size: size)
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
            HStack(padding: 8, alignment: .center) {
                Text("← Back", color: .accent, onClick: { session.goHome() })
                    .agentId("back")
                Spacer()
            }

            if let album = session.detailAlbum {
                HStack(padding: 12, alignment: .center) {
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
        HStack(padding: 6, alignment: .center) {
            Text(String(format: "%2d", track.trackNumber), color: .dim)
                .frame(width: .pt(28))
            Text(
                track.name,
                color: selected ? .accent : .primary,
                onClick: { session.selectTrack(track) }
            )
            .flexGrow(1)
            Text(track.durationLabel, color: .dim)
        }
        .hoverBackground(SpotifyTheme.cardHover)
        .cornerRadius(4)
        .agentId("track-\(track.id)")
    }

    // MARK: Player bar

    @ViewBuilder
    private var playerBar: some View {
        HStack(height: .pt(112), padding: 10, alignment: .center) {
            // Now playing
            HStack(width: .pt(280), padding: 4, alignment: .center) {
                if let track = session.nowPlaying {
                    CoverArt(
                        track.album?.preferredCover ?? session.detailAlbum?.preferredCover,
                        size: 52,
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

            // Transport + seek
            VStack(flexGrow: 1, padding: 4) {
                HStack(padding: 4, alignment: .center) {
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
                HStack(padding: 2, alignment: .center) {
                    Text(formatMs(session.progressMs), color: .dim)
                        .frame(width: .pt(40))
                        .agentId("progress-elapsed")
                    progressSlider
                    Text(formatMs(session.durationMs), color: .dim)
                        .frame(width: .pt(40))
                        .agentId("progress-duration")
                }
                Text(deviceFooter, color: .dim)
                    .agentId("player-footer")
            }

            HStack(width: .pt(160), padding: 4, alignment: .center) {
                Spacer()
                Text("🔊  ────●──", color: .secondary)
            }
        }
        .background(SpotifyTheme.playerBar)
        .agentId("player-bar")
    }

    @ViewBuilder
    private var progressSlider: some View {
        // Same interaction model as DemoExample's gauge: press anywhere on the
        // track jumps (mouse button / agent click), drag moves continuously.
        // Bind 0…1 like the demo — ms ranges are fine numerically, but the
        // unit interval matches how every other LavaUI slider is written.
        let hasTrack = session.nowPlaying != nil
        let duration = max(1, session.durationMs)
        Slider(
            value: Binding(
                get: {
                    min(1, max(0, Float(session.progressMs) / Float(duration)))
                },
                set: { frac in
                    let ms = Int((min(1, max(0, frac)) * Float(duration)).rounded())
                    session.scrub(toMs: ms)
                }
            ),
            in: 0...1,
            style: SliderStyle(
                trackWidth: 220,
                trackThickness: 4,
                knobRadius: 6,
                activeTrack: SpotifyTheme.green,
                inactiveTrack: Color(r: 0.28, g: 0.28, b: 0.28),
                knob: Color(r: 1, g: 1, b: 1),
                valueWidth: 0
            ),
            isEnabled: hasTrack && session.isLoggedIn
        )
        .flexGrow(1)
        .agentId("progress-slider")
    }

    private func formatMs(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func compact(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(1, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
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
