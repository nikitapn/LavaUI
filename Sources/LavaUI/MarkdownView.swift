import Foundation
import LavaText

/// Colours for a `MarkdownView`.
public struct MarkdownStyle {
    /// Colour of plain text.
    public var text: Color
    /// Colours for styled spans, indexed by `MarkdownSpanStyle`: heading, strong,
    /// emphasis, code, link and quote, in that order. A style past the end falls
    /// back to `text`.
    public var palette: [Color]

    /// Creates a style. `nil` takes colours from the current theme.
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
    /// The Markdown to render.
    public var source: String
    /// Colours for plain text and each span style.
    public var style: MarkdownStyle
    /// The font, or `nil` for the environment's.
    public var font: UIFont?

    /// Renders `source` as Markdown.
    public init(_ source: String, style: MarkdownStyle = MarkdownStyle(), font: UIFont? = nil) {
        self.source = source
        self.style = style
        self.font = font
    }

    /// The font the text is drawn in: `font`, or the environment's when that is `nil`.
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
