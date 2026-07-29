#if canImport(CxxCanvas)
import CxxCanvas
import CYoga
import Foundation

// Phase 3 — immediate draw list. C++ owns `canvas::DrawCommand` layout.

public enum DrawKind: UInt32 {
    case rect = 0
    case roundedRect = 1
    case text = 2
    case circle = 3
    case line = 4
    case pushClip = 5
    case popClip = 6
    case image = 7
}

/// Reused arena: draw commands plus the shaped glyphs they reference.
/// Shaping itself is cached per line on `UIFont`, so re-emission is cheap.
public final class DrawList {
    public private(set) var commands: [canvas.DrawCommand] = []

    /// Shaped glyphs in absolute window pixels; `Text` commands index this.
    /// Replaces the old string blob — the renderer no longer shapes anything,
    /// so strings never cross the boundary.
    public private(set) var glyphs: [canvas.GlyphInstance] = []

    public init() {
        commands.reserveCapacity(256)
        glyphs.reserveCapacity(2048)
    }

    public func clear() {
        commands.removeAll(keepingCapacity: true)
        glyphs.removeAll(keepingCapacity: true)
    }

    private func append(
        kind: DrawKind,
        x: Float, y: Float, w: Float, h: Float,
        color: Color,
        param: UInt32 = 0,
        aux: Float = 0
    ) {
        var cmd = canvas.DrawCommand()
        cmd.kind = kind.rawValue
        cmd.x = x
        cmd.y = y
        cmd.w = w
        cmd.h = h
        cmd.color = color.rgba8
        cmd.param = param
        cmd.aux = aux
        commands.append(cmd)
    }

    public func rect(x: Float, y: Float, w: Float, h: Float, color: Color) {
        append(kind: .rect, x: x, y: y, w: w, h: h, color: color)
    }

    public func roundedRect(
        x: Float, y: Float, w: Float, h: Float, color: Color, radius: Float = 4
    ) {
        append(kind: .roundedRect, x: x, y: y, w: w, h: h, color: color, aux: radius)
    }

    /// Shapes `string` (cached on the font) and appends its glyphs at
    /// absolute positions. `y` is the line box top; the pen sits at the
    /// baseline, i.e. `y + ascent`.
    public func text(
        _ string: String, x: Float, y: Float, w: Float, h: Float,
        color: Color, font: UIFont? = nil
    ) {
        guard let font = font ?? FontStore.default, !string.isEmpty else { return }
        let run = font.shape(string)
        guard !run.isEmpty else { return }

        let first = UInt32(glyphs.count)
        let penX = x + 4  // matches the inset the old renderText path used
        let penY = y + font.ascent
        for g in run {
            var inst = canvas.GlyphInstance()
            inst.glyphId = g.glyphId
            inst.fontId = font.engineId
            inst.x = penX + g.x
            inst.y = penY + g.y
            glyphs.append(inst)
        }
        // `w` carries the glyph count for Text (see draw_command.hpp).
        append(
            kind: .text, x: x, y: y, w: Float(run.count), h: h,
            color: color, param: first
        )
    }

    public func circle(cx: Float, cy: Float, radius: Float, color: Color) {
        append(kind: .circle, x: cx, y: cy, w: 0, h: 0, color: color, aux: radius)
    }

    public func line(x1: Float, y1: Float, x2: Float, y2: Float, color: Color) {
        append(kind: .line, x: x1, y: y1, w: x2, h: y2, color: color)
    }

    public func pushClip(x: Float, y: Float, w: Float, h: Float) {
        append(kind: .pushClip, x: x, y: y, w: w, h: h, color: .primary)
    }

    public func popClip() {
        append(kind: .popClip, x: 0, y: 0, w: 0, h: 0, color: .primary)
    }

    /// Textured quad. `param` = engine texture id; `color` = RGBA tint.
    public func image(
        textureId: UInt32,
        x: Float, y: Float, w: Float, h: Float,
        tint: Color = Color(r: 1, g: 1, b: 1)
    ) {
        guard w > 0, h > 0, textureId > 0 else { return }
        append(
            kind: .image, x: x, y: y, w: w, h: h,
            color: tint, param: textureId
        )
    }

