/// Text label primitive — Phase 4: Yoga measure via `canvas::Font` + layout cache.
public struct Text: PrimitiveView {
    public var string: String
    public var color: Color
    /// `nil` → `FontStore.default` (global UI face).
    public var font: UIFont?
    /// Closures break value equality (SwiftUI wart) — fine until Phase 5 skip-recompute.
    public var onClick: (() -> Void)?
    /// Row highlight under the pointer. Defaults to the theme's hover surface
    /// for clickable text, since an unclickable label highlighting on hover
    /// would be lying about being interactive.
    public var hoverFill: Color?
    public var hoverColor: Color?
    public var cornerRadius: Float
    public var lineLimit: Int?
    /// Where the glyphs sit when the node is wider than they are.
    ///
    /// A label that states its own width — `.frame(width:)`, a grid cell, a
    /// stack that stretches it — is a box with room left over, and until this
    /// existed the text was always jammed against the leading edge of it.
    /// The only way to centre one was `.frame(width:alignment:)`, which is a
    /// different thing entirely: it wraps the text in a box it does not own,
    /// and that box is where the width, the background, the hover fill and
    /// the cursor then land, while `onClick` stays on the text inside. The
    /// control ends up hovering at one size and clicking at another.
    ///
    /// So this is deliberately *not* a layout property. It moves the pen
    /// inside a node that already exists, and adds no node — which is what
    /// keeps a centred label the same click target as a leading one.
    ///
    /// Both axes, and the same `Alignment` the frame takes, so moving a call
    /// site across is the same word in a different place. The default is
    /// `.topLeading` rather than `.center`, because top-leading is where a
    /// text's glyphs have always gone and every existing caller is drawn
    /// against that.
    public var align: Alignment

    public init(
        _ string: String,
        color: Color = .primary,
        font: UIFont? = nil,
        hoverFill: Color? = nil,
        hoverColor: Color? = nil,
        cornerRadius: Float = 0,
        lineLimit: Int? = nil,
        align: Alignment = .topLeading,
        onClick: (() -> Void)? = nil
    ) {
        self.string = string
        self.color = color
        self.font = font
        self.onClick = onClick
        self.hoverColor = hoverColor
        self.hoverFill = onClick == nil || hoverColor != nil
            ? hoverFill
            : (hoverFill ?? Environment.current.theme.hover)
        self.cornerRadius = cornerRadius
        self.lineLimit = lineLimit.map { max(1, $0) }
        self.align = align
    }

    /// Resolved face for measure (explicit or environment default).
    public var resolvedFont: UIFont? { font ?? Environment.current.font }

    public var dumpDetail: String {
        let click = onClick == nil ? "" : " onClick"
        let preview = string.count > 40 ? String(string.prefix(40)) + "…" : string
        return "\"\(preview)\"\(click)"
    }

    public func mountPrimitive() -> any AnyViewNode {
        let leaf = LeafNode(
            kind: .text,
            label: "Text",
            width: .auto,
            height: .auto
        )
        leaf.text = string
        leaf.color = color
        leaf.onClick = onClick
        leaf.hoverFill = hoverFill
        leaf.hoverColor = hoverColor
        leaf.cornerRadius = cornerRadius
        leaf.textLineLimit = lineLimit
        leaf.textAlign = align
        leaf.font = resolvedFont
        leaf.label = "Text \"\(shortLabel)\""
        leaf.installTextMeasure()
        return leaf
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        if let leaf = node as? LeafNode, leaf.kind == .text {
            let prevFontId = leaf.font?.identity
            let prevLineLimit = leaf.textLineLimit
            leaf.update(
                label: "Text \"\(shortLabel)\"",
                width: .auto,
                height: .auto,
                text: string,
                color: color,
                onClick: onClick
            )
            leaf.hoverFill = hoverFill
            leaf.hoverColor = hoverColor
            leaf.cornerRadius = cornerRadius
            leaf.textLineLimit = lineLimit
            // Paint-only, so it never dirties the measure: where the pen
            // starts inside the box does not change how wide the box is.
            leaf.textAlign = align
            leaf.font = resolvedFont
            if !leaf.usesTextMeasure {
                leaf.installTextMeasure()
            } else if prevFontId != leaf.font?.identity {
                // Content scale swaps `FontStore.default` without changing the
                // string, and Yoga has to re-measure against the new face.
                leaf.markMeasureDirty()
                leaf.cachedLines = []
            } else if prevLineLimit != leaf.textLineLimit {
                leaf.markMeasureDirty()
            }
            // Deliberately *not* dirtied otherwise, and this is the whole
            // difference between a body pass that re-lays-out one row and one
            // that re-lays-out the window.
            //
            // Marking a text leaf dirty propagates to every ancestor, so doing
            // it unconditionally meant every body pass dirtied every text node
            // and every box above it — measured at 2249 of 2813 nodes on a
            // frame where one label changed, and Yoga then had nothing left to
            // skip. The three inputs `measureForYoga` actually reads are the
            // string, the face and the line limit: `update` dirties on the
            // first, and the two branches above cover the others.
            return leaf
        }
        return mountPrimitive()
    }

    private var shortLabel: String {
        string.count > 24 ? String(string.prefix(24)) + "…" : string
    }
}

extension Text {
    /// Limits wrapped rows and truncates the final visible row with an
    /// ellipsis when additional content exists.
    public func lineLimit(_ limit: Int?) -> Text {
        var copy = self
        copy.lineLimit = limit.map { max(1, $0) }
        return copy
    }
}
