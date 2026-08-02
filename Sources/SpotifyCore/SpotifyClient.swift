import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Thin Spotify Web API client.
///
/// **Catalog**
/// - Client credentials (`SPOTIFY_CLIENT_ID` / `SECRET`) → search + album detail
/// - Seed / oembed when secrets are missing
///
/// **Playback (spotifyd / Connect)**
/// - Requires a **user** OAuth token (`SpotifyOAuth.loginInteractive`)
/// - Player API targets a Connect device; spotifyd appears as one when running
///
/// **February 2026:** browse/new-releases removed; search `limit` max is 10.
public final class SpotifyClient: @unchecked Sendable {
    public let clientId: String?
    public let clientSecret: String?

    /// Preferred Connect device name substring (case-insensitive).
    /// Override with `SPOTIFY_DEVICE_NAME`. Default `"spotifyd"` matches the
    /// zeroconf name `Spotifyd@hostname` that stock spotifyd advertises.
    public let preferredDeviceName: String

    public private(set) var oauth: SpotifyOAuth?

    private let lock = NSLock()
    private var appAccessToken: String?
    private var appTokenExpiresAt: Date = .distantPast
    private var rateLimitUntil: Date = .distantPast

    public var hasCredentials: Bool {
        guard let id = clientId, let secret = clientSecret else { return false }
        return !id.isEmpty && !secret.isEmpty
    }

    public var isUserLoggedIn: Bool { oauth?.isLoggedIn ?? false }

