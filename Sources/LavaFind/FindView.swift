#if canImport(LavaIDL)
import Foundation
import LavaClient
import LavaFindCore
import LavaIDL
import LavaUI

/// The look, in one place. Surfaces and text follow the desktop's theme;
/// the amber is LavaFind's own, the one colour that says "this is where you
/// are typing, and this is what Enter will open".
enum FindStyle {
    static let accent = Color(rgb24: 0xF0A43A)
    static let width: Float = 640
    static let barHeight: Float = 58
    static let rowHeight: Float = 52
    /// Rows shown before the list scrolls. Enough to choose from, few enough
    /// that the panel never covers the whole screen.
    static let visibleRows = 7
    static let radius: Float = 14
    /// Where the bar sits, as a fraction of the window's height. High enough
    /// that a full list of `visibleRows` still fits below it on a 720p screen.
    static let topFraction: Float = 0.18

    static var surface: Color { Theme.current.background.opacity(0.97) }
    /// The plate over the compositor's frost. Translucent enough to show the
    /// blur, opaque enough to read a path against whatever is behind it — by
    /// eye, against a wallpaper; see docs/colour-and-blending.md before
    /// changing it by arithmetic.
    static var glass: Color { Theme.current.background.opacity(0.72) }
    /// Blur of the desktop behind the bar and the panel, in pixels.
    static let frostRadius: Float = 14
    static var raised: Color { Theme.current.panel }
    static var line: Color { Theme.current.border }
    static var dim: Color { Theme.current.textDim }
    static var secondary: Color { Theme.current.textSecondary }
}

/// Faces loaded in `main`, before the first frame.
enum FindFonts {
    nonisolated(unsafe) static var mono: UIFont?
    nonisolated(unsafe) static var small: UIFont?
}

/// Escape, Enter and the arrows: they belong to the list while the caret is
/// in the field, the way they do in every launcher. True consumes the key, so
/// Down never becomes a character.
func handleKey(_ event: LavaUI.InputEvent) -> Bool {
    guard event.kind == .key, event.keyAction != KeyAction.release else { return false }
    switch event.keyCode {
    case KeyCode.escape:
        model.escape()
        return true
    case KeyCode.enter:
        model.openSelected()
        return true
    case KeyCode.up:
        model.move(by: -1)
        return true
    case KeyCode.down:
        model.move(by: 1)
        return true
    case KeyCode.tab:
        model.move(by: KeyMods.contains(event.keyMods, KeyMods.shift) ? -1 : 1)
        return true
    default:
        return false
    }
}

struct FindView: View {
    var body: some View {
        // The surface is clear and fills the screen, so a click anywhere but
        // the card is a click "away" — which closes it, the way a popover
        // closes. The card swallows its own clicks so they do not count.
        VStack(flexGrow: 1, alignment: .center, onClick: { LavaClient.quit() }) {
            // A fixed share of the window's height, not a spacer: spacers
            // split whatever is *left over*, so the bar rode up and down as the
            // list under it grew and shrank. The bar stays put; only the list
            // moves, and only downwards.
            HStack(height: .pct(FindStyle.topFraction * 100)) {}
            VStack(spacing: 12, onClick: {}) {
                SearchBar()
                ResultsPanel()
            }
            .frame(width: .pt(FindStyle.width))
            Spacer(flexGrow: 1)
        }
    }
}

private struct SearchBar: View {
    var body: some View {
        HStack(
            height: .pt(FindStyle.barHeight), padding: 16, alignment: .center, spacing: 12
        ) {
            Magnifier(color: FindStyle.accent)
            TextField(
                text: Binding(model, \.query),
                placeholder: "Search files, PDFs, videos…",
                autoFocus: true,
                focusRing: FocusRingStyle.none,
                onSubmit: { model.openSelected() }
            )
            .flexGrow(1)
            .frame(height: .pct(100))
            .background(.clear)
            KeyChip("esc")
        }
        .border(FindStyle.accent.opacity(0.75), width: 1.5)
        .cornerRadius(FindStyle.radius)
        .underlay { Frost() }
    }
}

/// A keycap: "esc" in the bar.
private struct KeyChip: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label, color: FindStyle.secondary, font: FindFonts.mono, align: .center)
            .padding(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
            .border(FindStyle.line, width: 1)
            .cornerRadius(6)
    }
}

