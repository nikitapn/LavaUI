import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Curated album ids + oembed resolution for a credentials-free first paint.
///
/// Spotify's oembed endpoint needs no token and returns a title plus a 300px
/// cover URL — enough to exercise the image cache with real posters. Track
/// lists for a few ids are hardcoded so album detail is not empty in seed mode.
public enum SeedCatalog {
    /// Popular albums with stable Spotify ids (verified via oembed).
    public static let albumIDs: [String] = [
        "4aawyAB9vmqN3uQ7FjRGTy", // Global Warming
        "2noRn2Aes5aoNVsU6iWThc", // Discovery
        "3T4tUhGYeRNVUGevb0wThu", // ÷ (Deluxe)
        "1ATL5GLyefJaxhQzSPVrLX", // Scorpion
        "4yP0hdKOZPNshxUOjY0cZj", // After Hours
        "2ODvWsOgouMbaA5xf0RkJe", // Starboy
        "6DEjYFkNZh67HP7R9PSZvv", // reputation
        "0bUTHlWbkSQysoM3VsWldT", // Demon Days
        "5Z9iiGl2FcIfa3BMiv6OIw", // Whenever You Need Somebody
        "2cWBwpqMsDJC1ZUwz813lo", // The Eminem Show
        "6nYfHQnvkvOTNHnOhDT3sr", // BE
        "1lXY618HWkwYKJWBRYR4MK", // More Life
        "0ETFjACtuP2ADo6LFhL6HN", // Abbey Road
        "2WT1pbYjLJciAR26yMebkH", // Dark Side of the Moon
        "6ZG5lRT77aJ3btmArcykra", // Parachutes
        "5sY6UIQ32GqwMLAfSNEaXb", // Circles
        "0sNOF9WDwhWunNAHPD3Baj", // She's So Unusual
        "4m2880jivSbbyEGAKfITCa", // Random Access Memories
        "7xV2TzoaVc0ycW7fwBwAml", // Fine Line
        "2QJmrSgbdM35R67eoGQo4j", // 1989
        "2dIGnmEIy1WZIcZCFSj6i8", // Plastic Beach
        "0S0KGZnfBGSIssfF54WSJh", // WHEN WE ALL FALL ASLEEP…
    ]

