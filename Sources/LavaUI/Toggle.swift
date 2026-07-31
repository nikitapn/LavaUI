#if canImport(CxxCanvas)
import Foundation

/// A boolean switch with an animated knob.
///
/// The value lives wherever the `Binding` points; the node keeps only what is
/// needed to *draw* the transition. That split matters: flipping the binding
/// from anywhere — another control, a model update, a keyboard shortcut — still
/// animates, because `configure` retargets from the bound value on every
/// reconcile rather than only from the click handler.
public struct Toggle: PrimitiveView {
    public var label: String
    public var isOn: Binding<Bool>
    public var style: ToggleStyle
    public var font: UIFont?
    public var isEnabled: Bool

    public init(
        _ label: String = "",
        isOn: Binding<Bool>,
        style: ToggleStyle = ToggleStyle(),
        font: UIFont? = nil,
        isEnabled: Bool = true
    ) {
        self.label = label
        self.isOn = isOn
        self.style = style
        self.font = font
        self.isEnabled = isEnabled
    }

    public var resolvedFont: UIFont? { font ?? Environment.current.font }

    public var dumpDetail: String {
        "\"\(label)\" \(isOn.wrappedValue ? "on" : "off")\(isEnabled ? "" : " disabled")"
    }

    public func mountPrimitive() -> any AnyViewNode {
        let leaf = LeafNode(kind: .toggle, label: "Toggle", width: .auto, height: .auto)
        leaf.toggleStyle = style
        leaf.isOn = isOn.wrappedValue
        // Seeded at the resting position so a toggle that starts on does not
        // animate into place on the first frame.
        leaf.toggleKnob = Animated(isOn.wrappedValue ? 1 : 0)
        let track = style.track(on: isOn.wrappedValue, hovered: false, enabled: isEnabled)
        leaf.toggleTrack = Animated(track)
        leaf.toggleKnobColor = Animated(
            style.knobColor(over: track, enabled: isEnabled)
        )
        configure(leaf)
        leaf.installTextMeasure()
        return leaf
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let leaf = node as? LeafNode, leaf.kind == .toggle else {
            return mountPrimitive()
        }
        configure(leaf)
        if !leaf.usesTextMeasure { leaf.installTextMeasure() }
        leaf.markMeasureDirty()
        return leaf
    }

    private func configure(_ leaf: LeafNode) {
        leaf.theme = Environment.current.theme
        leaf.text = label
        leaf.font = resolvedFont
        leaf.color = isEnabled ? style.foreground : style.disabledForeground
        leaf.toggleStyle = style
        leaf.isEnabled = isEnabled
        leaf.isOn = isOn.wrappedValue
        leaf.applyStyle()

        leaf.onHover = { [weak leaf] inside in
            guard let leaf, leaf.isEnabled else { return }
            leaf.retargetToggle(hovered: inside)
        }
        HoverState.register(leaf.id) { [weak leaf] inside in
            leaf?.onHover?(inside)
        }

        let binding = isOn
        leaf.onClickLocal = { [weak leaf] _, _, _, _, _ in
            guard let leaf, leaf.isEnabled else { return }
            leaf.isPressed = true
            // Capture so the flip happens on *release*, and only if the pointer
            // is still inside — dragging off is how a user cancels.
            PointerCapture.capture(
                leaf.id,
                onMove: { _, _ in },
                onUp: { [weak leaf] in
                    guard let leaf else { return }
                    leaf.isPressed = false
                    let inside = HoverState.isHovered(leaf.id)
                    guard inside else { return }
                    binding.wrappedValue.toggle()
                    // Start the animation now rather than waiting for the
                    // rebuild: the binding write invalidates at `.body`, and a
                    // frame of stillness before the knob moves reads as lag.
                    leaf.isOn = binding.wrappedValue
                    leaf.retargetToggle(hovered: true)
                }
            )
        }

        // Also catches a value changed from outside this control.
        leaf.retargetToggle(hovered: HoverState.isHovered(leaf.id))
    }
}

