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
    /// Flush UI so far, blur the resolve under x,y,w,h (`aux` = radius px).
    case beginBackdropBlur = 8
    /// Closes a blur scope (bookkeeping; engine no-ops today).
    case endBackdropBlur = 9
    /// Draw everything up to the matching End into an offscreen target instead
    /// of the frame, blur it, and composite it back over x,y,w,h with its own
    /// alpha (`aux` = radius px).
    case beginContentBlur = 10
    case endContentBlur = 11
}

/// Reused arena: draw commands plus the shaped glyphs they reference.
/// Shaping itself is cached per line on `UIFont`, so re-emission is cheap.
public final class DrawList {
    public private(set) var commands: [canvas.DrawCommand] = []

    /// Shaped glyphs in absolute window pixels; `Text` commands index this.
    /// Replaces the old string blob — the renderer no longer shapes anything,
    /// so strings never cross the boundary.
    public private(set) var glyphs: [canvas.GlyphInstance] = []

    /// Overlays found during the current walk, emitted once it finishes.
    private var pendingOverlays: [PendingOverlay] = []

    /// Fade applied to everything appended, for transitions. A multiplier
    /// rather than a value so nested transitions compose.
    private var alphaMultiplier: Float = 1

    /// True inside any blur scope, of either kind. See `withBlurScope`.
    private var insideBlurScope = false

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
        // The single choke point every primitive goes through, which is why
        // the fade lives here rather than in each of them.
        if alphaMultiplier < 1 {
            var faded = color
            faded.a *= alphaMultiplier
            cmd.color = faded.rgba8
        } else {
            cmd.color = color.rgba8
        }
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

    /// Barrier: engine flushes UI drawn so far, blurs under this rect, composites.
    /// `color` is unused by the engine (tint the glass with a following fill).
    public func beginBackdropBlur(
        x: Float, y: Float, w: Float, h: Float, radius: Float
    ) {
        guard w > 0, h > 0, radius > 0 else { return }
        append(
            kind: .beginBackdropBlur, x: x, y: y, w: w, h: h,
            color: Color(r: 1, g: 1, b: 1), aux: radius
        )
    }

    public func endBackdropBlur() {
        append(
            kind: .endBackdropBlur, x: 0, y: 0, w: 0, h: 0,
            color: Color(r: 1, g: 1, b: 1)
        )
    }

    /// Barrier: engine draws everything until `endContentBlur` into an offscreen
    /// target, blurs it, and composites it back over this rect.
    public func beginContentBlur(
        x: Float, y: Float, w: Float, h: Float, radius: Float
    ) {
        guard w > 0, h > 0, radius > 0 else { return }
        append(
            kind: .beginContentBlur, x: x, y: y, w: w, h: h,
            color: Color(r: 1, g: 1, b: 1), aux: radius
        )
    }

    public func endContentBlur() {
        append(
            kind: .endContentBlur, x: 0, y: 0, w: 0, h: 0,
            color: Color(r: 1, g: 1, b: 1)
        )
    }

