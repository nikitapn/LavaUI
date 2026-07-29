#if canImport(CxxCanvas)
import Foundation

/// A clickable control with animated press and hover states.
///
/// The press feedback is driven entirely on the node: pressing retargets an
/// `Animated<Color>` and the frame loop interpolates it. No `body` runs, no
/// reconciliation happens, and the `Mirror`-based state transplant does not
/// fire — a press costs a draw-list re-emit and nothing else.
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

    public var resolvedFont: UIFont? { font ?? FontStore.default }

    public var dumpDetail: String { "\"\(title)\"\(isEnabled ? "" : " disabled")" }

    public func mountPrimitive() -> any AnyViewNode {
        let leaf = LeafNode(kind: .button, label: "Button", width: .auto, height: .auto)
        leaf.buttonFill = Animated(style.background)
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
        leaf.text = title
        leaf.font = resolvedFont
        leaf.color = isEnabled ? style.foreground : style.disabledForeground
        leaf.cornerRadius = style.cornerRadius
        leaf.padding = style.padding
        leaf.buttonStyle = style
        leaf.isEnabled = isEnabled
        leaf.applyStyle()

        // Hover is a state change like any other; the node retargets and the
        // driver interpolates.
        leaf.onHover = { [weak leaf] inside in
            guard let leaf, leaf.isEnabled else { return }
            leaf.retargetFill(hovered: inside, pressed: leaf.isPressed)
        }
        // Marks the node as a hover-test target. The fill itself is animated,
        // so this value is never drawn directly.
        leaf.hoverFill = style.hover
        HoverState.register(leaf.id) { [weak leaf] inside in
            leaf?.onHover?(inside)
        }

        let act = action
        leaf.onClickLocal = { [weak leaf] _, _, _, _ in
            guard let leaf, leaf.isEnabled else { return }
            leaf.isPressed = true
            leaf.retargetFill(hovered: true, pressed: true)

            // Capture so the release is seen even if the pointer leaves, and so
            // the action fires on *release* rather than on press — dragging off
            // a button is how a user cancels it.
            PointerCapture.capture(
                leaf.id,
                onMove: { _, _ in },
                onUp: { [weak leaf] in
                    guard let leaf else { return }
                    let wasInside = HoverState.isHovered(leaf.id)
                    leaf.isPressed = false
                    leaf.retargetFill(hovered: wasInside, pressed: false)
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
        let theme = Theme.current
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

extension LeafNode {
    /// Moves the fill toward whatever the current interaction state implies,
    /// and keeps the node registered with the driver while it is in flight.
    func retargetFill(hovered: Bool, pressed: Bool) {
        guard let style = buttonStyle else { return }
        let destination: Color
        if !isEnabled {
            destination = style.disabledBackground
        } else if pressed {
            destination = style.pressed
        } else if hovered {
            destination = style.hover
        } else {
            destination = style.background
        }
        guard buttonFill?.target != destination else { return }

        buttonFill?.animate(to: destination, duration: style.duration)
        let id = self.id
        AnimationDriver.register(id) { [weak self] in
            guard let self else { return false }
            let running = self.buttonFill?.step(FrameScheduler.now()) ?? false
            return running
        }
        ViewInvalidation.markNeedsRedraw()
    }
}

#endif
