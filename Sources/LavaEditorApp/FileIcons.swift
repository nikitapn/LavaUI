import Foundation
import LavaUI

/// What kind of file a tab or a tree row is, as a small logo — the way every
/// editor people are used to tells a Swift file from a header at a glance.
///
/// The logos are Simple Icons' (CC0; see `Resources/FileIcons/README.md`),
/// stored as white masks and tinted here, so one file serves both themes. A
/// file with no logo, or one whose logo is still loading, gets a plain file
/// glyph instead of a gap.
enum FileIcons {
    struct Logo: Equatable {
        let slug: String
        /// The brand's colour, or nil where it is black and would vanish on a
        /// dark theme: those take the text colour.
        let colour: UInt32?
    }

    /// The logo for a file name, if there is one.
    static func logo(for name: String) -> Logo? {
        let lower = name.lowercased()
        if let slug = byName[lower] { return logos[slug] }
        if lower.hasSuffix(".cmake") { return logos["cmake"] }
        if lower.hasPrefix("dockerfile") || lower.hasSuffix(".dockerfile") { return logos["docker"] }
        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else { return nil }
        return byExtension[String(lower[lower.index(after: dot)...])].flatMap { logos[$0] }
    }

    /// The colour to draw a logo in, readable on `theme`: a brand colour too
    /// dark for a dark background is lifted towards white.
    static func colour(_ logo: Logo, theme: Theme) -> Color {
        guard let rgb = logo.colour else { return theme.textSecondary }
        let colour = Color(rgb24: rgb)
        let dark = theme.inset.luminance < 0.5
        guard dark, colour.luminance < 0.35 else { return colour }
        let lift: Float = 0.45
        return Color(r: colour.r + (1 - colour.r) * lift, g: colour.g + (1 - colour.g) * lift,
                     b: colour.b + (1 - colour.b) * lift)
    }

    /// Draws `name`'s icon in a `size` square at `x`, `y`.
    static func draw(
        _ name: String, in list: DrawList, x: Float, y: Float, size: Float,
        theme: Theme, editor: Editor?
    ) {
        if let logo = logo(for: name), let editor, let path = path(logo.slug),
           // Decoded at twice the drawn size: crisp on a 2× screen, and still
           // well inside one atlas cell.
           let image = ImageStore.imageIfLoaded(path: path, maxPixelSize: UInt32(size * 2), into: editor)
        {
            list.image(image, x: x, y: y, w: size, h: size, tint: colour(logo, theme: theme))
            return
        }
        // Lucide's `file`, outline only.
        list.strokeIcon(plainFile, x: x, y: y, size: size, color: theme.textDim, strokeWidth: 1.75)
    }

    private static let plainFile: [IconShape] = [
        .path("M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"),
        .path("M14 2v4a2 2 0 0 0 2 2h4"),
    ]

    nonisolated(unsafe) private static var paths: [String: String?] = [:]

    private static func path(_ slug: String) -> String? {
        if let known = paths[slug] { return known }
        let found = Bundle.module.url(forResource: slug, withExtension: "svg", subdirectory: "FileIcons")?.path
            ?? Bundle.module.url(forResource: slug, withExtension: "svg")?.path
        paths[slug] = found
        return found
    }

    private static let logos: [String: Logo] = {
        let table: [(String, UInt32?)] = [
            ("c", 0xA8B9CC), ("clojure", 0x5881D8), ("cmake", 0x064F8C), ("cplusplus", 0x00599C),
            ("css", 0x663399), ("dart", 0x0175C2), ("docker", 0x2496ED), ("elixir", 0x4B275F),
            ("erlang", 0xA90533), ("fortran", 0x734F96), ("git", 0xF05032), ("gnubash", 0x4EAA25),
            ("go", 0x00ADD8), ("gradle", 0x02303A), ("graphql", 0xE10098), ("haskell", 0x5D4F85),
            ("html5", 0xE34F26), ("javascript", 0xF7DF1E), ("json", nil), ("julia", 0x9558B2),
            ("kotlin", 0x7F52FF), ("latex", 0x008080), ("less", 0x1D365D), ("lua", 0x000080),
            ("make", 0x6D00CC), ("markdown", nil), ("npm", 0xCB3837), ("ocaml", 0xEC6813),
            ("openjdk", nil), ("perl", 0x0073A1), ("php", 0x777BB4), ("python", 0x3776AB),
            ("r", 0x276DC3), ("react", 0x61DAFB), ("ruby", 0xCC342D), ("rust", nil),
            ("sass", 0xCC6699), ("scala", 0xDC322F), ("sqlite", 0x003B57), ("svelte", 0xFF3E00),
            ("swift", 0xF05138), ("terraform", 0x844FBA), ("toml", 0x9C4121), ("typescript", 0x3178C6),
            ("vim", 0x019733), ("vuedotjs", 0x4FC08D), ("webassembly", 0x654FF0), ("xml", 0x005FAD),
            ("yaml", 0xCB171E), ("zig", 0xF7A41D),
        ]
        return Dictionary(uniqueKeysWithValues: table.map { ($0.0, Logo(slug: $0.0, colour: $0.1)) })
    }()

    /// Whole names that say more than their extension.
    private static let byName: [String: String] = [
        "cmakelists.txt": "cmake", "makefile": "make", "gnumakefile": "make",
        "package.json": "npm", "package-lock.json": "npm",
        ".gitignore": "git", ".gitattributes": "git", ".gitmodules": "git", ".gitkeep": "git",
        "cargo.toml": "rust", "cargo.lock": "rust", "go.mod": "go", "go.sum": "go",
        "gemfile": "ruby", "rakefile": "ruby", ".vimrc": "vim", ".bashrc": "gnubash", ".zshrc": "gnubash",
        "build.gradle": "gradle", "settings.gradle": "gradle",
    ]

    private static let byExtension: [String: String] = [
        "swift": "swift",
        "c": "c", "h": "c",
        "cpp": "cplusplus", "cc": "cplusplus", "cxx": "cplusplus", "c++": "cplusplus",
        "hpp": "cplusplus", "hh": "cplusplus", "hxx": "cplusplus", "ipp": "cplusplus", "inl": "cplusplus",
        "py": "python", "pyi": "python",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "jsx": "react", "tsx": "react",
        "ts": "typescript", "mts": "typescript", "cts": "typescript",
        "rs": "rust", "go": "go",
        "md": "markdown", "markdown": "markdown",
        "json": "json", "jsonc": "json", "json5": "json",
        "html": "html5", "htm": "html5", "css": "css", "scss": "sass", "sass": "sass", "less": "less",
        "sh": "gnubash", "bash": "gnubash", "zsh": "gnubash",
        "yml": "yaml", "yaml": "yaml", "toml": "toml", "xml": "xml", "plist": "xml", "svg": "xml",
        "kt": "kotlin", "kts": "kotlin", "java": "openjdk", "lua": "lua", "rb": "ruby", "php": "php",
        "dart": "dart", "zig": "zig", "hs": "haskell", "sqlite": "sqlite", "db": "sqlite",
        "graphql": "graphql", "gql": "graphql", "vue": "vuedotjs", "svelte": "svelte",
        "mk": "make", "pl": "perl", "pm": "perl", "ex": "elixir", "exs": "elixir",
        "scala": "scala", "jl": "julia", "r": "r", "vim": "vim", "tex": "latex", "gradle": "gradle",
        "erl": "erlang", "clj": "clojure", "cljs": "clojure", "ml": "ocaml", "mli": "ocaml",
        "f90": "fortran", "f95": "fortran", "wasm": "webassembly", "wat": "webassembly",
        "tf": "terraform",
    ]
}