    /// Run `body` inside optional blur bookends, of whichever kind the node asked
    /// for.
    ///
    /// Scopes do not nest, in either kind or across them. Each one costs a
    /// render-target switch and reads back what the previous one composited, so
    /// an inner scope would blur the outer one's output a second time. The
    /// outermost wins — which is also what lets an overlay hoist its content's
    /// backdrop scope up over the panel's own chrome.
    ///
    /// Content wins over backdrop on the same node: `.blur()` is a statement
    /// about this view, and a frosted backdrop under a view that is itself
    /// being softened is not something you can see.
    private func withBlurScope(
        content contentRadius: Float?,
        backdrop backdropRadius: Float?,
        x: Float, y: Float, w: Float, h: Float,
        body: () -> Void
    ) {
        guard w > 0, h > 0, !insideBlurScope else { return body() }

        if let radius = contentRadius, radius > 0 {
            insideBlurScope = true
            beginContentBlur(x: x, y: y, w: w, h: h, radius: radius)
            body()
            endContentBlur()
            insideBlurScope = false
        } else if let radius = backdropRadius, radius > 0 {
            insideBlurScope = true
            beginBackdropBlur(x: x, y: y, w: w, h: h, radius: radius)
            body()
            endBackdropBlur()
            insideBlurScope = false
        } else {
            body()
        }
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
        pendingOverlays.removeAll(keepingCapacity: true)
        emitNode(root, ox: originX, oy: originY, vpW: viewportW, vpH: viewportH)

        // After the main walk, so overlays paint above everything and — because
        // the clip stack is balanced by now — are not scissored by whatever
        // ancestor the presenter happened to sit inside.
        for pending in pendingOverlays {
            let att = pending.attachment
            att.layoutAndPlace(
                anchorX: pending.x, anchorY: pending.y,
                anchorW: pending.w, anchorH: pending.h,
                viewportW: viewportW, viewportH: viewportH
            )
            guard let overlayRoot = att.root else { continue }

            // A glass overlay must frost what is *behind* the panel, not the
            // panel's own chrome, so the capture has to happen before any of it.
            // Hoisting the scope up here does that; `withBlurScope` then
            // no-ops the scope the content node would have opened.
            //
            // One level down is where a collapsed `.blur()` lands, because the
            // shell wraps exactly one mounted content node. Behind a fragment
            // (a tuple, an `if`) it stays where it was.
            let glassRadius =
                (overlayRoot.childNodes.first as? YogaBoxNode)?.backdropBlurRadius
            withBlurScope(
                content: nil, backdrop: glassRadius,
                x: att.origin.x, y: att.origin.y, w: att.size.w, h: att.size.h
            ) {
                // Outline first, one pixel proud on every side, so the panel's
                // own fill covers the middle of it — which is exactly why a
                // glass panel gets none. A plate is not a stroke: under a
                // translucent fill its middle shows through as a flat wash, and
                // it would be the only thing the blur had to capture. Until the
                // SDF pipeline can stroke a rounded rect, a frosted panel's
                // edge comes from its own fill and corner radius.
                if let border = att.border, glassRadius == nil {
                    roundedRect(
                        x: att.origin.x - 1, y: att.origin.y - 1,
                        w: att.size.w + 2, h: att.size.h + 2,
                        color: border, radius: att.cornerRadius + 1
                    )
                }
                emitNode(
                    overlayRoot,
                    ox: att.origin.x, oy: att.origin.y,
                    vpW: viewportW, vpH: viewportH
                )
            }
        }
        pendingOverlays.removeAll(keepingCapacity: true)
    }

    private struct PendingOverlay {
        let attachment: OverlayAttachment
        let x: Float
        let y: Float
        let w: Float
        let h: Float
    }

    private func emitNode(
        _ node: any AnyViewNode,
        ox: Float, oy: Float,
        vpW: Float, vpH: Float
    ) {
        // A transitioning subtree is drawn faded and displaced. Wrapping the
        // whole walk means every primitive underneath inherits it without
        // knowing anything about transitions, and nesting multiplies.
        if let box = node as? YogaBoxNode,
           let transition = box.transitionState,
           transition.isTransitioning
        {
            let saved = alphaMultiplier
            alphaMultiplier *= transition.alpha
            let shift = transition.translation
            emitNodeBody(node, ox: ox + shift.x, oy: oy + shift.y, vpW: vpW, vpH: vpH)
            alphaMultiplier = saved
            return
        }
        emitNodeBody(node, ox: ox, oy: oy, vpW: vpW, vpH: vpH)
    }