    public init(
        clientId: String? = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_ID"],
        clientSecret: String? = ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_SECRET"],
        preferredDeviceName: String? = ProcessInfo.processInfo.environment["SPOTIFY_DEVICE_NAME"]
    ) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.preferredDeviceName = preferredDeviceName?.isEmpty == false
            ? preferredDeviceName!
            : "spotifyd"
        if let id = clientId, !id.isEmpty {
            self.oauth = SpotifyOAuth(clientId: id, clientSecret: clientSecret)
        }
    }

    // MARK: - User login

    public func loginInteractive() throws {
        guard let oauth else {
            throw SpotifyError("Set SPOTIFY_CLIENT_ID (and secret) before logging in")
        }
        try oauth.loginInteractive()
    }

    public func logout() {
        oauth?.logout()
    }

    // MARK: - Catalog

    public func loadHome() throws -> [CatalogSection] {
        if hasCredentials || isUserLoggedIn {
            do {
                let shelves: [(id: String, title: String, query: String)] = [
                    ("hits", "Album hits", "tag:new"),
                    ("2020s", "From the 2020s", "year:2020-2026"),
                    ("electronic", "Electronic", "genre:electronic"),
                ]
                var sections: [CatalogSection] = []
                for shelf in shelves {
                    let albums = try searchAlbums(query: shelf.query, limit: Self.searchLimitMax)
                    if !albums.isEmpty {
                        sections.append(CatalogSection(
                            id: shelf.id, title: shelf.title, albums: albums
                        ))
                    }
                }
                if sections.isEmpty {
                    throw SpotifyError("Live search returned no albums")
                }
                return sections
            } catch {
                FileHandle.standardError.write(
                    Data("LavaSpotify: live catalog failed: \(error)\n".utf8)
                )
                return try seedHome()
            }
        }
        return try seedHome()
    }

    public func search(query: String) throws -> [Album] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        if hasCredentials || isUserLoggedIn {
            var hits = try searchAlbums(query: q, limit: Self.searchLimitMax, offset: 0)
            if hits.count == Self.searchLimitMax {
                let more = try searchAlbums(
                    query: q, limit: Self.searchLimitMax, offset: Self.searchLimitMax
                )
                let seen = Set(hits.map(\.id))
                hits.append(contentsOf: more.filter { !seen.contains($0.id) })
            }
            return hits
        }
        let all = try seedHome().flatMap(\.albums)
        let needle = q.lowercased()
        return all.filter {
            $0.name.lowercased().contains(needle)
                || $0.artistLine.lowercased().contains(needle)
        }
    }

    public func searchTracks(query: String, limit: Int = 8) throws -> [Track] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, hasCredentials || isUserLoggedIn else { return [] }
        let capped = min(max(1, limit), Self.searchLimitMax)
        let data = try apiGet(
            path: "/v1/search",
            query: ["q": q, "type": "track", "limit": "\(capped)"],
            userRequired: false
        )
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.tracks?.items.enumerated().map { index, track in
            track.asSearchTrack(fallbackNumber: index + 1)
        } ?? []
    }

    public func albumDetail(id: String) throws -> (album: Album, tracks: [Track]) {
        if hasCredentials || isUserLoggedIn {
            return try fetchAlbum(id: id)
        }
        let album = try SeedCatalog.resolveAlbum(id: id)
        return (album, SeedCatalog.tracks(for: id, album: album))
    }

    public func artistDetail(id: String, fallbackName: String = "Artist") throws
        -> (artist: Artist, albums: [Album])
    {
        guard hasCredentials || isUserLoggedIn else {
            let albums = try seedHome().flatMap(\.albums).filter {
                $0.artists.contains(where: { $0.id == id })
            }
            return (Artist(id: id, name: fallbackName), albums)
        }

        // Artist links already carry the identity. Spending a quota unit on
        // profile enrichment before loading the useful releases is wasteful.
        let artist = Artist(id: id, name: fallbackName)
        var seen = Set<String>()
        var albums: [Album] = []
        let albumsData = try apiGet(
            path: "/v1/artists/\(id)/albums",
            query: [
                "include_groups": "album,single",
                "limit": "\(Self.searchLimitMax)",
                "offset": "0",
            ],
            userRequired: false
        )
        let page = try JSONDecoder().decode(ArtistAlbumsResponse.self, from: albumsData)
        albums.append(contentsOf: page.items.map { $0.asAlbum() }.filter {
            seen.insert($0.id).inserted
        })
        return (artist, albums)
    }

    // MARK: - Player (Connect / spotifyd)

    public func listDevices() throws -> [SpotifyDevice] {
        let data = try apiGet(path: "/v1/me/player/devices", query: [:], userRequired: true)
        let decoded = try JSONDecoder().decode(DevicesResponse.self, from: data)
        return decoded.devices.map { $0.asDevice() }
    }

    /// Pick spotifyd (or `SPOTIFY_DEVICE_NAME`) when present, else the active
    /// device, else the first unrestricted one.
    ///
    /// Empty list almost always means spotifyd is only on zeroconf and has not
    /// finished `spotifyd authenticate` for this Spotify account — the Web API
    /// only lists devices already bound to the user, not LAN advertisements.
    public func resolvePlaybackDevice(
        among devices: [SpotifyDevice]? = nil
    ) throws -> SpotifyDevice {
        let list = try devices ?? listDevices()
        guard !list.isEmpty else {
            throw SpotifyError(Self.emptyDevicesHint)
        }
        let needle = preferredDeviceName.lowercased()
        if let match = list.first(where: {
            !$0.isRestricted && Self.name($0.name, matches: needle)
        }) {
            return match
        }
        // Also try the stock zeroconf label even if SPOTIFY_DEVICE_NAME was set.
        if needle != "spotifyd",
           let match = list.first(where: {
               !$0.isRestricted && Self.name($0.name, matches: "spotifyd")
           })
        {
            return match
        }
        if let active = list.first(where: { $0.isActive && !$0.isRestricted }) {
            return active
        }
        if let any = list.first(where: { !$0.isRestricted }) {
            return any
        }
        throw SpotifyError("All Connect devices are restricted")
    }

    public static let emptyDevicesHint = """
        No Connect devices on this account. spotifyd can be running and still \
        missing here until it logs in:
          1) spotifyd authenticate
          2) systemctl --user restart spotifyd
        Then Account → Refresh devices. (Zeroconf “Spotifyd@host” alone is not enough.)
        """

    private static func name(_ deviceName: String, matches needle: String) -> Bool {
        let n = deviceName.lowercased()
        let k = needle.lowercased()
        return n.contains(k)
    }

    /// Start a track on a Connect device (spotifyd when available).
    ///
    /// **Album context first.** A single-element `uris` list stops after that
    /// track; `context_uri` + offset keeps the album (or other context) as the
    /// queue so the next song starts when the current one ends — the Connect
    /// device advances, we only refresh the UI from `GET /me/player`.
    ///
    /// `queue` is a fallback when there is no album: remaining playable track
    /// URIs from the current index onward (e.g. a search hit list).
    public func play(
        track: Track,
        queue: [Track] = [],
        deviceId: String? = nil
    ) throws {
        let device = try deviceId.map { id in
            SpotifyDevice(
                id: id, name: "", type: "", isActive: false, isRestricted: false
            )
        } ?? resolvePlaybackDevice()

        let body = try playBody(track: track, queue: queue)
        try apiPut(
            path: "/v1/me/player/play",
            query: ["device_id": device.id],
            json: body,
            userRequired: true
        )
    }

    /// JSON body for `PUT /me/player/play` (exposed for tests / diagnostics).
    func playBody(track: Track, queue: [Track] = []) throws -> [String: Any] {
        var body: [String: Any] = ["position_ms": 0]

        // 1) Album (or any parent) context — continuous play through the disc.
        if let album = track.album, !album.id.isEmpty, Track.looksLikeSpotifyId(album.id) {
            body["context_uri"] = album.uri
            if let uri = track.uri {
                body["offset"] = ["uri": uri]
            } else {
                body["offset"] = ["position": max(0, track.trackNumber - 1)]
            }
            return body
        }

        // 2) Explicit queue of track URIs from this track forward.
        let fromQueue: [String] = {
            if let idx = queue.firstIndex(where: { $0.id == track.id }) {
                return queue[idx...].compactMap(\.uri)
            }
            var uris = [String]()
            if let uri = track.uri { uris.append(uri) }
            for t in queue {
                guard let u = t.uri, u != track.uri else { continue }
                uris.append(u)
            }
            return uris
        }()
        if !fromQueue.isEmpty {
            body["uris"] = fromQueue
            return body
        }

        // 3) Lone track — will not auto-advance (nothing follows).
        if let uri = track.uri {
            body["uris"] = [uri]
            return body
        }

        throw SpotifyError("Track has no playable Spotify id or album context")
    }

    public func playAlbum(_ album: Album, deviceId: String? = nil) throws {
        let device = try deviceId.map {
            SpotifyDevice(id: $0, name: "", type: "", isActive: false, isRestricted: false)
        } ?? resolvePlaybackDevice()
        try apiPut(
            path: "/v1/me/player/play",
            query: ["device_id": device.id],
            json: ["context_uri": album.uri, "position_ms": 0],
            userRequired: true
        )
    }

    public func pause() throws {
        try apiPut(path: "/v1/me/player/pause", query: [:], json: nil, userRequired: true)
    }

    public func resume() throws {
        try apiPut(path: "/v1/me/player/play", query: [:], json: nil, userRequired: true)
    }

    public func skipNext() throws {
        try apiPost(path: "/v1/me/player/next", query: [:], userRequired: true)
    }

    public func skipPrevious() throws {
        try apiPost(path: "/v1/me/player/previous", query: [:], userRequired: true)
    }

    /// Seek within the current track (Connect / spotifyd).
    public func seek(positionMs: Int, deviceId: String? = nil) throws {
        var query: [String: String] = [
            "position_ms": "\(max(0, positionMs))",
        ]
        if let deviceId { query["device_id"] = deviceId }
        try apiPut(
            path: "/v1/me/player/seek",
            query: query,
            json: nil,
            userRequired: true
        )
    }

    /// Set the active Connect device's volume, clamped to Spotify's 0…100 range.
    public func setVolume(percent: Int, deviceId: String? = nil) throws {
        var query: [String: String] = [
            "volume_percent": "\(min(100, max(0, percent)))",
        ]
        if let deviceId { query["device_id"] = deviceId }
        try apiPut(
            path: "/v1/me/player/volume",
            query: query,
            json: nil,
            userRequired: true
        )
    }

    public func transferPlayback(to deviceId: String, play: Bool = false) throws {
        try apiPut(
            path: "/v1/me/player",
            query: [:],
            json: ["device_ids": [deviceId], "play": play],
            userRequired: true
        )
    }

    /// Current playback; `nil` when nothing is active (204).
    public func currentPlayback() throws -> PlaybackSnapshot? {
        let response = try apiRequest(
            method: "GET",
            path: "/v1/me/player",
            query: [:],
            json: nil,
            userRequired: true
        )
        let (data, status) = (response.data, response.status)
        if status == 204 || data.isEmpty { return nil }
        let decoded = try JSONDecoder().decode(PlaybackResponse.self, from: data)
        return decoded.asSnapshot()
    }

    // MARK: - Catalog HTTP

    private static let searchLimitMax = 10

    private func searchAlbums(
        query: String,
        limit: Int,
        offset: Int = 0
    ) throws -> [Album] {
        let capped = min(max(1, limit), Self.searchLimitMax)
        var queryItems: [String: String] = [
            "q": query,
            "type": "album",
            "limit": "\(capped)",
        ]
        if offset > 0 {
            queryItems["offset"] = "\(offset)"
        }
        let data = try apiGet(path: "/v1/search", query: queryItems, userRequired: false)
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.albums?.items.map { $0.asAlbum() } ?? []
    }

    private func fetchAlbum(id: String) throws -> (Album, [Track]) {
        let data = try apiGet(path: "/v1/albums/\(id)", query: [:], userRequired: false)
        let decoded = try JSONDecoder().decode(APIAlbumDetail.self, from: data)
        let album = decoded.asAlbum()
        let tracks = (decoded.tracks?.items ?? []).enumerated().map { idx, t in
            t.asTrack(trackNumber: t.track_number ?? (idx + 1), album: album)
        }
        return (album, tracks)
    }

    // MARK: - Auth + transport

    private func bearerToken(userRequired: Bool) throws -> String {
        if userRequired {
            guard let oauth else {
                throw SpotifyError("Set SPOTIFY_CLIENT_ID and log in for playback")
            }
            return try oauth.accessToken()
        }
        // Prefer user token when present (works for catalog too).
        if let oauth, oauth.isLoggedIn, let token = try? oauth.accessToken() {
            return token
        }
        return try appToken()
    }

    private func appToken() throws -> String {
        lock.lock()
        if let token = appAccessToken, appTokenExpiresAt > Date().addingTimeInterval(30) {
            lock.unlock()
            return token
        }
        lock.unlock()

        guard let id = clientId, let secret = clientSecret else {
            throw SpotifyError("Missing SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET")
        }
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else {
            throw SpotifyError("Bad token URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let basic = Data("\(id):\(secret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("grant_type=client_credentials".utf8)

        let (data, status) = try HTTP.data(for: request)
        guard (200...299).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SpotifyError("HTTP \(status) from Spotify: \(body.prefix(200))")
        }
        let token = try JSONDecoder().decode(AppTokenResponse.self, from: data)
        lock.lock()
        appAccessToken = token.access_token
        appTokenExpiresAt = Date().addingTimeInterval(TimeInterval(token.expires_in))
        lock.unlock()
        return token.access_token
    }

    private func apiGet(
        path: String,
        query: [String: String],
        userRequired: Bool
    ) throws -> Data {
        // Player/device reads are live state and must never be cached. Catalog
        // reads are safe to retain locally and include poster URLs, which makes
        // revisiting album and artist pages immediate.
        let cacheKey = userRequired ? nil : CatalogCache.key(path: path, query: query)
        if let cacheKey, let cached = CatalogCache.value(for: cacheKey) {
            print("SpotifyClient cache hit \(path) query=\(query)")
            return cached
        }
        if !userRequired {
            lock.lock()
            let retryAt = rateLimitUntil
            lock.unlock()
            if retryAt > Date() {
                let seconds = max(1, Int(retryAt.timeIntervalSinceNow.rounded(.up)))
                throw SpotifyError("Spotify catalog rate limit active; retry in \(seconds)s")
            }
        }
        print("SpotifyClient GET \(path) query=\(query) userRequired=\(userRequired)")
        let response = try apiRequest(
            method: "GET", path: path, query: query, json: nil, userRequired: userRequired
        )
        let (data, status) = (response.data, response.status)
        if status == 429, !userRequired { recordRateLimit(response) }
        guard (200...299).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SpotifyError("HTTP \(status) \(path): \(body.prefix(200))")
        }
        if let cacheKey {
            CatalogCache.store(data, for: cacheKey)
        }
        return data
    }

    private func apiPut(
        path: String,
        query: [String: String],
        json: [String: Any]?,
        userRequired: Bool
    ) throws {
        let response = try apiRequest(
            method: "PUT", path: path, query: query, json: json, userRequired: userRequired
        )
        let (data, status) = (response.data, response.status)
        // 202 = accepted but no active device yet; treat as soft failure message.
        guard status == 204 || status == 200 || status == 202 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SpotifyError("HTTP \(status) \(path): \(body.prefix(200))")
        }
    }

    private func apiPost(
        path: String,
        query: [String: String],
        userRequired: Bool
    ) throws {
        let response = try apiRequest(
            method: "POST", path: path, query: query, json: nil, userRequired: userRequired
        )
        let (data, status) = (response.data, response.status)
        guard status == 204 || status == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SpotifyError("HTTP \(status) \(path): \(body.prefix(200))")
        }
    }

    private func apiRequest(
        method: String,
        path: String,
        query: [String: String],
        json: [String: Any]?,
        userRequired: Bool
    ) throws -> HTTP.Response {
        let token = try bearerToken(userRequired: userRequired)
        var components = URLComponents(string: "https://api.spotify.com\(path)")!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw SpotifyError("Bad API URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try HTTP.jsonBody(json)
        }
        return try HTTP.response(for: request)
    }

    private func recordRateLimit(_ response: HTTP.Response) {
        let delay = response.header("Retry-After").flatMap(TimeInterval.init) ?? 30
        lock.lock()
        rateLimitUntil = max(rateLimitUntil, Date().addingTimeInterval(max(1, delay)))
        lock.unlock()
    }

    // MARK: - Seed

    private func seedHome() throws -> [CatalogSection] {
        let resolved = try SeedCatalog.resolveAll()
        let chunk = max(1, (resolved.count + 2) / 3)
        var sections: [CatalogSection] = []
        let titles = ["Featured albums", "More of what you like", "Jump back in"]
        var i = 0
        var s = 0
        while i < resolved.count {
            let end = min(i + chunk, resolved.count)
            sections.append(CatalogSection(
                id: "seed-\(s)",
                title: titles[s % titles.count],
                albums: Array(resolved[i..<end])
            ))
            i = end
            s += 1
        }
        return sections
    }
}