    // MARK: - Tree emission (pre-order DFS = paint order)

    /// Emit chrome from a laid-out retained tree.
    /// `originX/Y` shift the tree (e.g. below ImGui menu). Viewport for leaf culling.
    public func emitTree(
        _ root: any AnyViewNode,
        originX: Float = 0,
        originY: Float = 0,
        viewportW: Float,
        viewportH: Float
    ) {
        emitNode(root, ox: originX, oy: originY, vpW: viewportW, vpH: viewportH)
    }

    private func emitNode(
        _ node: any AnyViewNode,
        ox: Float, oy: Float,
        vpW: Float, vpH: Float
    ) {
        if let box = node as? YogaBoxNode, let yref = box.yoga {
            let x = ox + YGNodeLayoutGetLeft(yref)
            let y = oy + YGNodeLayoutGetTop(yref)
            let w = YGNodeLayoutGetWidth(yref)
            let h = YGNodeLayoutGetHeight(yref)

            if let stack = node as? StackNode {
                // Never cull containers — Yoga does not clip children by default,
                // so an overflowing child of an offscreen parent can still be visible.
                if let fill = stack.fillColor {
                    rect(x: x, y: y, w: w, h: h, color: fill)
                }
                for c in stack.childNodes {
                    emitNode(c, ox: x, oy: y, vpW: vpW, vpH: vpH)
                }
                return
            }

            if let leaf = node as? LeafNode {
                // Cull leaves only.
                if x + w < 0 || y + h < 0 || x > vpW || y > vpH {
                    return
                }
                // Hover wins over the base fill; both honour the radius.
                let leafFill = HoverState.isHovered(leaf.id)
                    ? (leaf.hoverFill ?? leaf.fillColor)
                    : leaf.fillColor
                if let fill = leafFill {
                    if leaf.cornerRadius > 0 {
                        roundedRect(
                            x: x, y: y, w: w, h: h,
                            color: fill, radius: leaf.cornerRadius
                        )
                    } else {
                        rect(x: x, y: y, w: w, h: h, color: fill)
                    }
                }
                if leaf.kind == .text, !leaf.text.isEmpty {
                    // Multi-line: emit one command per wrapped line (same breaks
                    // as Yoga measure via TextLayoutCache / Font::wrapLines).
                    let lineH = (leaf.font ?? FontStore.default)?.lineHeight ?? 18
                    let lines = leaf.cachedLines.isEmpty ? [leaf.text] : leaf.cachedLines
                    for (i, line) in lines.enumerated() {
                        let ly = y + Float(i) * lineH
                        text(
                            line, x: x, y: ly, w: w, h: lineH,
                            color: leaf.color, font: leaf.font
                        )
                    }
                }
                if leaf.kind == .textField {
                    emitTextField(leaf, x: x, y: y, w: w, h: h)
                }
                if leaf.kind == .editor {
                    emitEditor(leaf, x: x, y: y, w: w, h: h)
                }
                if leaf.kind == .image, let img = leaf.image {
                    let dest = imageDestRect(
                        boxX: x, boxY: y, boxW: w, boxH: h,
                        srcW: img.pixelWidth, srcH: img.pixelHeight,
                        mode: leaf.imageContentMode
                    )
                    self.image(
                        textureId: img.textureId,
                        x: dest.x, y: dest.y, w: dest.w, h: dest.h,
                        tint: leaf.imageTint
                    )
                }
                return
            }

            for c in node.childNodes {
                emitNode(c, ox: x, oy: y, vpW: vpW, vpH: vpH)
            }
            return
        }

        for c in node.childNodes {
            emitNode(c, ox: ox, oy: oy, vpW: vpW, vpH: vpH)
        }
    }

