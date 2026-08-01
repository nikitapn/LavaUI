import LavaUI

/// Spotify-leaning dark palette. Applied as `Theme.current` at launch so
/// semantic tokens (`.primary`, `.accent`, …) resolve correctly.
enum SpotifyTheme {
    static let green = Color(r: 0.12, g: 0.84, b: 0.38)
    static let coverPlaceholder = Color(r: 0.16, g: 0.16, b: 0.16)
    static let playerBar = Color(r: 0.11, g: 0.11, b: 0.11)
    static let sidebar = Color(r: 0.00, g: 0.00, b: 0.00)
    static let cardHover = Color(r: 0.18, g: 0.18, b: 0.18)

    static let theme = Theme(
        textPrimary: Color(r: 1.0, g: 1.0, b: 1.0),
        textSecondary: Color(r: 0.70, g: 0.70, b: 0.70),
        textMuted: Color(r: 0.55, g: 0.55, b: 0.55),
        textDim: Color(r: 0.40, g: 0.40, b: 0.40),
        accent: green,
        selected: green,
        background: Color(r: 0.07, g: 0.07, b: 0.07),
        panel: Color(r: 0.09, g: 0.09, b: 0.09),
        inset: Color(r: 0.14, g: 0.14, b: 0.14),
        canvas: Color(r: 0.08, g: 0.08, b: 0.08),
        hover: Color(r: 0.20, g: 0.20, b: 0.20),
        selectionFill: Color(r: 0.12, g: 0.35, b: 0.20),
        border: Color(r: 0.22, g: 0.22, b: 0.22),
        cornerRadius: 6,
        controlPadding: 6
    )
}
