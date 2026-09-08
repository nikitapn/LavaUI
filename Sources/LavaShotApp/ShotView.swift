import Foundation
import LavaShotCore
import LavaUI

/// The whole interface: one canvas the size of the screen.
///
/// Everything is painted rather than laid out, which is deliberate and not
/// laziness. The window is a frozen photograph of somebody's desktop with a
/// selection over it and a toolbar floating above that, and at the moment of
/// export the toolbar has to *not be there* — the export is a capture of this
/// very window, so anything the engine drew is in the picture. One `if` around
/// one paint call takes the entire interface out of the result; a real widget
/// tree would have to be dismantled and rebuilt around the same instant.
struct ShotView: View {
    let session: ShotSession

    var body: some View {
        Canvas(
            label: "shot",
            flexGrow: 1,
            onGesture: handleGesture,
            paint: paint
        )
        .background(Palette.behind)
    }

    // MARK: - Painting

    private func paint(_ list: DrawList, _ frame: CanvasFrame) {
        let screen = ShotRect(x: 0, y: 0, w: frame.w, h: frame.h)
        // Framebuffer pixels per layout unit, read off the shot rather than
        // asked for: this window covers the output and the capture is the
        // output, so the ratio between them is the scale by definition.
        let scale = frame.w > 0 && session.shotWidth > 0
            ? Float(session.shotWidth) / frame.w : 1
        session.beforePaint(screen: screen, scale: scale)

        guard let shot = session.shot else {
            list.rect(x: 0, y: 0, w: frame.w, h: frame.h, color: Palette.behind)
            label(
                list, session.notice ?? "Photographing the desktop…",
                x: frame.x + frame.w / 2 - 120, y: frame.y + frame.h / 2,
                color: Palette.hint
            )
            return
        }

        // The desktop, 1:1. `frame` is the whole window because this window is
        // the whole output, so no arithmetic is needed and none is done —
        // every pixel of the shot lands on the pixel it came from.
        list.image(shot, x: frame.x, y: frame.y, w: frame.w, h: frame.h)

        let selection = session.selection
        let clean = session.isExporting

        // Everything outside the selection goes dark, so the region reads as
        // the picture and the rest reads as context. Skipped at export time —
        // the crop is what the dim was describing, and a dimmed border inside
        // the saved file would be the tool leaving fingerprints on the result.
        if !clean {
            dim(list, frame: frame, screen: screen, selection: selection)
        }

        // Marks are clipped to the selection: a stroke that runs past the edge
        // is cropped out of the export anyway, and showing it outside makes
        // people think it will be kept.
        if let region = selection, !region.isEmpty {
            list.pushClip(
                x: frame.x + region.x, y: frame.y + region.y,
                w: region.w, h: region.h
            )
            for stroke in session.document.strokes {
                draw(stroke, list, origin: frame)
            }
            if let drafting = session.drafting, drafting.tool != .select {
                draw(drafting, list, origin: frame)
            }
            list.popClip()
        }

        if clean { return }

        if let region = selection, !region.isEmpty {
            outline(list, region: region, origin: frame)
        }
        toolbar(list, screen: screen, origin: frame)
        hint(list, frame: frame, screen: screen)
    }

    /// Four rectangles around the selection, or one over everything.
    private func dim(
        _ list: DrawList, frame: CanvasFrame, screen: ShotRect,
        selection: ShotRect?
    ) {
        guard let region = selection, !region.isEmpty else {
            list.rect(
                x: frame.x, y: frame.y, w: frame.w, h: frame.h,
                color: Palette.dim
            )
            return
        }
        let x = frame.x
        let y = frame.y
        list.rect(x: x, y: y, w: frame.w, h: region.y, color: Palette.dim)
        list.rect(
            x: x, y: y + region.maxY, w: frame.w, h: frame.h - region.maxY,
            color: Palette.dim
        )
        list.rect(
            x: x, y: y + region.y, w: region.x, h: region.h, color: Palette.dim
        )
        list.rect(
            x: x + region.maxX, y: y + region.y,
            w: frame.w - region.maxX, h: region.h, color: Palette.dim
        )
    }

    /// The selection's edge, its size, and a handle at each corner.
    private func outline(_ list: DrawList, region: ShotRect, origin: CanvasFrame) {
        let x = origin.x + region.x
        let y = origin.y + region.y
        list.strokedRect(
            x: x, y: y, w: region.w, h: region.h, color: Palette.accent,
            width: 1
        )
        let handle: Float = 6
        for (hx, hy) in [
            (x, y), (x + region.w, y),
            (x, y + region.h), (x + region.w, y + region.h),
        ] {
            list.rect(
                x: hx - handle / 2, y: hy - handle / 2, w: handle, h: handle,
                color: Palette.accent
            )
        }
        // The size, above the selection if there is room and inside it if not
        // — a readout that runs off the top of the screen is a readout nobody
        // can use to line anything up.
        let label = "\(Int(region.w.rounded())) × \(Int(region.h.rounded()))"
        let above = y - 22
        self.label(
            list, label, x: x + 2, y: above > origin.y ? above : y + 6,
            color: Palette.accent
        )
    }

