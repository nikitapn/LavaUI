import Foundation
import LavaText

public struct MarkdownStyle {
    public var text: Color
    public var palette: [Color]

    public init(text: Color? = nil, palette: [Color]? = nil) {
        let theme = Environment.current.theme
        self.text = text ?? theme.textPrimary
        self.palette = palette ?? [
            theme.accent,         // heading
            theme.textPrimary,    // strong
            theme.textSecondary,  // emphasis
            theme.selected,       // code
            theme.accent,         // link
            theme.textDim,        // quote
        ]
    }

    func color(for style: MarkdownSpanStyle) -> Color {
        let index = style.rawValue
        return palette.indices.contains(index) ? palette[index] : text
    }
}

/// Read-only Markdown rendered as one wrapping, character-styled text leaf.
public struct MarkdownView: PrimitiveView {
    public var source: String
    public var style: MarkdownStyle
    public var font: UIFont?

    public init(_ source: String, style: MarkdownStyle = MarkdownStyle(), font: UIFont? = nil) {
        self.source = source
        self.style = style
        self.font = font
    }

    public var resolvedFont: UIFont? { font ?? Environment.current.font }
    public var dumpDetail: String { "markdown \(source.count) chars" }

    public func mountPrimitive() -> any AnyViewNode {
        let leaf = LeafNode(kind: .markdown, label: "MarkdownView", width: .auto, height: .auto)
        configure(leaf)
        leaf.installTextMeasure()
        return leaf
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let leaf = node as? LeafNode, leaf.kind == .markdown else { return mountPrimitive() }
        configure(leaf)
        if !leaf.usesTextMeasure { leaf.installTextMeasure() }
        leaf.markMeasureDirty()
        return leaf
    }

    private func configure(_ leaf: LeafNode) {
        let document = MarkdownParser.parse(source)
        leaf.text = document.text
        leaf.color = style.text
        leaf.markdownSpans = document.spans
        leaf.markdownStyle = style
        leaf.font = resolvedFont
        leaf.theme = Environment.current.theme
        leaf.label = "MarkdownView"
    }
}
