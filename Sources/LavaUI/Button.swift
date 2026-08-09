import Foundation

/// A clickable control whose hover and press feedback is owned by the renderer.
public struct Button: PrimitiveView {
    public var title: String
    public var action: () -> Void
    public var font: UIFont?
    public var style: ButtonStyle
    public var isEnabled: Bool

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
        leaf.onClickLocal = { [weak leaf] _, _, _, _, _ in
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
    public var background: Color
    public var hover: Color
    public var pressed: Color
    public var foreground: Color
    public var disabledBackground: Color
    public var disabledForeground: Color
    public var cornerRadius: Float
    public var padding: Float
    /// How long the fill takes to reach a new state. Short enough to feel
    /// immediate; long enough to read as a transition rather than a jump.
    public var duration: Double

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
