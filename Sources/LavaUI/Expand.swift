#if canImport(CxxCanvas)
import Foundation

/// Disclosure control: chevron + title in a rounded outline, content below when open.
///
/// Matches the common “expand block” pattern (› header, bordered pill). Use it to
/// gate continuous work — live charts, `AnimationDriver` widgets — so a long
/// scroll is not paying redraws while the section is collapsed.
public struct Expand<Content: View>: View {
    public var title: String
    public var isExpanded: Binding<Bool>
    public var style: ExpandStyle
    public var content: Content

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
                Text(
                    "\(chevron)  \(title)",
                    color: s.titleColor,
                    hoverFill: s.hoverFill,
                    cornerRadius: max(0, innerRadius - 2),
                    onClick: { binding.wrappedValue.toggle() }
                )
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
    public var collapsedChevron: String
    public var expandedChevron: String
    public var titleColor: Color
    public var background: Color
    public var border: Color
    public var hoverFill: Color
    public var cornerRadius: Float
    public var borderWidth: Float
    public var headerPadding: Float
    public var contentPadding: Float
    public var transition: Transition

    public init(
        collapsedChevron: String = "›",
        expandedChevron: String = "˅",
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

#endif
