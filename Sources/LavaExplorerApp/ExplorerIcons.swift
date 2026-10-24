import Foundation
import LavaExplorerCore
import LavaShell
import LavaUI

/// Where the explorer's pictures come from.
///
/// Two sources, on purpose. Folders and kinds of file come from the desktop's
/// icon theme, so a folder here looks like a folder everywhere else and a
/// theme change reaches it. The toolbar's glyphs are the app's own: a theme's
/// symbolic icons are drawn dark for a light toolkit to recolour, and this one
/// is drawn on a dark panel with nothing to recolour them — so they are white
/// strokes, tinted at draw time like text.
enum ExplorerIcons {
    /// A bundled toolbar glyph, by file name without `.svg`.
    static func glyph(_ name: String) -> String? {
        if let cached = glyphCache[name] { return cached }
        let found = Bundle.module.url(forResource: name, withExtension: "svg")?.path
        glyphCache[name] = found
        return found
    }

    /// The theme's picture for a file or folder, or nil when no theme on this
    /// machine has one — the caller then draws its own.
    static func file(_ entry: FileEntry) -> String? {
        resolve(FileIcon.candidates(for: entry))
    }

    /// The sidebar's glyph for a place: monochrome like the toolbar's, so a
    /// selected row's highlight is not fighting a blue folder on blue. Named
    /// through the same theme names the list uses, so the two agree about
    /// which folder is which.
    static func place(_ place: Place) -> String {
        let name = FileIcon.folder(place.path).first?.name ?? "folder"
        return placeGlyphs[name] ?? "place-folder"
    }

    private static let placeGlyphs: [String: String] = [
        "user-home": "place-home",
        "user-desktop": "place-desktop",
        "folder-documents": "place-documents",
        "folder-download": "place-downloads",
        "folder-pictures": "place-pictures",
        "folder-music": "place-music",
        "folder-videos": "place-videos",
        "drive-harddisk": "place-computer",
        "user-trash": "place-trash",
    ]

    private static func resolve(_ candidates: [FileIcon.Candidate]) -> String? {
        for candidate in candidates {
            if let path = IconLookup.themePath(
                forIconName: candidate.name, context: candidate.context.rawValue
            ) {
                return path
            }
        }
        return nil
    }

    nonisolated(unsafe) private static var glyphCache: [String: String?] = [:]
}

/// A toolbar glyph, tinted like the text beside it would be.
struct Glyph: View {
    let name: String
    let color: Color
    var size: Float = 16

    var body: some View {
        if let path = ExplorerIcons.glyph(name) {
            Image(
                path: path, width: .pt(size), height: .pt(size),
                tint: color, contentMode: .fit
            )
        } else {
            // A missing bundle is a broken install, not a reason for an empty
            // button nobody can find.
            Text(name, color: color, lineLimit: 1)
        }
    }
}
