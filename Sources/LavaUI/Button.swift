import Foundation

/// A clickable control whose hover and press feedback is owned by the renderer.
public struct Button: PrimitiveView {
    /// The label drawn on the button.
    public var title: String
    /// Called when the button is clicked. Not called while disabled.
    public var action: () -> Void
    /// The label's font, or `nil` to use the environment's font.
    public var font: UIFont?
    /// Colours, corner radius and padding.
    public var style: ButtonStyle
    /// Whether the button responds to clicks. A disabled button draws in the style's disabled colours.
    public var isEnabled: Bool

    /// Creates a button with a text label.
    /// - Parameters:
    /// - title: The label.
    /// - style: Colours and metrics; the default follows the current theme.
    /// - font: The label's font; `nil` uses the environment's.
    /// - isEnabled: Whether clicks call `action`.
    /// - action: Called on click.
    public init(
        _ title: String,
        style: ButtonStyle = ButtonStyle(),
        font: UIFont? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.style = style
        self.font = font
        self.isEnabled = isEnabled
        self.action = action
    }

    /// The font the label is drawn in: `font`, or the environment's when that is `nil`.
    public var resolvedFont: UIFont? { font ?? Environment.current.font }

    public var dumpDetail: String { "\"\(title)\"\(isEnabled ? "" : " disabled")" }

    public func mountPrimitive() -> any AnyViewNode {
        let leaf = LeafNode(kind: .button, label: "Button", width: .auto, height: .auto)
        configure(leaf)
        leaf.installTextMeasure()
        return leaf
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let leaf = node as? LeafNode, leaf.kind == .button else {
            return mountPrimitive()
        }
        configure(leaf)
        if !leaf.usesTextMeasure { leaf.installTextMeasure() }
        leaf.markMeasureDirty()
        return leaf
    }

    private func configure(_ leaf: LeafNode) {
        leaf.theme = Environment.current.theme
        leaf.text = title
        leaf.font = resolvedFont
        leaf.color = isEnabled ? style.foreground : style.disabledForeground
        leaf.cornerRadius = style.cornerRadius
        leaf.padding = .all(style.padding)
        leaf.buttonStyle = style
        leaf.isEnabled = isEnabled
        leaf.applyStyle()

        let act = action
        leaf.onClickLocal = { [weak leaf] _, _, _, _, _, _ in
            guard let leaf, leaf.isEnabled else { return }

            // Capture so the release is seen even if the pointer leaves, and so
            // the action fires on *release* rather than on press — dragging off
            // a button is how a user cancels it.
            PointerCapture.capture(
                leaf.id,
                onMove: { _, _ in },
                onUp: { [weak leaf] in
                    guard let leaf else { return }
                    let wasInside = HoverState.isHovered(leaf.id)
                    if wasInside { act() }
                }
            )
        }
    }
}

/// Colours and metrics for a `Button`.
public struct ButtonStyle {
    /// The fill at rest.
    public var background: Color
    /// The fill under the pointer.
    public var hover: Color
    /// The fill while pressed.
    public var pressed: Color
    /// The label colour.
    public var foreground: Color
    /// The fill while disabled.
    public var disabledBackground: Color
    /// The label colour while disabled.
    public var disabledForeground: Color
    /// Corner radius of the fill, in points.
    public var cornerRadius: Float
    /// Space between the label and the edge of the fill, on every side, in points.
    public var padding: Float
    /// How long the fill takes to reach a new state. Short enough to feel
    /// immediate; long enough to read as a transition rather than a jump.
    public var duration: Double

    /// Creates a style. Any colour left `nil` comes from the current theme:
    /// `panel` at rest, `hover` under the pointer, `accent` pressed, and
    /// `textPrimary` / `textSecondary` for the label.
    public init(
        background: Color? = nil,
        hover: Color? = nil,
        pressed: Color? = nil,
        foreground: Color? = nil,
        disabledBackground: Color? = nil,
        disabledForeground: Color? = nil,
        cornerRadius: Float? = nil,
        padding: Float = 8,
        duration: Double = 0.12
    ) {
        let theme = Environment.current.theme
        self.background = background ?? theme.panel
        self.hover = hover ?? theme.hover
        self.pressed = pressed ?? theme.accent
        self.foreground = foreground ?? theme.textPrimary
        self.disabledBackground = disabledBackground ?? theme.panel
        self.disabledForeground = disabledForeground ?? theme.textSecondary
        self.cornerRadius = cornerRadius ?? theme.cornerRadius
        self.padding = padding
        self.duration = duration
    }
}
