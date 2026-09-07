import Foundation
import LavaUI
import SpotifyCore

/// LavaSpotify root: title bar, sidebar + main, player bar. UI only — no audio.
struct Spotify: View {
    @Bindable var session: SpotifySession

    var body: some View {
        VStack(flexGrow: 1, padding: 0, spacing: 0) {
            TitleBar(session: session)
            HStack(flexGrow: 1, padding: 0) {
                sidebar
                mainColumn
            }
            playerBar
        }
        .background(Theme.current.background)
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        VStack(width: .pt(200), padding: 10) {
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
            navRow(
                "Liked Songs",
                selected: isLikedNav,
                action: { session.goLiked() }
            )
            .agentId("nav-liked")

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
        .background(Theme.current.panel)
    }

    private var isHome: Bool {
        if case .home = session.nav { return true }
        return false
    }

    private var isLikedNav: Bool {
        if case .liked = session.nav { return true }
        return false
    }

    private func navRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Text(
            selected ? "● \(title)" : "  \(title)",
            color: selected ? .accent : .primary,
            onClick: action
        )
        .padding(6)
        .hoverBackground(Theme.current.hover)
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
            case .liked:
                likedView
            case .album:
                albumDetailView
            case .artist:
                artistDetailView
            }
        }
        .background(Theme.current.background)
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
        let searchWidth: Float = 680
        let presented = Binding(
            get: { session.isQuickSearching || !session.quickSearchResults.isEmpty },
            set: { if !$0 { session.dismissQuickSearch() } }
        )
        HStack(height: .pt(48), alignment: .center) {
            Spacer()
            HStack(width: .pt(searchWidth), height: .pt(48), padding: 6, alignment: .center) {
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
            // `panel`, not `inset`. Inset is a well punched through a card —
            // on the dark palettes it is within a hundredth of `background`,
            // so a search bar painted in it is a bar nobody can see.
            .background(Theme.current.panel)
            .border(Theme.current.border, width: 1)
            .cornerRadius(10)
            .overlay(
                isPresented: presented,
                alignment: .below,
                style: OverlayStyle(padding: 6, minWidth: searchWidth)
            ) {
                VStack(padding: 2) {
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
            Spacer()
        }
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
                    artistLink(track.artists)
                }
                Text(track.durationLabel, color: .dim)
            }
            .hoverBackground(Theme.current.hover)
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
            width: .pt(AlbumCardLayout.width(cover: size)),
            height: .pt(AlbumCardLayout.height(cover: size)),
            padding: AlbumCardLayout.padding,
            alignment: .start,
            spacing: AlbumCardLayout.spacing,
            onClick: { session.openAlbum(album) }
        ) {
            CoverArt(
                album.preferredCover,
                size: size,
                cornerRadius: 6,
                editor: session.editor,
                onClick: nil
            )
            Text(album.name, color: .primary)
                .lineLimit(2)
            artistLink(album.artists)
                .lineLimit(1)
        }
        .background(Theme.current.panel)
        .hoverBackground(Theme.current.hover)
        .cornerRadius(8)
        .agentId("album-\(album.id)")
    }

    @ViewBuilder
    private func spacedAlbumCard(_ album: Album, size: Float) -> some View {
        // Stack padding is inside its background. This transparent wrapper is
        // intentional: it creates real breathing room between card surfaces.
        VStack(padding: AlbumCardLayout.outerGap) {
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
            .background(Theme.current.panel)
            .border(Theme.current.border, width: 1)
            .cornerRadius(10)

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
        // Virtualized, not a wrapping HStack. A library of a few thousand
        // albums built every card on every body pass — ~46ms for a frame that
        // then drew in 0.2ms, because the draw list culls and the mount/layout
        // path did not. Cell size is `albumCard` plus `spacedAlbumCard`'s gap.
        LazyVGrid(
            albums,
            cellWidth: AlbumCardLayout.cellWidth(cover: size),
            cellHeight: AlbumCardLayout.cellHeight(cover: size)
        ) { album in
            spacedAlbumCard(album, size: size)
        }
    }

    // MARK: Artist detail

    @ViewBuilder
    private var likedView: some View {
        VStack(flexGrow: 1, padding: 12) {
            HStack(padding: 8, alignment: .center) {
                VStack(padding: 2, alignment: .start) {
                    Text("PLAYLIST", color: .muted)
                    Text("Liked Songs", color: .primary)
                        .agentId("liked-title")
                    Text(
                        session.isLoggedIn
                            ? "\(session.likedTracks.count) songs"
                            : "Log in to see songs you have liked",
                        color: .dim
                    )
                }
                Spacer()
                if !session.likedTracks.isEmpty {
                    Button("Play") { session.playLiked() }
                        .agentId("play-liked")
                }
            }

            if session.isLoading && session.likedTracks.isEmpty {
                Text("Loading Liked Songs…", color: .secondary)
                    .agentId("liked-loading")
            } else if !session.isLoggedIn {
                Text("Account → Log in", color: .accent, onClick: { session.login() })
                    .padding(8)
            } else if session.likedTracks.isEmpty {
                Text("Songs you like will land here.", color: .secondary)
                    .padding(8)
                    .agentId("liked-empty")
            } else {
                ScrollView(.vertical) {
                    VStack(padding: 4) {
                        ForEach(session.likedTracks) { track in
                            trackRow(
                                track,
                                number: (session.likedTracks.firstIndex(where: {
                                    $0.id == track.id
                                }) ?? 0) + 1
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var artistDetailView: some View {
        VStack(flexGrow: 1, padding: 12) {
            HStack(padding: 8, alignment: .center) {
                Text("← Back", color: .accent, onClick: { session.goBack() })
                    .agentId("artist-back")
                Spacer()
            }

            if let artist = session.detailArtist {
                HStack(padding: 12, alignment: .center) {
                    CoverArt(
                        artist.preferredImage,
                        size: 164,
                        cornerRadius: 82,
                        editor: session.editor
                    )
                    VStack(padding: 5) {
                        Text("ARTIST", color: .muted)
                        Text(artist.name, color: .primary)
                            .agentId("artist-title")
                        if !artist.genres.isEmpty {
                            Text(artist.genres.prefix(3).joined(separator: " · "), color: .secondary)
                        }
                        if let followers = artist.followerCount {
                            Text("\(followers.formatted()) followers", color: .dim)
                        }
                        Text("\(session.artistAlbums.count) releases", color: .dim)
                    }
                    Spacer()
                }

                Text("Albums and singles", color: .primary)
                    .padding(6)
                ScrollView(.vertical) {
                    albumGrid(session.artistAlbums, size: 128)
                }
            } else {
                Text("Opening artist…", color: .secondary)
            }
        }
    }

    // MARK: Album detail

    @ViewBuilder
    private var albumDetailView: some View {
        VStack(flexGrow: 1, padding: 12) {
            HStack(padding: 8, alignment: .center) {
                Text("← Back", color: .accent, onClick: { session.goBack() })
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
                        artistLink(album.artists)
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
    private func trackRow(_ track: Track, number: Int? = nil) -> some View {
        let selected = session.nowPlaying?.id == track.id
        let index = number ?? track.trackNumber
        let stripe = index.isMultiple(of: 2)
            ? Theme.current.inset.opacity(0.52)
            : Theme.current.panel.opacity(0.72)
        HStack(padding: 6, alignment: .center,
               onClick: { session.selectTrack(track) })
        {
            // Right-aligned so the column of numbers lines up on its units
            // digit. This used to be `%2d`, which pads a single digit with a
            // space to fake the same thing — and stops working at track 100,
            // where the padding runs out and the column steps left. Alignment
            // does not care how many digits there are.
            Text(String(index), color: .dim, align: .trailing)
                .frame(width: .pt(28))
            CoverArt(
                track.album?.preferredCover,
                size: 40,
                cornerRadius: 4,
                editor: session.editor
            )
            VStack(flexGrow: 1, padding: 1) {
                Text(track.name, color: selected ? .accent : .primary)
                    .lineLimit(1)
                HStack() {
                    artistLink(track.artists)
                        .lineLimit(1)
                    Spacer()
                }
            }
            likeButton(track)
            Text(track.durationLabel, color: .dim)
        }
        .background(selected ? Theme.current.selectionFill : stripe)
        .hoverBackground(Theme.current.hover)
        .cornerRadius(6)
        .agentId("track-\(track.id)")
    }

    // MARK: Player bar

    @ViewBuilder
    private var playerBar: some View {
        HStack(height: .pt(136), padding: 16, alignment: .center, spacing: 12) {
            // Now playing
            if let track = session.nowPlaying {
                HStack(
                    width: .pt(280), padding: 4, alignment: .center,
                    onClick: { session.openNowPlayingAlbum() }
                ) {
                    CoverArt(
                        track.album?.preferredCover ?? session.detailAlbum?.preferredCover,
                        size: 52,
                        cornerRadius: 4,
                        editor: session.editor
                    )
                    VStack(padding: 2) {
                        Text(track.name, color: .primary)
                            .lineLimit(1)
                            .agentId("np-title")
                        artistLink(track.artists)
                            .lineLimit(1)
                    }
                    likeButton(track, id: "np-like")
                    Spacer()
                }
                .hoverBackground(Theme.current.hover)
                .cornerRadius(7)
                .agentId("now-playing-album")
            } else {
                HStack(width: .pt(280), padding: 4, alignment: .center) {
                    Text("Nothing playing", color: .dim)
                        .agentId("np-empty")
                    Spacer()
                }
            }

            // Transport + seek
            VStack(flexGrow: 1, padding: 0, spacing: 6) {
                HStack(padding: 0, alignment: .center) {
                    Spacer()
                    Button(
                        "⏮",
                        style: secondaryTransportStyle,
                        font: session.playerControlFont,
                        action: { session.playPrevious() }
                    )
                    .frame(width: .pt(36), height: .pt(36))
                    .agentId("prev")
                    Button(
                        session.isPlaying ? "⏸" : "▶",
                        style: ButtonStyle(
                            background: Theme.current.accent.opacity(0.15),
                            hover: Theme.current.accent.opacity(0.25),
                            pressed: Theme.current.accent.opacity(0.35),
                            foreground: .primary,
                            cornerRadius: 20,
                            padding: 0
                        ),
                        font: session.playerControlFont,
                        action: { session.togglePlay() }
                    )
                    .frame(width: .pt(40), height: .pt(40))
                    .padding(4)
                    .agentId("play-pause")
                    Button(
                        "⏭",
                        style: secondaryTransportStyle,
                        font: session.playerControlFont,
                        action: { session.playNext() }
                    )
                        .frame(width: .pt(36), height: .pt(36))
                        .agentId("next")
                    Spacer()
                }
                HStack(padding: 0, alignment: .center) {
                    // Centred in their gutters, so crossing 9:59 into 10:00
                    // widens the number about its own middle instead of
                    // pushing it sideways from a fixed left edge.
                    Text(formatMs(session.progressMs), color: .dim, align: .center)
                        .frame(width: .pt(40))
                        .agentId("progress-elapsed")
                    progressSlider
                    Text(formatMs(session.durationMs), color: .dim, align: .center)
                        .frame(width: .pt(40))
                        .agentId("progress-duration")
                }
                Text(deviceFooter, color: .dim)
                    .agentId("player-footer")
            }

            HStack(width: .pt(176), padding: 6, alignment: .center) {
                Button(
                    session.volumePercent == 0 ? "🔇" : "🔊",
                    style: secondaryTransportStyle,
                    font: session.playerControlFont,
                    isEnabled: session.canControlVolume,
                    action: {
                        session.setVolume(to: session.volumePercent == 0 ? 50 : 0)
                    }
                )
                .frame(width: .pt(36), height: .pt(36))
                .agentId("volume-mute")
                Slider(
                    value: Binding(
                        get: { Float(session.volumePercent) },
                        set: { session.setVolume(to: Int($0.rounded())) }
                    ),
                    in: 0...100,
                    step: 1,
                    style: SliderStyle(
                        trackWidth: 96,
                        trackThickness: 4,
                        knobRadius: 6,
                        activeTrack: Theme.current.accent,
                        inactiveTrack: Theme.current.border,
                        knob: Theme.current.textPrimary,
                        valueWidth: 0
                    ),
                    isEnabled: session.canControlVolume
                )
                .flexGrow(1)
                .agentId("volume-slider")
            }
        }
        .background(Theme.current.panel)
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
                activeTrack: Theme.current.accent,
                inactiveTrack: Theme.current.border,
                knob: Theme.current.textPrimary,
                valueWidth: 0
            ),
            isEnabled: hasTrack && session.isLoggedIn
        )
        .flexGrow(1)
        .agentId("progress-slider")
    }

    private var secondaryTransportStyle: ButtonStyle {
        ButtonStyle(
            background: Color(r: 0, g: 0, b: 0, a: 0),
            hover: Theme.current.accent.opacity(0.14),
            pressed: Theme.current.accent.opacity(0.24),
            foreground: .secondary,
            disabledBackground: Color(r: 0, g: 0, b: 0, a: 0),
            disabledForeground: .dim,
            cornerRadius: 18,
            padding: 0
        )
    }

    /// Click and hover live on the square, not the glyph. A `Text` with
    /// `onClick` paints `theme.hover` around its ink box, and a heart sits
    /// high in that box — the plate looks shifted the moment the pointer
    /// arrives.
    ///
    /// `spacing: 0` is required: the theme's default 8pt stack gap plus
    /// Text's built-in +8 measure pad overflow a 32pt chip, Yoga packs
    /// from the start, and the heart leans right.
    private func likeButton(_ track: Track, id: String? = nil) -> some View {
        let liked = session.isLiked(track)
        return HStack(
            width: .pt(32),
            height: .pt(32),
            padding: 0,
            alignment: .center,
            spacing: 0,
            onClick: { session.toggleLike(track) }
        ) {
            Spacer()
            Text(liked ? "♥" : "♡", color: liked ? .accent : .dim)
            Spacer()
        }
        .hoverBackground(Theme.current.hover)
        .cornerRadius(6)
        .agentId(id ?? "like-\(track.id)")
    }

    private func artistLink(_ artists: [ArtistRef]) -> Text {
        guard let artist = artists.first else { return Text("Unknown artist", color: .dim) }
        return Text(
            artist.name,
            color: .secondary,
            hoverColor: .accent,
            onClick: { session.openArtist(artist) }
        )
    }

    private func formatMs(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func compact(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(1, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    private var deviceFooter: String { session.playerFooterLabel }
}

/// Cover plus a caption that always has room for a two-line name and one
/// artist line. The old `size + 93` box was exact for a 16px face at the
/// theme's default stack gap — a wrap ate the artist and sat on the radius.
private enum AlbumCardLayout {
    static let padding: Float = 10
    static let spacing: Float = 4
    static let outerGap: Float = 4

    static var lineHeight: Float {
        max(16, FontStore.default?.lineHeight ?? 20)
    }

    /// Two title lines + one artist line + the two gaps between cover, title,
    /// and artist, plus a little slack so descenders clear the corner.
    static var caption: Float { lineHeight * 3 + spacing * 2 + 8 }

    static func width(cover: Float) -> Float { cover + padding * 2 }
    static func height(cover: Float) -> Float { cover + caption + padding * 2 }
    static func cellWidth(cover: Float) -> Float { width(cover: cover) + outerGap * 2 }
    static func cellHeight(cover: Float) -> Float { height(cover: cover) + outerGap * 2 }
}

// MARK: - Chrome

/// Client title strip: window controls, the product name, a drag handle.
/// Hidden buttons while maximized (`.windowChrome`); the rest of the row stays
/// so the name does not jump. Matches LavaWeather's bar.
private struct TitleBar: View {
    @Bindable var session: SpotifySession

    var body: some View {
        HStack(padding: 10, alignment: .center, spacing: 10) {
            if WindowBridge.drawsOwnChrome {
                WindowControls()
                    .windowChrome()
            }
            Text("LavaSpotify", color: .primary)
                .agentId("app-title")
            if !subtitle.isEmpty {
                Text(subtitle, color: .dim)
            }
            Spacer()
        }
        .frame(height: .pt(44))
        .background(Theme.current.panel)
        .windowDrag()
    }

    private var subtitle: String {
        switch session.nav {
        case .home:
            return ""
        case .search:
            return "Search"
        case .library:
            return "Library"
        case .liked:
            return "Liked Songs"
        case .album:
            return session.detailAlbum?.name ?? ""
        case .artist:
            return session.detailArtist?.name ?? ""
        }
    }
}
