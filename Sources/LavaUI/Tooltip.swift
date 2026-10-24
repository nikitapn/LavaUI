import Foundation

// A name for a control that has no room for one.
//
// Painted, not presented. An `.overlay` takes input first and dismisses on a
// click outside it, which is right for a menu and wrong here: the click a
// tooltip is in the way of is the click on the button it describes. So there
// is no node, no layout and nothing to hit-test — the anchor's rect is picked
// up during the frame's walk, like an overlay's, and the label is drawn after
// everything else, which is all "above everything" has to mean for something
// that cannot be clicked.
//
// Rides the hover the renderer already reports. A node with a tooltip is a
// hit-test node for the same reason a `.onHover` region is: the pointer
// entering it has to be something anybody hears about.

extension View {
    /// Shows `text` beside this view after the pointer has rested on it.
    ///
    /// For a control whose meaning is a picture — an icon button. Hidden again
    /// by a press, a key or a wheel: whoever is acting already knows what the
    /// control is.
    ///
    /// ```swift
    /// IconButton("folder-plus") { session.startNewFolder() }
    ///     .tooltip("New Folder")
    /// ```
    public func tooltip(_ text: String) -> ModifiedView<Self> {
        var style = ViewStyle()
        style.tooltip = text
        return ModifiedView(content: self, style: style)
    }
}

extension ModifiedView {
    /// See `View.tooltip(_:)`.
    public func tooltip(_ text: String) -> ModifiedView<Content> {
        var next = ViewStyle()
        next.tooltip = text
        return ModifiedView(
            content: content, style: next.merged(over: style),
            forceWrapper: forceWrapper
        )
    }
}

/// Whose tooltip is up, or coming up. One pointer, one tooltip, and node ids
/// unique across windows — so process-wide, like `HoverRegions`, and only
/// the window whose tree holds the anchor ever finds it to draw.
enum Tooltips {
    /// How long the pointer rests before the first one shows.
    static let delay: Double = 0.6
    /// Moving from one control to the next within this long of a tooltip
    /// showing skips the delay: someone reading along a toolbar should not
    /// wait out the delay again at every button.
    static let grace: Double = 0.5

    nonisolated(unsafe) private(set) static var anchor: NodeID?
    nonisolated(unsafe) private static var since: Double = 0
    /// When a tooltip was last on screen, for `grace`.
    nonisolated(unsafe) private static var lastShown: Double = -.infinity
    /// Set by a press; holds until the pointer reaches another anchor.
    nonisolated(unsafe) private static var suppressed = false

    /// The hovered node changed. Same inputs as `HoverRegions.update`, and
    /// called from it.
    static func update(hovered: NodeID?, in root: (any AnyViewNode)?) {
        var next: NodeID?
        if let hovered, let root { next = innermost(hovered, in: root) }
        guard next != anchor else { return }
        let now = FrameScheduler.now()
        let wasVisible = isVisible(at: now)
        if wasVisible { lastShown = now }
        anchor = next
        suppressed = false
        if next != nil {
            since = now - lastShown <= grace ? now - delay : now
            // The deadline is the event: a pointer at rest sends nothing else.
            FrameScheduler.requestRedraw(in: max(0, since + delay - now))
        }
        // Only when what is on screen changes. A hover is otherwise free in
        // client mode — the renderer tints without asking — and a pointer
        // sweeping across a toolbar should not cost a frame per button.
        if wasVisible || isVisible(at: now) {
            ViewInvalidation.markNeedsRedraw()
        }
    }

    /// A press, a key or a wheel: the user is acting on the control, not
    /// asking what it is.
    static func dismiss() {
        guard anchor != nil, !suppressed else { return }
        if isVisible(at: FrameScheduler.now()) {
            ViewInvalidation.markNeedsRedraw()
        }
        suppressed = true
    }

    static func isVisible(at now: Double) -> Bool {
        anchor != nil && !suppressed && now - since >= delay
    }

    /// The innermost node with a tooltip on the way down to `id`.
    private static func innermost(_ id: NodeID, in node: any AnyViewNode) -> NodeID? {
        var found: NodeID?
        _ = walk(id, in: node, found: &found)
        return found
    }

    private static func walk(
        _ id: NodeID, in node: any AnyViewNode, found: inout NodeID?
    ) -> Bool {
        let saved = found
        if (node as? YogaBoxNode)?.tooltip != nil { found = node.id }
        if node.id == id { return true }
        for child in node.childNodes where walk(id, in: child, found: &found) {
            return true
        }
        found = saved
        return false
    }
}

extension DrawList {
    /// The label, under its anchor or over it when there is no room below,
    /// pulled back inside the window at the sides.
    func emitTooltip(
        _ text: String, anchorX: Float, anchorY: Float, anchorW: Float, anchorH: Float,
        viewportW: Float, viewportH: Float
    ) {
        guard !text.isEmpty, let font = FontStore.default else { return }
        let theme = Theme.current
        let padX: Float = 8
        let padY: Float = 4
        let gap: Float = 6
        let w = font.shapedRun(text).width + padX * 2
        let h = font.lineHeight + padY * 2
        var x = anchorX + (anchorW - w) / 2
        x = max(4, min(x, viewportW - w - 4))
        var y = anchorY + anchorH + gap
        if y + h > viewportH - 4 { y = anchorY - gap - h }
        y = max(4, y)
        // Outline as a plate one pixel proud, as overlays draw theirs: a
        // `panel` label over `panel` chrome is otherwise only its shadow.
        roundedRect(
            x: x - 1, y: y - 1, w: w + 2, h: h + 2,
            color: theme.border, radius: theme.cornerRadius + 1
        )
        roundedRect(x: x, y: y, w: w, h: h, color: theme.panel, radius: theme.cornerRadius)
        // `text` adds 4 of its own to the pen.
        self.text(
            text, x: x + padX - 4, y: y + padY, w: w, h: font.lineHeight,
            color: theme.textPrimary, font: font
        )
    }
}
