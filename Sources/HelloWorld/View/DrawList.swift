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
                if let fill = leaf.fillColor {
                    rect(x: x, y: y, w: w, h: h, color: fill)
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
}

#endif
