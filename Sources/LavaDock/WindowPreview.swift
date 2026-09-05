import Foundation
import LavaClient
import LavaIDL
import LavaShell
import LavaUI

// Hovering an icon that has a stack of windows behind it puts a shelf of live
// thumbnails above the dock, and clicking one raises that window. The badge
// on the icon already says "four" — this is what says *which* four.
//
// Three things make it work, and none of them are new machinery:
//
//   * `ImageSurface`. A thumbnail is not a screenshot the dock fetched and
//     decoded; it is the *name* of a compositor surface in the draw list, and
//     the compositor imports that window's last dma-buf when it replays the
//     command. Same path the switcher's posters take — see `UIImage
//     .surfacePoster`. A GPU-less client could not do this any other way, and
//     `CaptureSurface` (PNG, CPU readback) would put a megabyte and a decode
//     on a hover.
//   * `SetPanelThickness`. The dock's strip is 138pt and a shelf of
//     thumbnails is not. The panel grows to `Dock.openHeight` while the
//     preview is up and shrinks when it comes down — grown *and left* grown
//     the way the taskbar's is would be wrong here, because a dock reserves
//     nothing, and `panelCovered` reads the whole surface of a panel that
//     reserves nothing as its strip. A permanently tall dock would decide it
//     was covered by any window in the bottom quarter of the screen and
//     auto-hide from it.
//   * `ForgetWindowPoster`. The compositor caches a poster per (window, size)
//     so a shelf costs one import rather than one per frame. The switcher
//     never has to think about that — it is a fresh process each time. A dock
//     is here all session, so the second hover would show the first hover's
//     picture unless it says otherwise, once, as the preview opens.
//
// The delay is the whole reason this is pleasant rather than a strobe: the
// pointer crosses the dock on its way to somewhere else far more often than
// it stops on an icon, and a shelf that opened on contact would flash open
// four times on the way past.

/// The open preview: whose windows it is showing.
///
/// The window list itself is not copied in. It is read from the entry at
/// paint time, so a window that closes while the shelf is up loses its card
/// on the next frame rather than leaving a thumbnail of something that has
/// gone.
struct DockPreview {
    var appId: String
    /// Dismissed, and only still here to finish leaving. A closing shelf is
    /// painted and nothing else: it answers no clicks, holds no input region,
    /// and does not keep the dock out. See `DockModel.closePreview`.
    var closing = false
}

extension Dock {
    /// How long the shelf takes to arrive, and to leave.
    ///
    /// It is a real object appearing over the desktop, and appearing is
    /// something objects do in a moment rather than instantly — one frame from
    /// nothing to a full shelf of windows reads as a glitch, which is what it
    /// looked like. Out is quicker than in: whatever is leaving should get out
    /// of the way faster than it arrived, or dismissing feels sticky.
    static let previewFadeIn: Double = 0.14
    static let previewFadeOut: Double = 0.09
    /// How far below its resting place the shelf starts, and sinks back to.
    ///
    /// Small on purpose. The shelf belongs to the icon under it, so it rises
    /// out of the dock rather than flying in from anywhere; more than about a
    /// card's padding stops reading as "out of" and starts reading as "past".
    static let previewRise: Float = 10

    /// How long the pointer has to rest on an icon before the shelf opens.
    ///
    /// Long enough that crossing the dock on the way somewhere else opens
    /// nothing, short enough that stopping on an icon does not feel like
    /// waiting. Only the *first* open pays it: once a shelf is up, sliding
    /// along to the next stacked icon switches immediately, because by then
    /// the pointer has already said what it is doing.
    static let previewDelay: Double = 0.4

    /// Resting height of a thumbnail. Width follows the window's own aspect,
    /// so a terminal is narrow and a browser is wide — a shelf of identical
    /// rectangles tells you nothing about which window is which.
    static let previewThumbHeight: Float = 104
    static let previewThumbMinWidth: Float = 72
    static let previewThumbMaxWidth: Float = 260
    static let previewTitleHeight: Float = 16
    /// Between the thumbnail and the name under it.
    static let previewTitleGap: Float = 4
    static let previewCardPadding: Float = 6
    static let previewCardSpacing: Float = 8
    static let previewStripPadding: Float = 10
    static let previewStripRadius: Float = 14

