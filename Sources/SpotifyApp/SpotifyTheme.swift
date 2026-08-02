import LavaUI

struct SpotifyPalette: Identifiable, Sendable {
    let id: String
    let name: String
    let subtitle: String
    let theme: Theme
    let green: Color
    let sidebar: Color
    let playerBar: Color
    let cardHover: Color
    let coverPlaceholder: Color

    var swatches: [Color] {
        [theme.background, theme.panel, green, theme.selectionFill]
    }
}

/// Product palettes plus Spotify-specific chrome that is not represented by
/// LavaUI's general semantic theme tokens.
enum SpotifyTheme {
    private static let themeKey = "theme.id"

    nonisolated(unsafe) private(set) static var selectedIndex = 0

    /// Restores the last chosen palette from `AppSettings` (no-op if unset).
    static func restore() {
        guard let id = AppSettings.string(forKey: themeKey),
              let index = palettes.firstIndex(where: { $0.id == id })
        else { return }
        apply(index, persist: false)
    }

    static let palettes: [SpotifyPalette] = [
        SpotifyPalette(
            id: "midnight-groove", name: "Midnight Groove",
            subtitle: "The classic dark room",
            theme: Theme(
                textPrimary: Color(r: 1, g: 1, b: 1),
                textSecondary: Color(r: 0.70, g: 0.70, b: 0.70),
                textMuted: Color(r: 0.55, g: 0.55, b: 0.55),
                textDim: Color(r: 0.40, g: 0.40, b: 0.40),
                accent: Color(r: 0.12, g: 0.84, b: 0.38),
                selected: Color(r: 0.12, g: 0.84, b: 0.38),
                background: Color(r: 0.07, g: 0.07, b: 0.07),
                panel: Color(r: 0.09, g: 0.09, b: 0.09),
                inset: Color(r: 0.14, g: 0.14, b: 0.14),
                canvas: Color(r: 0.08, g: 0.08, b: 0.08),
                hover: Color(r: 0.20, g: 0.20, b: 0.20),
                selectionFill: Color(r: 0.12, g: 0.35, b: 0.20),
                border: Color(r: 0.22, g: 0.22, b: 0.22),
                cornerRadius: 6, controlPadding: 6
            ),
            green: Color(r: 0.12, g: 0.84, b: 0.38),
            sidebar: Color(r: 0, g: 0, b: 0),
            playerBar: Color(r: 0.11, g: 0.11, b: 0.11),
            cardHover: Color(r: 0.18, g: 0.18, b: 0.18),
            coverPlaceholder: Color(r: 0.16, g: 0.16, b: 0.16)
        ),
        SpotifyPalette(
            id: "aurora", name: "Aurora",
            subtitle: "Indigo nights and mint light",
            theme: Theme(
                textPrimary: Color(r: 0.94, g: 0.97, b: 1),
                textSecondary: Color(r: 0.68, g: 0.73, b: 0.84),
                textMuted: Color(r: 0.48, g: 0.57, b: 0.70),
                textDim: Color(r: 0.36, g: 0.43, b: 0.57),
                accent: Color(r: 0.35, g: 0.94, b: 0.75),
                selected: Color(r: 0.49, g: 0.45, b: 1.0),
                background: Color(r: 0.035, g: 0.045, b: 0.10),
                panel: Color(r: 0.065, g: 0.075, b: 0.16),
                inset: Color(r: 0.09, g: 0.10, b: 0.21),
                canvas: Color(r: 0.045, g: 0.055, b: 0.13),
                hover: Color(r: 0.13, g: 0.16, b: 0.29),
                selectionFill: Color(r: 0.18, g: 0.25, b: 0.42),
                border: Color(r: 0.20, g: 0.27, b: 0.43),
                cornerRadius: 9, controlPadding: 7
            ),
            green: Color(r: 0.35, g: 0.94, b: 0.75),
            sidebar: Color(r: 0.025, g: 0.03, b: 0.075),
            playerBar: Color(r: 0.045, g: 0.05, b: 0.12),
            cardHover: Color(r: 0.13, g: 0.16, b: 0.29),
            coverPlaceholder: Color(r: 0.10, g: 0.12, b: 0.23)
        ),
        SpotifyPalette(
            id: "sunset-mixtape", name: "Sunset Mixtape",
            subtitle: "Plum, coral, and warm amber",
            theme: Theme(
                textPrimary: Color(r: 1, g: 0.95, b: 0.91),
                textSecondary: Color(r: 0.84, g: 0.69, b: 0.69),
                textMuted: Color(r: 0.70, g: 0.51, b: 0.54),
                textDim: Color(r: 0.52, g: 0.37, b: 0.43),
                accent: Color(r: 1.0, g: 0.42, b: 0.35),
                selected: Color(r: 1.0, g: 0.70, b: 0.28),
                background: Color(r: 0.105, g: 0.035, b: 0.09),
                panel: Color(r: 0.16, g: 0.055, b: 0.13),
                inset: Color(r: 0.20, g: 0.075, b: 0.15),
                canvas: Color(r: 0.13, g: 0.04, b: 0.105),
                hover: Color(r: 0.27, g: 0.09, b: 0.18),
                selectionFill: Color(r: 0.42, g: 0.13, b: 0.20),
                border: Color(r: 0.39, g: 0.14, b: 0.25),
                cornerRadius: 10, controlPadding: 7
            ),
            green: Color(r: 1.0, g: 0.42, b: 0.35),
            sidebar: Color(r: 0.07, g: 0.018, b: 0.065),
            playerBar: Color(r: 0.10, g: 0.025, b: 0.08),
            cardHover: Color(r: 0.27, g: 0.09, b: 0.18),
            coverPlaceholder: Color(r: 0.22, g: 0.07, b: 0.15)
        ),
        SpotifyPalette(
            id: "deep-ocean", name: "Deep Ocean",
            subtitle: "Cool blue with electric cyan",
            theme: Theme(
                textPrimary: Color(r: 0.92, g: 0.98, b: 1),
                textSecondary: Color(r: 0.62, g: 0.76, b: 0.82),
                textMuted: Color(r: 0.43, g: 0.61, b: 0.68),
                textDim: Color(r: 0.31, g: 0.46, b: 0.54),
                accent: Color(r: 0.16, g: 0.82, b: 0.94),
                selected: Color(r: 0.22, g: 0.68, b: 1.0),
                background: Color(r: 0.025, g: 0.075, b: 0.095),
                panel: Color(r: 0.04, g: 0.115, b: 0.14),
                inset: Color(r: 0.055, g: 0.15, b: 0.17),
                canvas: Color(r: 0.03, g: 0.09, b: 0.115),
                hover: Color(r: 0.075, g: 0.21, b: 0.24),
                selectionFill: Color(r: 0.06, g: 0.29, b: 0.34),
                border: Color(r: 0.10, g: 0.30, b: 0.34),
                cornerRadius: 8, controlPadding: 6
            ),
            green: Color(r: 0.16, g: 0.82, b: 0.94),
            sidebar: Color(r: 0.015, g: 0.05, b: 0.065),
            playerBar: Color(r: 0.025, g: 0.08, b: 0.095),
            cardHover: Color(r: 0.075, g: 0.21, b: 0.24),
            coverPlaceholder: Color(r: 0.06, g: 0.16, b: 0.19)
        ),
        SpotifyPalette(
            id: "paper-jam", name: "Paper Jam",
            subtitle: "Warm daylight and rich ink",
            theme: Theme(
                textPrimary: Color(r: 0.12, g: 0.105, b: 0.09),
                textSecondary: Color(r: 0.35, g: 0.31, b: 0.27),
                textMuted: Color(r: 0.46, g: 0.40, b: 0.34),
                textDim: Color(r: 0.57, g: 0.52, b: 0.46),
                accent: Color(r: 0.82, g: 0.24, b: 0.18),
                selected: Color(r: 0.12, g: 0.48, b: 0.43),
                background: Color(r: 0.94, g: 0.91, b: 0.84),
                panel: Color(r: 0.985, g: 0.965, b: 0.91),
                inset: Color(r: 1.0, g: 0.99, b: 0.96),
                canvas: Color(r: 0.90, g: 0.86, b: 0.78),
                hover: Color(r: 0.88, g: 0.82, b: 0.73),
                selectionFill: Color(r: 0.77, g: 0.87, b: 0.81),
                border: Color(r: 0.72, g: 0.66, b: 0.57),
                cornerRadius: 5, controlPadding: 6
            ),
            green: Color(r: 0.82, g: 0.24, b: 0.18),
            sidebar: Color(r: 0.87, g: 0.82, b: 0.73),
            playerBar: Color(r: 0.90, g: 0.86, b: 0.78),
            cardHover: Color(r: 0.88, g: 0.82, b: 0.73),
            coverPlaceholder: Color(r: 0.80, g: 0.75, b: 0.67)
        ),
    ]

    static var palette: SpotifyPalette { palettes[selectedIndex] }
    static var theme: Theme { palette.theme }
    static var green: Color { palette.green }
    static var coverPlaceholder: Color { palette.coverPlaceholder }
    static var playerBar: Color { palette.playerBar }
    static var sidebar: Color { palette.sidebar }
    static var cardHover: Color { palette.cardHover }

    static func apply(_ index: Int, persist: Bool = true) {
        guard !palettes.isEmpty else { return }
        selectedIndex = min(max(0, index), palettes.count - 1)
        Theme.current = palettes[selectedIndex].theme
        if persist {
            AppSettings.set(palettes[selectedIndex].id, forKey: themeKey)
        }
    }
}