    private func draw(_ stroke: ShotStroke, _ list: DrawList, origin: CanvasFrame) {
        let color = Color(
            r: stroke.color.r, g: stroke.color.g, b: stroke.color.b,
            a: stroke.color.a
        )
        let a = ShotPoint(
            x: origin.x + stroke.start.x, y: origin.y + stroke.start.y
        )
        let b = ShotPoint(x: origin.x + stroke.end.x, y: origin.y + stroke.end.y)

        switch stroke.tool {
        case .select:
            break
        case .rectangle:
            let r = ShotRect.between(a, b)
            list.strokedRect(
                x: r.x, y: r.y, w: r.w, h: r.h, color: color,
                width: stroke.width
            )
        case .ellipse:
            segments(list, ellipse(from: a, to: b), width: stroke.width, color: color)
        case .arrow:
            arrow(list, from: a, to: b, width: stroke.width, color: color)
        case .pen:
            segments(
                list,
                stroke.points.map { (x: origin.x + $0.x, y: origin.y + $0.y) },
                width: stroke.width, color: color
            )
        case .highlight:
            // A translucent wash rather than an outline, and always the same
            // alpha: a highlighter that can be made opaque is a rectangle tool
            // that hides what it was pointing at.
            let r = ShotRect.between(a, b)
            list.rect(
                x: r.x, y: r.y, w: r.w, h: r.h,
                color: Color(r: color.r, g: color.g, b: color.b, a: 0.32)
            )
        case .blur:
            let r = ShotRect.between(a, b)
            // Content blur, so what comes out is the desktop's own pixels
            // smeared past recognition rather than a rectangle drawn over
            // them — which survives being cropped out of the file and is what
            // "redacted" has to mean.
            list.beginContentBlur(x: r.x, y: r.y, w: r.w, h: r.h, radius: 18)
            list.endContentBlur()
        }
    }

    /// A run of thick segments, with a dot at every joint.
    ///
    /// `polyline` is deliberately one pixel wide — portable Vulkan does not
    /// promise wide lines — and a one-pixel annotation on a screenshot of a
    /// screen is invisible. `line` does carry a width, so a stroke is a chain
    /// of them, and the circles are the joins: without them a fast scribble
    /// has a notch at every direction change.
    private func segments(
        _ list: DrawList, _ points: [(x: Float, y: Float)], width: Float,
        color: Color
    ) {
        guard points.count >= 2 else {
            if let only = points.first {
                list.circle(cx: only.x, cy: only.y, radius: width / 2, color: color)
            }
            return
        }
        for i in 1..<points.count {
            list.line(
                x1: points[i - 1].x, y1: points[i - 1].y,
                x2: points[i].x, y2: points[i].y, color: color, width: width
            )
            if width > 2 {
                list.circle(
                    cx: points[i].x, cy: points[i].y, radius: width / 2,
                    color: color
                )
            }
        }
    }

    /// One glyph in the middle of a button.
    private func centred(
        _ list: DrawList, _ glyph: String, in frame: ShotRect,
        origin: CanvasFrame, color: Color
    ) {
        guard let font = Environment.current.font ?? FontStore.default else {
            return
        }
        let size = font.measure(glyph)
        list.text(
            glyph,
            // `text` insets the pen by 4 to match the old renderer, so the
            // centring has to take that back out.
            x: origin.x + frame.x + (frame.w - size.width) / 2 - 4,
            y: origin.y + frame.y + (frame.h - font.lineHeight) / 2,
            w: size.width + 8, h: font.lineHeight, color: color, font: font
        )
    }

    /// Text at a point, with the default face. The draw list wants a box; a
    /// label on a floating toolbar has no box, so it gets a generous one.
    private func label(
        _ list: DrawList, _ string: String, x: Float, y: Float, color: Color
    ) {
        guard let font = Environment.current.font ?? FontStore.default else {
            return
        }
        list.text(
            string, x: x, y: y,
            w: font.measure(string).width + 8, h: font.lineHeight,
            color: color, font: font
        )
    }

    /// A closed polyline around the box, which is what an ellipse is when the
    /// draw list has circles and rectangles and nothing between them.
    private func ellipse(from a: ShotPoint, to b: ShotPoint) -> [(x: Float, y: Float)] {
        let cx = (a.x + b.x) / 2
        let cy = (a.y + b.y) / 2
        let rx = abs(b.x - a.x) / 2
        let ry = abs(b.y - a.y) / 2
        // Enough segments that the biggest ellipse anybody draws on a screen
        // has no visible corners, few enough to cost nothing.
        let steps = 64
        var points: [(x: Float, y: Float)] = []
        points.reserveCapacity(steps + 1)
        for i in 0...steps {
            let t = Float(i) / Float(steps) * 2 * .pi
            points.append((x: cx + cos(t) * rx, y: cy + sin(t) * ry))
        }
        return points
    }