    /// Between the top of the plate and the bottom of the shelf.
    ///
    /// Bigger than it looks like it needs to be: a magnified icon rises
    /// `magnifiedSize - iconSize - padding` above the plate, and the shelf
    /// has to clear that or the icon the shelf is *about* pokes into it.
    static let previewGap: Float = 24

    /// Longest edge the compositor downsamples a poster to. A thumbnail is
    /// ~100pt tall, so this is deliberately generous — the import is a
    /// downsample on the GPU either way, and the shelf keeps its sharpness
    /// when a window's aspect makes its card wide.
    static let previewPosterSide: UInt32 = 512

    static var previewCardHeight: Float {
        previewCardPadding * 2 + previewThumbHeight + previewTitleGap
            + previewTitleHeight
    }

    static var previewStripHeight: Float {
        previewCardHeight + previewStripPadding * 2
    }

    /// Panel thickness while a shelf is up. The plate is positioned from the
    /// *bottom* of the surface, so growing the panel does not move it: the
    /// compositor puts a bottom panel's origin at `output - thickness` and
    /// the extra height appears above the dock, which is where the shelf is.
    static var openHeight: Float {
        plateInset + plateHeight + previewGap + previewStripHeight
    }

    /// One thumbnail and the name under it.
    struct PreviewCard {
        var surfaceId: UInt32
        var title: String
        var focused: Bool
        var minimized: Bool
        /// The card's own plate, which is what a click hits.
        var rect: (x: Float, y: Float, w: Float, h: Float)
        /// Where the window's picture goes inside it.
        var thumb: (x: Float, y: Float, w: Float, h: Float)
    }

    struct PreviewLayout {
        var strip: (x: Float, y: Float, w: Float, h: Float)
        var cards: [PreviewCard]

        /// The same shelf, moved `dy` down the screen.
        ///
        /// For paint only. Hit tests keep using the resting rectangles, so a
        /// click during the 140ms it is arriving lands on the card the user
        /// aimed at rather than the one that happens to be under the pointer
        /// mid-flight.
        func lowered(by dy: Float) -> PreviewLayout {
            guard dy != 0 else { return self }
            var copy = self
            copy.strip.y += dy
            for index in copy.cards.indices {
                copy.cards[index].rect.y += dy
                copy.cards[index].thumb.y += dy
            }
            return copy
        }

        /// Which card is at this point, in surface coordinates.
        func card(atX x: Float, y: Float) -> PreviewCard? {
            cards.first {
                x >= $0.rect.x && x <= $0.rect.x + $0.rect.w
                    && y >= $0.rect.y && y <= $0.rect.y + $0.rect.h
            }
        }
    }