private struct ResultsPanel: View {
    var body: some View {
        VStack(spacing: 0) {
            Header()
            Rows()
            // A rule rather than a filled footer: a fill reaches the panel's
            // edge, and the panel's rounding does not clip it, so over glass
            // its square corners showed outside the round ones.
            Divider(style: DividerStyle(thickness: 1, spacing: 0, color: FindStyle.line))
            Footer()
        }
        .border(FindStyle.line, width: 1)
        .cornerRadius(FindStyle.radius)
        .underlay { Frost() }
    }
}

private struct Header: View {
    var body: some View {
        let title: String = {
            if !model.isSearching { return "RECENT" }
            if !model.answered && model.hits.isEmpty { return "SEARCHING" }
            let count = model.hits.count
            return count == 0 ? "FILES" : "FILES · \(count)\(model.truncated ? "+" : "")"
        }()
        Text(title, color: FindStyle.dim, font: FindFonts.mono)
            .padding(EdgeInsets(top: 12, leading: 18, bottom: 6, trailing: 18))
    }
}

private struct Rows: View {
    var body: some View {
        let rows = model.rows
        let message: String? = {
            if let problem = model.problem { return problem }
            guard rows.isEmpty else { return nil }
            if !model.isSearching { return "Nothing opened recently. Type to search." }
            return model.answered ? "Nothing matches “\(model.query)”." : "Searching…"
        }()
        // A fixed height, the rows' own until there are too many: there is no
        // max-height, and a ScrollView fills whatever it is given.
        //
        // The list stays mounted when it is empty, at zero height, rather than
        // being swapped for the message. Swapped out and back in, its rows
        // came back laid out but never drawn.
        let shown = min(rows.count, FindStyle.visibleRows)
        VStack(spacing: 0) {
            if let message { Message(message) }
            ScrollView(indicatorInset: 6) {
                VStack(padding: 6, spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { item in
                        Row(hit: item.element, index: item.offset)
                    }
                }
            }
            .frame(height: .pt(shown == 0 ? 0 : Float(shown) * (FindStyle.rowHeight + 2) + 12))
        }
    }
}

private struct Message: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text, color: FindStyle.dim)
            .padding(EdgeInsets(top: 14, leading: 18, bottom: 18, trailing: 18))
    }
}

private struct Row: View {
    let hit: Hit
    let index: Int

    var body: some View {
        let isSelected = model.selected == index
        let isDirectory = hit.kind == .directory
        let (name, folder) = FindFormat.split(hit.path, home: NSHomeDirectory())
        // Only a search highlights: a recent item matched nothing.
        let parts = model.isSearching
            ? FindFormat.highlight(name, start: hit.matchStart, length: hit.matchLength)
            : (before: name, match: "", after: "")

        return HStack(
            height: .pt(FindStyle.rowHeight), padding: 0, alignment: .center, spacing: 14,
            onClick: { model.open(hit) },
            onHover: { inside in if inside { model.selected = index } }
        ) {
            Badge(text: FindFormat.badge(ext: hit.ext, isDirectory: isDirectory))
            VStack(spacing: 2) {
                HighlightedName(parts: parts)
                Text(folder, color: FindStyle.dim, font: FindFonts.mono, lineLimit: 1)
            }
            .flexGrow(1)
            .flexShrink(1)
            Text(
                FindFormat.detail(size: hit.size, mtime: hit.mtime, isDirectory: isDirectory),
                color: FindStyle.dim, font: FindFonts.mono, lineLimit: 1
            )
            // Always laid out, only drawn when selected, so the detail column
            // does not jump sideways as the selection moves.
            Text("Open ↵", color: isSelected ? FindStyle.accent : .clear,
                 font: FindFonts.mono, lineLimit: 1)
        }
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 14))
        .background(isSelected ? FindStyle.raised : .clear)
        .cornerRadius(8)
        .scrollIntoView(when: isSelected)
    }
}

/// The name, with the part that matched in the accent colour.
///
/// Drawn rather than built from three `Text`s side by side: every text leaf
/// measures 8 pt wider than its glyphs (a hit-target margin), which put a
/// visible gap either side of the match, and each of the three ellipsized on
/// its own — "Celia Hawkes… Serb ian…". One run, cut once at the end, is
/// what a name looks like.
private struct HighlightedName: View {
    let parts: (before: String, match: String, after: String)