    /// Resolve all seed ids through oembed. Failures are skipped so a single
    /// retired id does not blank the home screen. Runs in parallel — sequential
    /// was fine for a probe but multiplies cold-start latency by album count.
    public static func resolveAll() throws -> [Album] {
        var seen = Set<String>()
        let ids = albumIDs.filter { seen.insert($0).inserted }
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var byId: [String: Album] = [:]
        }
        let box = Box()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "lavaspotify.oembed", attributes: .concurrent)
        for id in ids {
            group.enter()
            queue.async {
                defer { group.leave() }
                if let album = try? resolveAlbum(id: id) {
                    box.lock.lock()
                    box.byId[id] = album
                    box.lock.unlock()
                }
            }
        }
        _ = group.wait(timeout: .now() + 45)
        // Preserve seed order so shelves stay stable across launches.
        let out = ids.compactMap { box.byId[$0] }
        if out.isEmpty {
            throw SpotifyError("Seed oembed returned no albums — check network")
        }
        return out
    }

    public static func resolveAlbum(id: String) throws -> Album {
        let urlString = "https://open.spotify.com/oembed?url=https://open.spotify.com/album/\(id)"
        guard let url = URL(string: urlString) else {
            throw SpotifyError("Bad oembed URL")
        }
        var request = URLRequest(url: url)
        request.setValue("LavaSpotify/0.1", forHTTPHeaderField: "User-Agent")

        let (data, status) = try HTTP.data(for: request, timeout: 20)
        guard status == 200 else {
            throw SpotifyError("oembed HTTP \(status) for album \(id)")
        }
        let oembed = try JSONDecoder().decode(OEmbed.self, from: data)
        let title = oembed.title ?? "Album \(id)"
        // oembed often returns only the album title. Prefer a known artist for
        // seed ids; otherwise try "Artist – Album" parsing.
        let name: String
        let artist: String
        if let known = knownArtists[id] {
            artist = known
            name = title
        } else {
            let split = splitTitle(title)
            artist = split.0
            name = split.1
        }
        var images: [CoverImage] = []
        if let thumb = oembed.thumbnail_url {
            images.append(CoverImage(
                url: thumb,
                width: oembed.thumbnail_width,
                height: oembed.thumbnail_height
            ))
        }
        return Album(
            id: id,
            name: name,
            artists: [ArtistRef(id: artist, name: artist)],
            images: images,
            totalTracks: nil
        )
    }

    /// oembed does not include artist; hardcode the ones we seed so the UI
    /// does not say "Various Artists" under every cover.
    private static let knownArtists: [String: String] = [
        "4aawyAB9vmqN3uQ7FjRGTy": "Pitbull",
        "2noRn2Aes5aoNVsU6iWThc": "Daft Punk",
        "3T4tUhGYeRNVUGevb0wThu": "Ed Sheeran",
        "1ATL5GLyefJaxhQzSPVrLX": "Drake",
        "4yP0hdKOZPNshxUOjY0cZj": "The Weeknd",
        "2ODvWsOgouMbaA5xf0RkJe": "The Weeknd",
        "6DEjYFkNZh67HP7R9PSZvv": "Taylor Swift",
        "0bUTHlWbkSQysoM3VsWldT": "Gorillaz",
        "5Z9iiGl2FcIfa3BMiv6OIw": "Rick Astley",
        "2cWBwpqMsDJC1ZUwz813lo": "Eminem",
        "6nYfHQnvkvOTNHnOhDT3sr": "BTS",
        "1lXY618HWkwYKJWBRYR4MK": "Drake",
        "0ETFjACtuP2ADo6LFhL6HN": "The Beatles",
        "2WT1pbYjLJciAR26yMebkH": "Pink Floyd",
        "6ZG5lRT77aJ3btmArcykra": "Coldplay",
        "5sY6UIQ32GqwMLAfSNEaXb": "Post Malone",
        "0sNOF9WDwhWunNAHPD3Baj": "Cyndi Lauper",
        "4m2880jivSbbyEGAKfITCa": "Daft Punk",
        "7xV2TzoaVc0ycW7fwBwAml": "Harry Styles",
        "2QJmrSgbdM35R67eoGQo4j": "Taylor Swift",
        "2dIGnmEIy1WZIcZCFSj6i8": "Gorillaz",
        "0S0KGZnfBGSIssfF54WSJh": "Billie Eilish",
    ]

    /// A few canned track lists so detail is not blank without API credentials.
    public static func tracks(for albumId: String, album: Album) -> [Track] {
        let names: [String]
        switch albumId {
        case "2noRn2Aes5aoNVsU6iWThc": // Discovery
            names = [
                "One More Time", "Aerodynamic", "Digital Love", "Harder, Better, Faster, Stronger",
                "Crescendolls", "Nightvision", "Superheroes", "High Life", "Something About Us",
                "Voyager", "Veridis Quo", "Short Circuit", "Face to Face", "Too Long",
            ]
        case "3T4tUhGYeRNVUGevb0wThu": // ÷
            names = [
                "Eraser", "Castle on the Hill", "Dive", "Shape of You", "Perfect",
                "Galway Girl", "Happier", "New Man", "Hearts Don't Break Around Here",
                "What Do I Know?", "How Would You Feel (Paean)", "Supermarket Flowers",
            ]
        case "4yP0hdKOZPNshxUOjY0cZj": // After Hours
            names = [
                "Alone Again", "Too Late", "Hardest to Love", "Scared to Live",
                "Snowchild", "Escape from LA", "Heartless", "Faith", "Blinding Lights",
                "In Your Eyes", "Save Your Tears", "Repeat After Me (Interlude)",
                "After Hours", "Until I Bleed Out",
            ]
        default:
            // Synthetic placeholders — UI-only until audio arrives.
            names = (1...8).map { "Track \($0)" }
        }
        return names.enumerated().map { idx, name in
            Track(
                id: "\(albumId)-t\(idx + 1)",
                name: name,
                artists: album.artists,
                durationMs: 180_000 + idx * 17_000,
                trackNumber: idx + 1,
                album: album
            )
        }
    }

    private static func splitTitle(_ title: String) -> (String, String) {
        // oembed sometimes returns "Album Name" only; sometimes "Artist – Album".
        for sep in [" – ", " - ", " — "] {
            if let r = title.range(of: sep) {
                let artist = String(title[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let name = String(title[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !artist.isEmpty, !name.isEmpty { return (artist, name) }
            }
        }
        return ("Various Artists", title)
    }
}

private struct OEmbed: Decodable {
    var title: String?
    var thumbnail_url: String?
    var thumbnail_width: Int?
    var thumbnail_height: Int?
}