// MARK: - Wire types

private struct AppTokenResponse: Decodable {
    var access_token: String
    var expires_in: Int
}

private struct SearchResponse: Decodable {
    var albums: APIAlbumPage?
    var tracks: APITrackPage?
}

private struct APIAlbumPage: Decodable {
    var items: [APIAlbum]
}

private struct APIImage: Decodable {
    var url: String
    var width: Int?
    var height: Int?
}

private struct APIArtist: Decodable {
    var id: String?
    var name: String
    var images: [APIImage]?
    var genres: [String]?
    var followers: APIFollowers?

    func asArtist() -> Artist {
        Artist(
            id: id ?? name,
            name: name,
            images: (images ?? []).map {
                CoverImage(url: $0.url, width: $0.width, height: $0.height)
            },
            genres: genres ?? [],
            followerCount: followers?.total
        )
    }
}

private struct APIFollowers: Decodable {
    var total: Int?
}

private struct ArtistAlbumsResponse: Decodable {
    var items: [APIAlbum]
    var next: String?
}

private struct APIAlbum: Decodable {
    var id: String
    var name: String
    var artists: [APIArtist]?
    var images: [APIImage]?
    var release_date: String?
    var total_tracks: Int?

    func asAlbum() -> Album {
        Album(
            id: id,
            name: name,
            artists: (artists ?? []).map {
                ArtistRef(id: $0.id ?? $0.name, name: $0.name)
            },
            images: (images ?? []).map {
                CoverImage(url: $0.url, width: $0.width, height: $0.height)
            },
            releaseDate: release_date,
            totalTracks: total_tracks
        )
    }
}