    /// The shelf for `windows`, centred over the icon at `anchorX`.
    ///
    /// Nil when there is nothing to show. Everything is derived from the
    /// surface rather than stored, so the shelf follows an icon that slides
    /// and re-centres itself when the screen's width changes under it.
    static func previewLayout(
        windows: [WindowInfo], anchorX: Float, frame: CanvasFrame
    ) -> PreviewLayout? {
        guard !windows.isEmpty, frame.w > 0 else { return nil }

        var thumbHeight = previewThumbHeight
        var thumbWidths = windows.map { window -> Float in
            let raw: Float =
                window.width > 0 && window.height > 0
                ? Float(window.width) / Float(window.height) : 16 / 10
            let aspect = min(max(raw, 0.45), 2.8)
            return min(
                max(thumbHeight * aspect, previewThumbMinWidth),
                previewThumbMaxWidth
            )
        }

        // Chrome is fixed; only the pictures shrink. Scaling the padding too
        // would make a shelf of eight windows read as a different widget from
        // a shelf of two.
        let count = Float(windows.count)
        let chrome = previewStripPadding * 2
            + previewCardSpacing * (count - 1)
            + previewCardPadding * 2 * count
        let room = frame.w - 16 - chrome
        let pictures = thumbWidths.reduce(0, +)
        if room > 0, pictures > room {
            let scale = room / pictures
            thumbWidths = thumbWidths.map { $0 * scale }
            thumbHeight *= scale
        }

        let cardHeight = previewCardPadding * 2 + thumbHeight
            + previewTitleGap + previewTitleHeight
        let stripHeight = cardHeight + previewStripPadding * 2
        let stripWidth = chrome + thumbWidths.reduce(0, +)

        // Off the top of the plate, not off the top of the surface: the
        // surface is however tall the panel currently is, and the shelf hangs
        // from the dock rather than from the screen's edge.
        let plateTop = frame.y + frame.h - plateInset - plateHeight
        let stripY = plateTop - previewGap - stripHeight
        let stripX = min(
            max(frame.x + 8, anchorX - stripWidth * 0.5),
            max(frame.x + 8, frame.x + frame.w - stripWidth - 8)
        )

        var cards: [PreviewCard] = []
        var pen = stripX + previewStripPadding
        for (index, window) in windows.enumerated() {
            let thumbWidth = thumbWidths[index]
            let cardWidth = thumbWidth + previewCardPadding * 2
            let cardY = stripY + previewStripPadding
            cards.append(PreviewCard(
                surfaceId: window.surfaceId,
                title: window.title.isEmpty ? "Untitled" : window.title,
                focused: window.focused,
                minimized: window.minimized,
                rect: (pen, cardY, cardWidth, cardHeight),
                thumb: (
                    pen + previewCardPadding, cardY + previewCardPadding,
                    thumbWidth, thumbHeight
                )
            ))
            pen += cardWidth + previewCardSpacing
        }
        return PreviewLayout(
            strip: (stripX, stripY, stripWidth, stripHeight), cards: cards
        )
    }

    /// Where a picture of `aspect` sits inside `box`, whole and centred.
    ///
    /// The card was sized from the window's aspect, so this is usually the
    /// box itself — it stops mattering exactly when the clamps bite, which is
    /// the ultrawide terminal and the tall phone-shaped window, and those are
    /// the two cases a stretched thumbnail would look worst on.
    static func fit(
        aspect: Float, in box: (x: Float, y: Float, w: Float, h: Float)
    ) -> (x: Float, y: Float, w: Float, h: Float) {
        guard aspect > 0, box.w > 0, box.h > 0 else { return box }
        let boxAspect = box.w / box.h
        if aspect > boxAspect {
            let h = box.w / aspect
            return (box.x, box.y + (box.h - h) * 0.5, box.w, h)
        }
        let w = box.h * aspect
        return (box.x + (box.w - w) * 0.5, box.y, w, box.h)
    }

    /// `text` trimmed with an ellipsis so it fits `width`.
    ///
    /// LavaUI has one of these, memoised, but it is internal to the
    /// framework; a card title is one short string per window per frame, so
    /// a plain walk is the right size of answer here.
    static func fitted(_ text: String, to width: Float, font: UIFont) -> String {
        guard width > 0 else { return "" }
        if font.measure(text).width <= width { return text }
        var candidate = text
        while !candidate.isEmpty {
            candidate.removeLast()
            let trial = candidate.trimmingCharacters(in: .whitespaces) + "…"
            if font.measure(trial).width <= width { return trial }
        }
        return ""
    }
}