    private func arrow(
        _ list: DrawList, from a: ShotPoint, to b: ShotPoint, width: Float,
        color: Color
    ) {
        list.line(x1: a.x, y1: a.y, x2: b.x, y2: b.y, color: color, width: width)
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = max(0.001, (dx * dx + dy * dy).squareRoot())
        // The head grows with the line's weight, not with its length: an arrow
        // drawn thick and short still has to read as an arrow.
        let head = max(10, width * 3.5)
        let ux = dx / length
        let uy = dy / length
        let spread: Float = 0.45
        let left = (
            x: b.x - (ux * cos(spread) - uy * sin(spread)) * head,
            y: b.y - (uy * cos(spread) + ux * sin(spread)) * head
        )
        let right = (
            x: b.x - (ux * cos(spread) + uy * sin(spread)) * head,
            y: b.y - (uy * cos(spread) - ux * sin(spread)) * head
        )
        list.polygon([(x: b.x, y: b.y), left, right], color: color)
    }

    // MARK: - Toolbar

    private func toolbar(_ list: DrawList, screen: ShotRect, origin: CanvasFrame) {
        let (plate, buttons) = ShotToolbar.layout(in: screen)
        list.roundedRect(
            x: origin.x + plate.x, y: origin.y + plate.y,
            w: plate.w, h: plate.h, color: Palette.plate, radius: 10
        )
        for button in buttons {
            let bx = origin.x + button.frame.x
            let by = origin.y + button.frame.y
            let on = isActive(button.action)
            if on {
                list.roundedRect(
                    x: bx, y: by, w: button.frame.w, h: button.frame.h,
                    color: Palette.accent, radius: 7
                )
            }
            var color = on ? Palette.plate : Palette.glyph
            if case .color(let index) = button.action {
                let swatch = ShotColor.palette[index]
                color = Color(r: swatch.r, g: swatch.g, b: swatch.b, a: 1)
            }
            if !isEnabled(button.action) { color = Palette.disabled }
            // Measured rather than nudged by a constant: the buttons shrink on
            // a narrow screen, and a glyph centred by guesswork drifts out of
            // its own button as soon as they do.
            centred(list, button.glyph, in: button.frame, origin: origin, color: color)
        }

        // The stroke weight, as itself: a dot the size of the line that will
        // be drawn, which says more than a number would.
        if let thicker = buttons.first(where: { $0.action == .thicker }) {
            let dot = session.strokeWidth
            list.circle(
                cx: origin.x + thicker.frame.x + thicker.frame.w / 2,
                cy: origin.y + thicker.frame.maxY + 7,
                radius: max(1.5, dot / 2), color: Palette.glyph
            )
        }
    }

    private func isActive(_ action: ShotAction) -> Bool {
        switch action {
        case .tool(let tool): return tool == session.tool
        case .color(let index): return index == session.colorIndex
        default: return false
        }
    }

    private func isEnabled(_ action: ShotAction) -> Bool {
        switch action {
        case .undo: return session.document.canUndo
        case .redo: return session.document.canRedo
        case .copy, .save: return session.selection != nil
        default: return true
        }
    }

    private func hint(_ list: DrawList, frame: CanvasFrame, screen: ShotRect) {
        let text: String
        if let notice = session.notice {
            text = notice
        } else if session.selection == nil {
            text = "Drag to choose a region · Esc to cancel"
        } else {
            text = "Enter copies · Ctrl+S saves · Esc cancels"
        }
        let (plate, _) = ShotToolbar.layout(in: screen)
        label(
            list, text, x: frame.x + screen.w / 2 - Float(text.count) * 3.2,
            y: frame.y + plate.y - 26, color: Palette.hint
        )
    }

    // MARK: - Input

    private func handleGesture(_ gesture: CanvasGesture) {
        let point = ShotPoint(x: gesture.localX, y: gesture.localY)
        let screen = ShotRect(x: 0, y: 0, w: gesture.frame.w, h: gesture.frame.h)

        switch gesture.phase {
        case .began:
            let (_, buttons) = ShotToolbar.layout(in: screen)
            if let action = ShotToolbar.hit(buttons, x: point.x, y: point.y) {
                session.perform(action)
                return
            }
            session.beginDraw(at: point, screen: screen)
        case .moved:
            session.continueDraw(to: point, screen: screen)
        case .ended:
            session.endDraw()
        }
    }
}

/// The colours of the overlay itself, which are not the theme's.
///
/// A screenshot tool draws on top of an arbitrary picture of somebody's
/// screen, so its own furniture cannot borrow the desktop's palette and hope
/// to stay legible — it has to be dark enough to read against a white page and
/// light enough to read against a terminal.
enum Palette {
    static let behind = Color(r: 0.05, g: 0.05, b: 0.06)
    static let dim = Color(r: 0.03, g: 0.03, b: 0.05, a: 0.55)
    static let plate = Color(r: 0.10, g: 0.11, b: 0.13, a: 0.96)
    static let glyph = Color(r: 0.90, g: 0.91, b: 0.94)
    static let disabled = Color(r: 0.42, g: 0.44, b: 0.48)
    static let accent = Color(r: 0.35, g: 0.62, b: 0.98)
    static let hint = Color(r: 0.72, g: 0.74, b: 0.78)
}