private struct APIAlbumDetail: Decodable {
    var id: String
    var name: String
    var artists: [APIArtist]?
    var images: [APIImage]?
    var release_date: String?
    var total_tracks: Int?
    var tracks: APITrackPage?

    func asAlbum() -> Album {
        Album(
            id: id,
            name: name,
            artists: (artists ?? []).map {
                ArtistRef(id: $0.id ?? $0.name, name: $0.name)
            },
            images: (images ?? []).map {
                CoverImage(url: $0.url, width: $0.width, height: $0.height)
            },
            releaseDate: release_date,
            totalTracks: total_tracks
        )
    }
}

private struct APITrackPage: Decodable {
    var items: [APITrack]
}

private struct APITrack: Decodable {
    var id: String?
    var name: String
    var artists: [APIArtist]?
    var duration_ms: Int?
    var track_number: Int?
    var album: APIAlbum?

    func asTrack(trackNumber: Int, album: Album) -> Track {
        Track(
            id: id ?? "\(album.id)-\(trackNumber)",
            name: name,
            artists: (artists ?? []).map {
                ArtistRef(id: $0.id ?? $0.name, name: $0.name)
            },
            durationMs: duration_ms ?? 0,
            trackNumber: trackNumber,
            album: album
        )
    }

    func asSearchTrack(fallbackNumber: Int) -> Track {
        let parent = album?.asAlbum()
        return Track(
            id: id ?? "search-\(fallbackNumber)-\(name)",
            name: name,
            artists: (artists ?? []).map {
                ArtistRef(id: $0.id ?? $0.name, name: $0.name)
            },
            durationMs: duration_ms ?? 0,
            trackNumber: track_number ?? fallbackNumber,
            album: parent
        )
    }
}

