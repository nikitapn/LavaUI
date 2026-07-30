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
    public var cornerRadius: Float

    public init(
        _ string: String,
        color: Color = .primary,
        font: UIFont? = nil,
        hoverFill: Color? = nil,
        cornerRadius: Float = 0,
        onClick: (() -> Void)? = nil
    ) {
        self.string = string
        self.color = color
        self.font = font
        self.onClick = onClick
        self.hoverFill = onClick == nil ? hoverFill : (hoverFill ?? Environment.current.theme.hover)
        self.cornerRadius = cornerRadius
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
        leaf.cornerRadius = cornerRadius
        leaf.font = resolvedFont
        leaf.label = "Text \"\(shortLabel)\""
        leaf.installTextMeasure()
        return leaf
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        if let leaf = node as? LeafNode, leaf.kind == .text {
            let prevFontId = leaf.font?.identity
            leaf.update(
                label: "Text \"\(shortLabel)\"",
                width: .auto,
                height: .auto,
                text: string,
                color: color,
                onClick: onClick
            )
            leaf.hoverFill = hoverFill
            leaf.cornerRadius = cornerRadius
            leaf.font = resolvedFont
            if !leaf.usesTextMeasure {
                leaf.installTextMeasure()
            } else {
                // Always dirty: content scale swaps `FontStore.default` without
                // changing the string, and Yoga must re-measure with the new face.
                leaf.markMeasureDirty()
                if prevFontId != leaf.font?.identity {
                    leaf.cachedLines = []
                }
            }
            return leaf
        }
        return mountPrimitive()
    }

    private var shortLabel: String {
        string.count > 24 ? String(string.prefix(24)) + "…" : string
    }
}
