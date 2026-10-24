import Foundation

/// A font-independent disclosure chevron, pointing right when collapsed and down when expanded.
public struct DisclosureChevron: View {
    public var isExpanded: Bool
    public var size: Float
    public var color: Color
    public var lineWidth: Float

    public init(isExpanded: Bool, size: Float = 14, color: Color = .primary, lineWidth: Float = 1.5) {
        self.isExpanded = isExpanded
        self.size = size
        self.color = color
        self.lineWidth = lineWidth
    }

    public var body: some View {
        let expanded = isExpanded
        let color = color
        let lineWidth = lineWidth
        return Canvas(label: "Disclosure", width: .pt(size), height: .pt(size)) { list, frame in
            let cx = frame.x + frame.w * 0.5
            let cy = frame.y + frame.h * 0.5
            let arm = min(frame.w, frame.h) * (4.0 / 14.0)
            if expanded {
                list.line(x1: cx - arm, y1: cy - arm * 0.5, x2: cx, y2: cy + arm * 0.5,
                          color: color, width: lineWidth)
                list.line(x1: cx, y1: cy + arm * 0.5, x2: cx + arm, y2: cy - arm * 0.5,
                          color: color, width: lineWidth)
            } else {
                list.line(x1: cx - arm * 0.5, y1: cy - arm, x2: cx + arm * 0.5, y2: cy,
                          color: color, width: lineWidth)
                list.line(x1: cx + arm * 0.5, y1: cy, x2: cx - arm * 0.5, y2: cy + arm,
                          color: color, width: lineWidth)
            }
        }
    }
}

/// Disclosure control: chevron + title in a rounded outline, content below when open.
///
/// Matches the common “expand block” pattern (› header, bordered pill). Use it to
/// gate continuous work — live charts, `AnimationDriver` widgets — so a long
/// scroll is not paying redraws while the section is collapsed.
public struct Expand<Content: View>: View {
    /// The header text, shown after the chevron.
    public var title: String
    /// Whether the content is showing. Clicking the header toggles it.
    public var isExpanded: Binding<Bool>
    /// Colours, chevrons, paddings and the reveal transition.
    public var style: ExpandStyle
    /// What the disclosure shows while expanded.
    public var content: Content

    /// Creates a disclosure.
    /// - Parameters:
    /// - title: The header text.
    /// - isExpanded: Whether the content shows; the header toggles it.
    /// - style: Colours and metrics; the default follows the theme.
    /// - content: What shows while expanded. It is not mounted while collapsed.
    public init(
        _ title: String,
        isExpanded: Binding<Bool>,
        style: ExpandStyle = ExpandStyle(),
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.isExpanded = isExpanded
        self.style = style
        self.content = content()
    }

    public var body: some View {
        let open = isExpanded.wrappedValue
        let binding = isExpanded
        let s = style
        let chevron = open ? s.expandedChevron : s.collapsedChevron
        let innerRadius = max(0, s.cornerRadius - s.borderWidth)

        // Outer stack paints the outline; inner stack is the surface. Nested
        // fills + padding = 1px stroke without a dedicated border primitive.
        VStack(padding: s.borderWidth) {
            VStack(padding: 0) {
                HStack(padding: 0, alignment: .center, spacing: 8,
                       onClick: { binding.wrappedValue.toggle() }) {
                    if let chevron {
                        Text(chevron, color: s.titleColor)
                    } else {
                        DisclosureChevron(isExpanded: open, color: s.titleColor)
                    }
                    Text(title, color: s.titleColor)
                }
                .hoverBackground(s.hoverFill)
                .cornerRadius(max(0, innerRadius - 2))
                .cursor(.pointer)
                // Inside the hover fill, so the fill is a chip round the title
                // rather than a box flush with its glyphs.
                .padding(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                .padding(s.headerPadding)

                if open {
                    content
                        .padding(s.contentPadding)
                        .transition(s.transition)
                }
            }
            .background(s.background)
            .cornerRadius(innerRadius)
        }
        .background(s.border)
        .cornerRadius(s.cornerRadius)
    }
}

/// Colours and metrics for an `Expand` disclosure.
public struct ExpandStyle {
    /// Optional custom header glyph while collapsed; nil uses the drawn chevron.
    public var collapsedChevron: String?
    /// Optional custom header glyph while expanded; nil uses the drawn chevron.
    public var expandedChevron: String?
    /// Colour of the header text.
    public var titleColor: Color
    /// Fill inside the outline.
    public var background: Color
    /// Colour of the outline.
    public var border: Color
    /// Fill under the header while the pointer is over it.
    public var hoverFill: Color
    /// Corner radius of the outline, in points.
    public var cornerRadius: Float
    /// Width of the outline, in points.
    public var borderWidth: Float
    /// Space around the header text, in points.
    public var headerPadding: Float
    /// Space around the content, in points.
    public var contentPadding: Float
    /// How the content appears and disappears.
    public var transition: Transition

    /// Creates a style. Colours and radius left `nil` come from the current theme.
    public init(
        collapsedChevron: String? = nil,
        expandedChevron: String? = nil,
        titleColor: Color? = nil,
        background: Color? = nil,
        border: Color? = nil,
        hoverFill: Color? = nil,
        cornerRadius: Float? = nil,
        borderWidth: Float = 1,
        headerPadding: Float = 10,
        contentPadding: Float = 10,
        transition: Transition = .slide(dy: -14)
    ) {
        let theme = Environment.current.theme
        self.collapsedChevron = collapsedChevron
        self.expandedChevron = expandedChevron
        self.titleColor = titleColor ?? theme.textSecondary
        // Inset surface so the outline reads as a stroke, not a filled plate.
        self.background = background ?? theme.inset
        self.border = border ?? theme.border
        self.hoverFill = hoverFill ?? theme.hover
        self.cornerRadius = cornerRadius ?? max(theme.cornerRadius, 8)
        self.borderWidth = borderWidth
        self.headerPadding = headerPadding
        self.contentPadding = contentPadding
        self.transition = transition
    }
}