    private func emitNodeBody(
        _ node: any AnyViewNode,
        ox: Float, oy: Float,
        vpW: Float, vpH: Float
    ) {
        if let box = node as? YogaBoxNode, let yref = box.yoga {
            let x = ox + YGNodeLayoutGetLeft(yref)
            let y = oy + YGNodeLayoutGetTop(yref)
            let w = YGNodeLayoutGetWidth(yref)
            let h = YGNodeLayoutGetHeight(yref)

            // Recorded here rather than emitted here: this is the one place
            // that knows the presenter's absolute rect, but drawing at this
            // point would put the popup underneath every later sibling.
            if let presenter = node as? OverlayBoxNode, presenter.attachment.presented {
                pendingOverlays.append(
                    PendingOverlay(attachment: presenter.attachment, x: x, y: y, w: w, h: h)
                )
            }

            if let scroll = node as? ScrollNode {
                // Record what Yoga granted; clamping against the requested size
                // would let content scroll out of reach.
                scroll.viewportLength = scroll.axis == .vertical ? h : w
                scroll.contentLength = scroll.measureContentLength()
                // Re-clamp in case content shrank since the last wheel event.
                scroll.scrollBy(0)

                pushClip(x: x, y: y, w: w, h: h)
                let shift = scroll.childOffset
                for c in scroll.childNodes {
                    emitNode(c, ox: x - shift.x, oy: y - shift.y, vpW: vpW, vpH: vpH)
                }
                popClip()

                if scroll.showsIndicator, scroll.maxOffset > 0 {
                    emitScrollIndicator(scroll, x: x, y: y, w: w, h: h)
                }
                return
            }

            if let styled = node as? StyleBoxNode {
                // Same rule as a stack: never cull a container, since Yoga does
                // not clip and an overflowing child may still be on screen.
                withBlurScope(
                    content: styled.contentBlurRadius,
                    backdrop: styled.backdropBlurRadius,
                    x: x, y: y, w: w, h: h
                ) {
                    if let fill = styled.fillColor {
                        if styled.cornerRadius > 0 {
                            roundedRect(
                                x: x, y: y, w: w, h: h,
                                color: fill, radius: styled.cornerRadius
                            )
                        } else {
                            rect(x: x, y: y, w: w, h: h, color: fill)
                        }
                    }
                    for c in styled.childNodes {
                        emitNode(c, ox: x, oy: y, vpW: vpW, vpH: vpH)
                    }
                }
                return
            }

            if let stack = node as? StackNode {
                // Never cull containers — Yoga does not clip children by default,
                // so an overflowing child of an offscreen parent can still be visible.
                withBlurScope(
                    content: stack.contentBlurRadius,
                    backdrop: stack.backdropBlurRadius,
                    x: x, y: y, w: w, h: h
                ) {
                    if let fill = stack.fillColor {
                        rect(x: x, y: y, w: w, h: h, color: fill)
                    }
                    for c in stack.childNodes {
                        emitNode(c, ox: x, oy: y, vpW: vpW, vpH: vpH)
                    }
                }
                return
            }

            if let leaf = node as? LeafNode {
                // Cull leaves only.
                if x + w < 0 || y + h < 0 || x > vpW || y > vpH {
                    return
                }
                withBlurScope(
                    content: leaf.contentBlurRadius,
                    backdrop: leaf.backdropBlurRadius,
                    x: x, y: y, w: w, h: h
                ) {
                    emitLeafContents(leaf, x: x, y: y, w: w, h: h)
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

    /// Paint for a leaf inside an optional backdrop-blur scope.
    private func emitLeafContents(
        _ leaf: LeafNode, x: Float, y: Float, w: Float, h: Float
    ) {
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
        if leaf.kind == .button {
            // The animated fill, not the static one — this is the only
            // thing a press changes, and it changes without any body
            // recompute behind it.
            let fill = leaf.buttonFill?.current
                ?? leaf.buttonStyle?.background ?? Theme.current.panel
            roundedRect(
                x: x, y: y, w: w, h: h,
                color: fill, radius: leaf.cornerRadius
            )
            if !leaf.text.isEmpty, let f = leaf.font ?? FontStore.default {
                let lineH = f.lineHeight
                let labelW = f.shapedRun(leaf.text).width
                text(
                    leaf.text,
                    x: x + (w - labelW) / 2 - 4,
                    y: y + max(0, (h - lineH) / 2),
                    w: w, h: lineH, color: leaf.color, font: f
                )
            }
            return
        }

        if leaf.kind == .toggle {
            emitToggle(leaf, x: x, y: y, w: w, h: h)
            return
        }

        if leaf.kind == .slider {
            emitSlider(leaf, x: x, y: y, w: w, h: h)
            return
        }

        if leaf.kind == .canvas {
            // App owns every command for this box (background, glyphs, bars…).
            leaf.canvasPaint?(self, CanvasFrame(x: x, y: y, w: w, h: h))
            return
        }

        if leaf.kind == .divider, let style = leaf.dividerStyle {
            let t = max(1, style.thickness)
            // Rounded to a whole pixel: a 1px rule landing on a half
            // pixel is smeared across two rows by the SDF and reads as
            // a smudge rather than a line.
            if leaf.isVerticalDivider {
                rect(
                    x: (x + (w - t) / 2).rounded(), y: y,
                    w: t, h: h, color: style.color
                )
            } else {
                rect(
                    x: x, y: (y + (h - t) / 2).rounded(),
                    w: w, h: t, color: style.color
                )
            }
            return
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
    /// Draws a toggle as: capsule track, knob, then label.
    ///
    /// The knob position comes from the animation, never from `isOn` directly —
    /// reading the boolean would snap it, which is the whole thing the
    /// animation exists to avoid. `isOn` is only the fallback for a node that
    /// somehow has no animation yet.
    fileprivate func emitToggle(
        _ leaf: LeafNode, x: Float, y: Float, w: Float, h: Float
    ) {
        guard let style = leaf.toggleStyle else { return }
        let trackH = style.trackHeight
        // The +4 mirrors the horizontal half of the padding `measureForYoga`
        // added, so the track sits where the box was sized for it.
        let trackX = x + 4
        let trackY = y + (h - trackH) / 2
        let track = leaf.toggleTrack?.current
            ?? style.track(on: leaf.isOn, hovered: false, enabled: leaf.isEnabled)
        roundedRect(
            x: trackX, y: trackY, w: style.trackWidth, h: trackH,
            color: track, radius: trackH / 2
        )

        let t = leaf.toggleKnob?.current ?? (leaf.isOn ? 1 : 0)
        let radius = trackH / 2 - style.knobInset
        // Travel is measured centre-to-centre, so the knob stays inset at both
        // ends regardless of how wide the track is.
        let travel = style.trackWidth - trackH
        circle(
            cx: trackX + trackH / 2 + travel * t,
            cy: trackY + trackH / 2,
            radius: radius,
            color: leaf.toggleKnobColor?.current
                ?? style.knobColor(over: track, enabled: leaf.isEnabled)
        )

        if !leaf.text.isEmpty, let font = leaf.font ?? FontStore.default {
            let lineH = font.lineHeight
            text(
                leaf.text,
                // -4 cancels the pen inset `text(_:)` applies.
                x: trackX + style.trackWidth + style.labelGap - 4,
                y: y + max(0, (h - lineH) / 2),
                w: w, h: lineH, color: leaf.color, font: font
            )
        }
    }

    /// Draws a slider as: inactive track, active track, knob, then readout.
    ///
    /// This is also where the drag geometry is recorded. Deriving it here
    /// rather than in the drag handler is what keeps the knob under the
    /// pointer: the numbers that convert a click back to a value are, by
    /// construction, the same ones that drew the track.
    fileprivate func emitSlider(
        _ leaf: LeafNode, x: Float, y: Float, w: Float, h: Float
    ) {
        guard let style = leaf.sliderStyle else { return }
        let readoutW = leaf.text.isEmpty ? 0 : style.valueGap + style.valueWidth
        let knobR = style.knobRadius
        // The +4/-8 mirror the padding `measureForYoga` added.
        let trackX = x + 4
        let trackW = max(0, w - 8 - readoutW)
        let cy = y + h / 2

        // The knob's centre never reaches the track ends, so travel is shorter
        // than the track by one diameter.
        leaf.sliderInset = 4 + knobR
        leaf.sliderTravel = max(0, trackW - knobR * 2)

        let enabled = leaf.isEnabled
        let thickness = style.trackThickness
        roundedRect(
            x: trackX, y: cy - thickness / 2, w: trackW, h: thickness,
            color: enabled ? style.inactiveTrack : style.disabledTrack,
            radius: thickness / 2
        )

        let cx = trackX + knobR + leaf.sliderTravel * leaf.sliderFraction
        let filled = cx - trackX
        if filled > 0, enabled {
            roundedRect(
                x: trackX, y: cy - thickness / 2, w: filled, h: thickness,
                color: style.activeTrack, radius: thickness / 2
            )
        }

        circle(
            cx: cx, cy: cy,
            radius: knobR * (leaf.sliderKnobScale?.current ?? 1),
            color: enabled ? style.knob : style.disabledKnob
        )

        if !leaf.text.isEmpty, let font = leaf.font ?? FontStore.default {
            text(
                leaf.text,
                // -4 cancels the pen inset `text(_:)` applies.
                x: trackX + trackW + style.valueGap - 4,
                y: cy - font.lineHeight / 2,
                w: style.valueWidth, h: font.lineHeight,
                color: leaf.color, font: font
            )
        }
    }

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

extension DrawList {
    /// A thin position indicator, drawn outside the clip so it is never
    /// scrolled away with the content it describes.
    fileprivate func emitScrollIndicator(
        _ scroll: ScrollNode, x: Float, y: Float, w: Float, h: Float
    ) {
        let thickness: Float = 4
        let track = scroll.viewportLength
        guard track > 0, scroll.contentLength > 0 else { return }

        let ratio = min(1, track / scroll.contentLength)
        let thumb = max(24, track * ratio)
        let travel = track - thumb
        let progress = scroll.maxOffset > 0 ? scroll.scrollOffset / scroll.maxOffset : 0
        let along = travel * min(1, max(0, progress))

        let color = Color(
            r: Theme.current.textSecondary.r,
            g: Theme.current.textSecondary.g,
            b: Theme.current.textSecondary.b,
            a: 0.55
        )
        if scroll.axis == .vertical {
            roundedRect(
                x: x + w - thickness - 2, y: y + along,
                w: thickness, h: thumb, color: color, radius: thickness / 2
            )
        } else {
            roundedRect(
                x: x + along, y: y + h - thickness - 2,
                w: thumb, h: thickness, color: color, radius: thickness / 2
            )
        }
    }
}

#endif
