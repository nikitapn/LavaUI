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
            // Cheap vertical cull: a tall buffer in a short box.
            if lineTop + lineH < y || lineTop > y + h { continue }

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

#endif