    /// Layout box → dest rect for the bitmap under `contentMode`.
    private func imageDestRect(
        boxX: Float, boxY: Float, boxW: Float, boxH: Float,
        srcW: Float, srcH: Float,
        mode: ImageContentMode
    ) -> (x: Float, y: Float, w: Float, h: Float) {
        guard srcW > 0, srcH > 0, boxW > 0, boxH > 0 else {
            return (boxX, boxY, boxW, boxH)
        }
        switch mode {
        case .stretch:
            return (boxX, boxY, boxW, boxH)
        case .fit:
            let sx = boxW / srcW
            let sy = boxH / srcH
            let s = min(sx, sy)
            let dw = srcW * s
            let dh = srcH * s
            return (boxX + (boxW - dw) * 0.5, boxY + (boxH - dh) * 0.5, dw, dh)
        case .fill:
            let sx = boxW / srcW
            let sy = boxH / srcH
            let s = max(sx, sy)
            let dw = srcW * s
            let dh = srcH * s
            return (boxX + (boxW - dw) * 0.5, boxY + (boxH - dh) * 0.5, dw, dh)
        }
    }
}

extension DrawList {
    /// Draws a field as: selection rects, then glyphs, then caret.
    ///
    /// That order is the whole point of the unified pipeline — under the old
    /// three-renderer split the caret was geometry and text always drew last,
    /// so a caret could never appear over its own glyphs.
    fileprivate func emitTextField(
        _ leaf: LeafNode, x: Float, y: Float, w: Float, h: Float
    ) {
        guard let font = leaf.font ?? FontStore.default else { return }
        let inset = LeafNode.textInset
        let lineH = font.lineHeight
        let focused = FocusManager.isFocused(leaf.id)
        let state = leaf.editing

        if focused {
            rect(x: x, y: y, w: w, h: Theme.current.borderWidth, color: .accent)
            rect(
                x: x, y: y + h - Theme.current.borderWidth,
                w: w, h: Theme.current.borderWidth, color: .accent
            )
        }

        if state.text.isEmpty {
            if !leaf.placeholder.isEmpty {
                let top = leaf.isMultiline ? y + inset : y + max(0, (h - lineH) / 2)
                text(
                    leaf.placeholder, x: x + inset - 4, y: top,
                    w: w, h: lineH, color: .muted, font: font
                )
            }
            if focused, CaretBlink.isVisible {
                let top = leaf.isMultiline ? y + inset : y + max(0, (h - lineH) / 2)
                rect(
                    x: x + inset, y: top,
                    w: Theme.current.caretWidth, h: lineH, color: .primary
                )
            }
            return
        }

        // Single-line stays vertically centred in its box; multi-line starts
        // at the top inset and stacks.
        let firstTop = leaf.isMultiline ? y + inset : y + max(0, (h - lineH) / 2)
        let rows = state.layout.rows
        let selection = state.hasSelection ? state.selectedRange : nil
        let caretRow = state.layout.rowIndex(
            ofOffset: state.offset(of: state.focus), affinity: state.affinity
        )

        for (row, rowRange) in rows.enumerated() {
            let lineTop = firstTop + Float(row) * lineH
            // Same rule as the editor: draw only rows that fully fit, so a
            // shrunk box cannot spill text onto its neighbours.
            if lineTop + lineH > y + h { break }

            let lineStart = state.index(atOffset: rowRange.lowerBound)
            let lineEnd = state.index(atOffset: rowRange.upperBound)
            let lineText = String(state.text[lineStart..<lineEnd])
            let run = font.shapedRun(lineText)

            // Selection is a range over the whole buffer; clip it to this line
            // so each row draws only its own share.
            if let sel = selection, sel.lowerBound < lineEnd, sel.upperBound > lineStart {
                let from = max(sel.lowerBound, lineStart)
                let to = min(sel.upperBound, lineEnd)
                let x0 = run.caretX(for: localIndex(in: lineText, matching: from, lineStart: lineStart, state: state))
                let x1 = run.caretX(for: localIndex(in: lineText, matching: to, lineStart: lineStart, state: state))
                // A selection crossing a newline should show the break, so an
                // empty tail still paints a sliver.
                let spansNewline = sel.upperBound > lineEnd
                rect(
                    x: x + inset + x0, y: lineTop,
                    w: max(spansNewline ? 4 : 1, x1 - x0), h: lineH,
                    color: Theme.current.selectionFill
                )
            }

            if !lineText.isEmpty {
                text(
                    lineText, x: x + inset - 4, y: lineTop,
                    w: w, h: lineH, color: leaf.color, font: font
                )
            }

            if focused, !state.hasSelection, CaretBlink.isVisible, row == caretRow {
                let local = localIndex(
                    in: lineText, matching: state.focus, lineStart: lineStart, state: state
                )
                rect(
                    x: x + inset + run.caretX(for: local), y: lineTop,
                    w: Theme.current.caretWidth, h: lineH, color: .primary
                )
            }
        }
    }