extension DockView {
    /// The shelf: a plate, a card per window, a live picture in each — at
    /// `progress` along its arrival, where 0 is gone and 1 is there.
    ///
    /// Everything fades together and the whole thing rides up out of the dock.
    /// That also covers the frame or two where a poster has been named but not
    /// yet resolved: such a card draws its application's icon instead, and at
    /// a fifth of full opacity nobody sees it swap.
    func paintPreview(
        _ list: DrawList, entry: DockEntry, layout: Dock.PreviewLayout,
        theme: Theme, pointer: (x: Float, y: Float), progress: Float
    ) {
        let alpha = max(0, min(1, progress))
        // Below this it is one more draw list for nothing.
        guard alpha > 0.01 else { return }
        let shown = layout.lowered(by: (1 - alpha) * Dock.previewRise)

        let strip = shown.strip
        list.roundedRect(
            x: strip.x, y: strip.y, w: strip.w, h: strip.h,
            color: fade(Color(r: theme.panel.r, g: theme.panel.g,
                              b: theme.panel.b, a: 0.96), alpha),
            radius: Dock.previewStripRadius
        )
        list.strokedRect(
            x: strip.x, y: strip.y, w: strip.w, h: strip.h,
            color: fade(theme.border.opacity(0.6), alpha),
            radius: Dock.previewStripRadius, width: 1
        )

        // Hovering is asked of the resting shelf, for the same reason clicking
        // is: what the pointer is on should not depend on how far along the
        // animation is.
        let hovered = layout.card(atX: pointer.x, y: pointer.y)?.surfaceId
        for card in shown.cards {
            paintPreviewCard(
                list, entry: entry, card: card, theme: theme,
                hovered: card.surfaceId == hovered, alpha: alpha
            )
        }
    }

    private func paintPreviewCard(
        _ list: DrawList, entry: DockEntry, card: Dock.PreviewCard,
        theme: Theme, hovered: Bool, alpha: Float
    ) {
        let rect = card.rect
        if hovered || card.focused {
            list.roundedRect(
                x: rect.x, y: rect.y, w: rect.w, h: rect.h,
                color: fade(hovered ? theme.hover
                                    : theme.selected.opacity(0.5), alpha),
                radius: 8
            )
        }

        // The window's own pixels, or the reason there are none. A window
        // that has never been configured has no buffer to import, and a
        // minimized one is dimmed rather than hidden: it is in the stack,
        // and the shelf is how you get it back.
        let thumb = card.thumb
        list.roundedRect(
            x: thumb.x, y: thumb.y, w: thumb.w, h: thumb.h,
            color: fade(theme.inset, alpha), radius: 4
        )
        if let poster = model.previewPosters[card.surfaceId] {
            let picture = Dock.fit(
                aspect: poster.pixelHeight > 0
                    ? poster.pixelWidth / poster.pixelHeight : 1,
                in: thumb
            )
            list.image(
                poster, x: picture.x, y: picture.y, w: picture.w, h: picture.h,
                tint: fade(card.minimized
                    ? Color(r: 1, g: 1, b: 1, a: 0.55)
                    : Color(r: 1, g: 1, b: 1), alpha)
            )
        } else if let icon = model.icon(for: entry) {
            let side = min(48, min(thumb.w, thumb.h) * 0.6)
            list.image(
                icon,
                x: thumb.x + (thumb.w - side) * 0.5,
                y: thumb.y + (thumb.h - side) * 0.5,
                w: side, h: side,
                tint: fade(Color(r: 1, g: 1, b: 1), alpha)
            )
        }
        list.strokedRect(
            x: thumb.x, y: thumb.y, w: thumb.w, h: thumb.h,
            color: fade(card.focused ? theme.accent
                                     : theme.border.opacity(0.7), alpha),
            radius: 4, width: card.focused ? 1.5 : 1
        )

        guard let font = model.badgeFont() else { return }
        let width = rect.w - Dock.previewCardPadding * 2
        let label = Dock.fitted(card.title, to: width - 8, font: font)
        guard !label.isEmpty else { return }
        let textW = font.measure(label).width
        // `text` insets the pen 4px; pull back so the label centres on the
        // card rather than sitting 4px right of centre.
        list.text(
            label,
            x: rect.x + (rect.w - textW) * 0.5 - 4,
            y: thumb.y + thumb.h + Dock.previewTitleGap,
            w: textW + 8, h: Dock.previewTitleHeight,
            color: fade(card.minimized
                ? theme.textDim
                : (card.focused ? theme.textPrimary : theme.textSecondary),
                alpha),
            font: font
        )
    }
}

/// A colour dimmed by the shelf's progress, keeping whatever alpha it already
/// had. There is no group opacity in a draw list — every command carries its
/// own colour — so fading a panel means fading each thing on it.
private func fade(_ color: Color, _ alpha: Float) -> Color {
    alpha >= 1 ? color : color.opacity(color.a * alpha)
}