    var body: some View {
        let font = FontStore.default
        let height = (font?.lineHeight ?? 20) + 4
        let before = parts.before, match = parts.match, after = parts.after
        return Canvas(
            label: "Name \"\(before)\(match)\(after)\"", width: .pct(100), height: .pt(height),
            paint: { draw, frame in
                guard let font else { return }
                // `DrawList.text` insets its pen by 4, as `Text` does; the
                // segments are placed by width from one origin, so the inset is
                // paid once.
                let room = frame.w - 8
                var segments = [(before, Theme.current.textPrimary),
                                (match, FindStyle.accent),
                                (after, Theme.current.textPrimary)]
                if font.measure(before + match + after).width > room {
                    segments = Self.cut(segments, to: room, font: font)
                }
                var x = frame.x
                for (string, color) in segments where !string.isEmpty {
                    draw.text(string, x: x, y: frame.y + 2, w: frame.w, h: height,
                              color: color, font: font)
                    x += font.measure(string).width
                }
            }
        )
    }

    /// Drops characters from the end, across segments, until the name and an
    /// ellipsis fit. Names are short and this runs only for the ones too long
    /// for the row.
    static func cut(
        _ segments: [(String, Color)], to room: Float, font: UIFont
    ) -> [(String, Color)] {
        var parts = segments.map { (Array($0.0), $0.1) }
        func text() -> String { parts.map { String($0.0) }.joined() }
        while font.measure(text() + "…").width > room,
              let last = parts.lastIndex(where: { !$0.0.isEmpty }) {
            parts[last].0.removeLast()
        }
        var out = parts.map { (String($0.0), $0.1) }
        if let last = out.lastIndex(where: { !$0.0.isEmpty }) { out[last].0 += "…" }
        return out
    }
}

/// "PDF" in a small outlined box, one width for every row.
private struct Badge: View {
    let text: String

    var body: some View {
        Text(text, color: FindStyle.secondary, font: FindFonts.mono, align: .center)
            .frame(width: .pt(44), height: .pt(26))
            .border(FindStyle.line, width: 1)
            .cornerRadius(6)
    }
}

private struct Footer: View {
    var body: some View {
        let roots = FindFormat.roots(model.roots, home: NSHomeDirectory())
        let place = roots.isEmpty ? "" : "Searching \(roots)"
        HStack(alignment: .center, spacing: 12) {
            Text(model.indexing ? "Indexing… \(place)" : place,
                 color: FindStyle.dim, font: FindFonts.mono, lineLimit: 1)
                .flexShrink(1)
            Spacer()
            Text("↑↓ move   ↵  open   esc \(model.query.isEmpty ? "close" : "clear")",
                 color: FindStyle.dim, font: FindFonts.mono, lineLimit: 1)
        }
        .padding(EdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18))
    }
}

/// The glass under the bar and the panel: the compositor's blur of the
/// desktop behind this box, and a translucent plate over it.
///
/// Per box rather than one plate for the card, so the 12 pt between the bar
/// and the list stays clear desktop. Both rects go to the compositor in one
/// `SetBackdropBlurRegions` per frame, and only on frames where one moved —
/// the list growing as results arrive is a new rect on the frame it grows.
///
/// With no compositor to ask (a windowed run), `frostDesktop` says so and
/// the plate is drawn nearly opaque instead: in-window blur would only smear
/// this surface's own empty framebuffer.
private struct Frost: View {
    var body: some View {
        Canvas(
            label: "Frost", width: .pct(100), height: .pct(100),
            paint: { draw, frame in
                let frosted = draw.frostDesktop(
                    x: frame.x, y: frame.y, w: frame.w, h: frame.h,
                    radius: FindStyle.frostRadius, cornerRadius: FindStyle.radius
                )
                draw.roundedRect(
                    x: frame.x, y: frame.y, w: frame.w, h: frame.h,
                    color: frosted ? FindStyle.glass : FindStyle.surface,
                    radius: FindStyle.radius
                )
            }
        )
    }
}

/// Drawn, like the launcher's: a ring and a handle, crisp at any scale and
/// independent of which symbol fonts are installed.
private struct Magnifier: View {
    let color: Color

    var body: some View {
        Canvas(
            label: "Search icon", width: .pt(22), height: .pt(22),
            paint: { draw, frame in
                let cx = frame.x + 9
                let cy = frame.y + 9
                // A ring, not a disc with a disc on it: over frosted glass a
                // filled middle is a dark blob in the desktop's colours.
                let steps = 40
                func circle(_ r: Float) -> [(x: Float, y: Float)] {
                    (0...steps).map { i in
                        let a = Float(i) / Float(steps) * 2 * .pi
                        return (cx + r * cos(a), cy + r * sin(a))
                    }
                }
                draw.ring(inner: circle(5), outer: circle(7), color: color)
                draw.line(
                    x1: cx + 4.5, y1: cy + 4.5, x2: frame.x + 20, y2: frame.y + 20,
                    color: color, width: 2.2
                )
            }
        )
    }
}
#endif