    /// Buffer index → index into a single line's own string, which is what
    /// `ShapedRun` (shaped per line) expects.
    fileprivate func localIndex(
        in lineText: String, matching index: String.Index,
        lineStart: String.Index, state: TextEditingState
    ) -> String.Index {
        let column = state.text.distance(from: lineStart, to: index)
        let clamped = max(0, min(column, lineText.count))
        return lineText.index(lineText.startIndex, offsetBy: clamped)
    }
}

extension DrawList {
    /// Draw order per row: current-line wash, search matches, selection,
    /// syntax-coloured text, caret. Backgrounds before glyphs, caret after —
    /// the ordering the unified pipeline made expressible.
    fileprivate func emitEditor(
        _ leaf: LeafNode, x: Float, y: Float, w: Float, h: Float
    ) {
        guard let font = leaf.font ?? FontStore.default else { return }
        let style = leaf.codeStyle ?? CodeStyle()
        let inset = LeafNode.textInset
        let lineH = font.lineHeight
        let focused = FocusManager.isFocused(leaf.id)
        let state = leaf.editing
        let rows = state.layout.rows

        // Yoga may have shrunk the box below the measured height; the clamp
        // and the row window must use what was granted, not what was asked.
        leaf.viewportHeight = h
        leaf.textViewportWidth = max(0, w - leaf.gutterWidth - inset * 2)

        let textX = x + leaf.gutterWidth + inset - leaf.scrollX
        let top = y + inset - leaf.scrollY

        let caretRow = state.layout.rowIndex(
            ofOffset: state.offset(of: state.focus), affinity: state.affinity
        )
        let selection = state.hasSelection ? state.selectedRange : nil

        // Only rows intersecting the viewport are emitted: a long buffer costs
        // a screenful of quads, not a file's worth.
        let firstRow = max(0, Int(leaf.scrollY / lineH))
        let lastRow = min(rows.count - 1, Int((leaf.scrollY + h) / lineH) + 1)
        guard firstRow <= lastRow else { return }

        // Pass 1 — chrome that must not scroll horizontally. The gutter stays
        // pinned while text moves under it, which is the whole reason this is
        // two clip regions instead of one.
        pushClip(x: x, y: y, w: w, h: h)
        if leaf.showsGutter, leaf.gutterWidth > 0 {
            rect(x: x, y: y, w: leaf.gutterWidth, h: h, color: style.gutterBackground)
        }
        for row in firstRow...lastRow {
            let rowTop = top + Float(row) * lineH
            if focused, row == caretRow, selection == nil {
                rect(
                    x: x + leaf.gutterWidth, y: rowTop,
                    w: w - leaf.gutterWidth, h: lineH, color: style.currentLine
                )
            }
            if leaf.showsGutter, leaf.gutterWidth > 0 {
                // Right-aligned so numbers stay in a column as they widen.
                let label = String(row + 1)
                let labelW = font.shapedRun(label).width
                text(
                    label, x: x + leaf.gutterWidth - inset - labelW - 4, y: rowTop,
                    w: leaf.gutterWidth, h: lineH,
                    color: style.gutterText, font: font
                )
            }
        }
        popClip()

        // Pass 2 — everything that scrolls, clipped to the text area so a
        // horizontally scrolled line cannot draw over the gutter.
        pushClip(
            x: x + leaf.gutterWidth, y: y,
            w: max(0, w - leaf.gutterWidth), h: h
        )
        defer { popClip() }

        for row in firstRow...lastRow {
            let range = rows[row]
            let rowTop = top + Float(row) * lineH

            let lo = state.index(atOffset: range.lowerBound)
            let hi = state.index(atOffset: range.upperBound)
            let lineText = String(state.text[lo..<hi])
            let run = font.shapedRun(lineText)

            func columnX(_ column: Int) -> Float {
                let clamped = max(0, min(column, lineText.count))
                return run.caretX(for: lineText.index(lineText.startIndex, offsetBy: clamped))
            }

            for (i, match) in leaf.search.matches.enumerated() {
                guard match.lowerBound < range.upperBound,
                      match.upperBound > range.lowerBound else { continue }
                let a = columnX(match.lowerBound - range.lowerBound)
                let b = columnX(match.upperBound - range.lowerBound)
                let isCurrent = leaf.search.currentIndex == i
                rect(
                    x: textX + a, y: rowTop, w: max(2, b - a), h: lineH,
                    color: isCurrent ? style.currentSearchMatch : style.searchMatch
                )
            }

            if let sel = selection, sel.lowerBound < hi, sel.upperBound > lo {
                let from = max(state.offset(of: sel.lowerBound), range.lowerBound)
                let to = min(state.offset(of: sel.upperBound), range.upperBound)
                let a = columnX(from - range.lowerBound)
                let b = columnX(to - range.lowerBound)
                let spansNewline = state.offset(of: sel.upperBound) > range.upperBound
                rect(
                    x: textX + a, y: rowTop,
                    w: max(spansNewline ? 4 : 1, b - a), h: lineH,
                    color: Theme.current.selectionFill
                )
            }

            emitCodeLine(
                lineText, spans: leaf.highlighter?.spans(in: lineText) ?? [],
                style: style, run: run, font: font, x: textX, y: rowTop, h: lineH
            )

            if focused, !state.hasSelection, CaretBlink.isVisible, row == caretRow {
                let column = state.offset(of: state.focus) - range.lowerBound
                rect(
                    x: textX + columnX(column), y: rowTop,
                    w: Theme.current.caretWidth, h: lineH, color: .primary
                )
            }
        }
    }