/// Colours and metrics for a `Toggle`.
public struct ToggleStyle {
    public var trackWidth: Float
    public var trackHeight: Float
    /// Gap between the knob and the track edge, on both sides.
    public var knobInset: Float
    public var offTrack: Color
    public var onTrack: Color
    /// nil means "contrast automatically against the track".
    public var knob: Color?
    public var disabledTrack: Color
    public var disabledKnob: Color
    public var foreground: Color
    public var disabledForeground: Color
    public var labelGap: Float
    public var duration: Double

    public init(
        trackWidth: Float = 36,
        trackHeight: Float = 20,
        knobInset: Float = 2.5,
        offTrack: Color? = nil,
        onTrack: Color? = nil,
        knob: Color? = nil,
        disabledTrack: Color? = nil,
        disabledKnob: Color? = nil,
        foreground: Color? = nil,
        disabledForeground: Color? = nil,
        labelGap: Float = 8,
        duration: Double = 0.14
    ) {
        let theme = Environment.current.theme
        self.trackWidth = trackWidth
        self.trackHeight = trackHeight
        self.knobInset = knobInset
        self.offTrack = offTrack ?? theme.border
        self.onTrack = onTrack ?? theme.accent
        self.knob = knob
        self.disabledTrack = disabledTrack ?? theme.panel
        self.disabledKnob = disabledKnob ?? theme.textSecondary
        self.foreground = foreground ?? theme.textPrimary
        self.disabledForeground = disabledForeground ?? theme.textSecondary
        self.labelGap = labelGap
        self.duration = duration
    }

    /// Track colour for an interaction state. Hover variants are *derived*
    /// rather than stored, so a theme swap cannot leave them stale.
    func track(on: Bool, hovered: Bool, enabled: Bool) -> Color {
        guard enabled else { return disabledTrack }
        let base = on ? onTrack : offTrack
        return hovered ? base.lightened(0.18) : base
    }

    /// Knob colour over a given track.
    ///
    /// Chosen by the track's luminance rather than fixed, because neither
    /// theme has a strong-fill token: dark's `accent` is pale and light's
    /// surfaces are paler still, so *any* single knob colour goes invisible in
    /// one of them. The two constants are deliberately not theme tokens — a
    /// knob is a physical object on top of a surface, and it needs to contrast
    /// with that surface, not agree with the palette.
    func knobColor(over track: Color, enabled: Bool) -> Color {
        guard enabled else { return disabledKnob }
        if let knob { return knob }
        return track.luminance > 0.5
            ? Color(r: 0.14, g: 0.15, b: 0.18)
            : Color(r: 0.97, g: 0.97, b: 0.98)
    }
}

extension LeafNode {
    /// Moves knob and track toward whatever the current state implies.
    ///
    /// Both properties share one registered stepper: they always start and end
    /// together, so two registry entries would only mean two dictionary lookups
    /// per frame for the same node.
    func retargetToggle(hovered: Bool) {
        guard let style = toggleStyle else { return }
        let knobTarget: Float = isOn ? 1 : 0
        let trackTarget = style.track(on: isOn, hovered: hovered, enabled: isEnabled)
        // Derived from the *target* track, not the animating one, so the
        // contrast flip rides the same interpolation instead of snapping.
        let colorTarget = style.knobColor(over: trackTarget, enabled: isEnabled)

        let knobSettled = toggleKnob?.target == knobTarget
        let trackSettled = toggleTrack?.target == trackTarget
        let colorSettled = toggleKnobColor?.target == colorTarget
        guard !knobSettled || !trackSettled || !colorSettled else { return }

        if !knobSettled { toggleKnob?.animate(to: knobTarget, duration: style.duration) }
        if !trackSettled { toggleTrack?.animate(to: trackTarget, duration: style.duration) }
        if !colorSettled {
            toggleKnobColor?.animate(to: colorTarget, duration: style.duration)
        }

        let id = self.id
        AnimationDriver.register(id) { [weak self] in
            guard let self else { return false }
            // Every property must step: `||` would short-circuit and freeze
            // whichever came after the first one still running.
            let now = FrameScheduler.now()
            let knobRunning = self.toggleKnob?.step(now) ?? false
            let trackRunning = self.toggleTrack?.step(now) ?? false
            let colorRunning = self.toggleKnobColor?.step(now) ?? false
            return knobRunning || trackRunning || colorRunning
        }
        ViewInvalidation.markNeedsRedraw()
    }
}

#endif
