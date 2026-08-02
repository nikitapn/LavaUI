import Foundation

// Catalog types shared by the Web API path and the oembed seed path.
// Keep them free of LavaUI so the client stays unit-testable without a window.

/// A remote image the UI will download and hand to `ImageStore`.
public struct CoverImage: Hashable, Sendable, Codable {
    public var url: String
    public var width: Int?
    public var height: Int?

    public init(url: String, width: Int? = nil, height: Int? = nil) {
        self.url = url
        self.width = width
        self.height = height
    }
}

public struct ArtistRef: Hashable, Identifiable, Sendable, Codable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Artist: Hashable, Identifiable, Sendable, Codable {
    public var id: String
    public var name: String
    public var images: [CoverImage]
    public var genres: [String]
    public var followerCount: Int?

    public init(
        id: String, name: String, images: [CoverImage] = [],
        genres: [String] = [], followerCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.images = images
        self.genres = genres
        self.followerCount = followerCount
    }

    public var preferredImage: CoverImage? {
        guard !images.isEmpty else { return nil }
        return images.min {
            abs(($0.width ?? 0) - 300) < abs(($1.width ?? 0) - 300)
        }
    }
}

public struct Album: Hashable, Identifiable, Sendable, Codable {
    public var id: String
    public var name: String
    public var artists: [ArtistRef]
    public var images: [CoverImage]
    public var releaseDate: String?
    public var totalTracks: Int?

    public init(
        id: String,
        name: String,
        artists: [ArtistRef],
        images: [CoverImage],
        releaseDate: String? = nil,
        totalTracks: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.artists = artists
        self.images = images
        self.releaseDate = releaseDate
        self.totalTracks = totalTracks
    }

    public var artistLine: String {
        artists.map(\.name).joined(separator: ", ")
    }

    public var uri: String { "spotify:album:\(id)" }

    /// Prefer a mid-size cover (~300px) when the API offers several.
    public var preferredCover: CoverImage? {
        guard !images.isEmpty else { return nil }
        let scored = images.map { img -> (CoverImage, Int) in
            let w = img.width ?? 0
            return (img, abs(w - 300))
        }
        return scored.min(by: { $0.1 < $1.1 })?.0 ?? images.first
    }
}

public struct Track: Hashable, Identifiable, Sendable, Codable {
    public var id: String
    public var name: String
    public var artists: [ArtistRef]
    public var durationMs: Int
    public var trackNumber: Int
    public var album: Album?

    public init(
        id: String,
        name: String,
        artists: [ArtistRef],
        durationMs: Int,
        trackNumber: Int,
        album: Album? = nil
    ) {
        self.id = id
        self.name = name
        self.artists = artists
        self.durationMs = durationMs
        self.trackNumber = trackNumber
        self.album = album
    }

    public var artistLine: String {
        artists.map(\.name).joined(separator: ", ")
    }

    public var durationLabel: String {
        let total = max(0, durationMs / 1000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Real Spotify track ids are 22-char base62. Seed placeholders are not.
    public var isPlayableSpotifyId: Bool {
        Self.looksLikeSpotifyId(id)
    }

    public var uri: String? {
        isPlayableSpotifyId ? "spotify:track:\(id)" : nil
    }

    public static func looksLikeSpotifyId(_ id: String) -> Bool {
        id.count == 22 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        }
    }
}

public struct Playlist: Hashable, Identifiable, Sendable, Codable {
    public var id: String
    public var name: String
    public var description: String
    public var images: [CoverImage]
    public var ownerName: String?

    public init(
        id: String,
        name: String,
        description: String = "",
        images: [CoverImage] = [],
        ownerName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.images = images
        self.ownerName = ownerName
    }

    public var preferredCover: CoverImage? {
        images.first
    }
}

/// One horizontally scrolling shelf on Home (e.g. "Made for you").
public struct CatalogSection: Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var albums: [Album]

    public init(id: String, title: String, albums: [Album]) {
        self.id = id
        self.title = title
        self.albums = albums
    }
}

public enum SpotifyNav: Hashable, Sendable {
    case home
    case search
    case library
    case album(String)
    case artist(String)
}

/// A Spotify Connect device — spotifyd, desktop app, phone, Web Playback SDK, …
public struct SpotifyDevice: Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var type: String
    public var isActive: Bool
    public var isRestricted: Bool
    public var volumePercent: Int?

    public init(
        id: String,
        name: String,
        type: String,
        isActive: Bool,
        isRestricted: Bool,
        volumePercent: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.isActive = isActive
        self.isRestricted = isRestricted
        self.volumePercent = volumePercent
    }

    /// Heuristic: stock spotifyd advertises as `Spotifyd@hostname` on zeroconf
    /// and usually keeps a similar Connect display name after authenticate.
    public var looksLikeSpotifyd: Bool {
        let n = name.lowercased()
        return n.contains("spotifyd") || n.hasPrefix("spotifyd@")
    }
}

/// Snapshot of remote playback (Connect / Player API).
public struct PlaybackSnapshot: Sendable {
    public var isPlaying: Bool
    public var progressMs: Int
    public var device: SpotifyDevice?
    public var track: Track?

    public init(
        isPlaying: Bool,
        progressMs: Int = 0,
        device: SpotifyDevice? = nil,
        track: Track? = nil
    ) {
        self.isPlaying = isPlaying
        self.progressMs = progressMs
        self.device = device
        self.track = track
    }

    public var progressLabel: String {
        let total = max(0, progressMs / 1000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

public struct SpotifyError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