    /// Emits one line as coloured segments.
    ///
    /// Each segment is shaped on its own, so shaping does not carry across a
    /// span boundary — a ligature spanning a keyword edge would break. That is
    /// the same trade every token-colouring editor makes, and it only shows on
    /// text where a ligature straddles two token types.
    private func emitCodeLine(
        _ line: String, spans: [HighlightSpan], style: CodeStyle,
        run: ShapedRun, font: UIFont, x: Float, y: Float, h: Float
    ) {
        guard !line.isEmpty else { return }
        guard !spans.isEmpty else {
            text(line, x: x - 4, y: y, w: 10_000, h: h, color: style.text, font: font)
            return
        }

        func slice(_ r: Range<Int>) -> String {
            let a = line.index(line.startIndex, offsetBy: max(0, min(r.lowerBound, line.count)))
            let b = line.index(line.startIndex, offsetBy: max(0, min(r.upperBound, line.count)))
            return String(line[a..<b])
        }
        func xFor(_ column: Int) -> Float {
            let c = max(0, min(column, line.count))
            return run.caretX(for: line.index(line.startIndex, offsetBy: c))
        }

        var cursor = 0
        for span in spans.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if span.range.lowerBound > cursor {
                let plain = slice(cursor..<span.range.lowerBound)
                text(
                    plain, x: x + xFor(cursor) - 4, y: y, w: 10_000, h: h,
                    color: style.text, font: font
                )
            }
            text(
                slice(span.range), x: x + xFor(span.range.lowerBound) - 4, y: y,
                w: 10_000, h: h, color: style.color(for: span.styleIndex), font: font
            )
            cursor = max(cursor, span.range.upperBound)
        }
        if cursor < line.count {
            text(
                slice(cursor..<line.count), x: x + xFor(cursor) - 4, y: y,
                w: 10_000, h: h, color: style.text, font: font
            )
        }
    }
}

#endif