private struct DevicesResponse: Decodable {
    var devices: [APIDevice]
}

private struct APIDevice: Decodable {
    var id: String?
    var is_active: Bool?
    var is_restricted: Bool?
    var name: String?
    var type: String?
    var volume_percent: Int?

    func asDevice() -> SpotifyDevice {
        SpotifyDevice(
            id: id ?? "",
            name: name ?? "Unknown",
            type: type ?? "",
            isActive: is_active ?? false,
            isRestricted: is_restricted ?? false,
            volumePercent: volume_percent
        )
    }
}

private struct PlaybackResponse: Decodable {
    var is_playing: Bool?
    var progress_ms: Int?
    var device: APIDevice?
    var item: APIPlaybackItem?

    func asSnapshot() -> PlaybackSnapshot {
        let track: Track? = {
            guard let item else { return nil }
            let albumImages = (item.album?.images ?? []).map {
                CoverImage(url: $0.url, width: $0.width, height: $0.height)
            }
            let album: Album? = item.album.map {
                Album(
                    id: $0.id ?? "",
                    name: $0.name ?? "",
                    artists: (item.artists ?? []).map {
                        ArtistRef(id: $0.id ?? $0.name, name: $0.name)
                    },
                    images: albumImages
                )
            }
            return Track(
                id: item.id ?? "",
                name: item.name ?? "Unknown",
                artists: (item.artists ?? []).map {
                    ArtistRef(id: $0.id ?? $0.name, name: $0.name)
                },
                durationMs: item.duration_ms ?? 0,
                trackNumber: item.track_number ?? 1,
                album: album
            )
        }()
        return PlaybackSnapshot(
            isPlaying: is_playing ?? false,
            progressMs: progress_ms ?? 0,
            device: device?.asDevice(),
            track: track
        )
    }
}

private struct APIPlaybackItem: Decodable {
    var id: String?
    var name: String?
    var duration_ms: Int?
    var track_number: Int?
    var artists: [APIArtist]?
    var album: APIPlaybackAlbum?
}

private struct APIPlaybackAlbum: Decodable {
    var id: String?
    var name: String?
    var images: [APIImage]?
}
