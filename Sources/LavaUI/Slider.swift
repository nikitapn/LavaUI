#if canImport(CxxCanvas)
import Foundation

/// A draggable value in a range.
///
/// Unlike `Button` and `Toggle`, this is a *drag* control: the press captures
/// the pointer and every move recomputes the value, so the interesting part is
/// coordinate conversion rather than animation. The knob position is not
/// animated at all — during a drag it has to sit under the pointer, and
/// interpolating there reads as the control lagging behind the hand.
///
/// No label. A slider's label is not part of its hit target, so it composes
/// better as a neighbouring `Text` than as a bundled string — which is the
/// opposite of `Toggle`, where the label *is* part of what you click.
public struct Slider: PrimitiveView {
    public var value: Binding<Float>
    public var range: ClosedRange<Float>
    /// Quantisation. nil is continuous.
    public var step: Float?
    /// Renders a readout to the right of the track. nil draws no readout.
    public var format: ((Float) -> String)?
    public var style: SliderStyle
    public var font: UIFont?
    public var isEnabled: Bool

    public init(
        value: Binding<Float>,
        in range: ClosedRange<Float> = 0...1,
        step: Float? = nil,
        format: ((Float) -> String)? = nil,
        style: SliderStyle = SliderStyle(),
        font: UIFont? = nil,
        isEnabled: Bool = true
    ) {
        self.value = value
        self.range = range
        self.step = step
        self.format = format
        self.style = style
        self.font = font
        self.isEnabled = isEnabled
    }

    public var resolvedFont: UIFont? { font ?? FontStore.default }

    public var dumpDetail: String {
        "\(value.wrappedValue) in \(range.lowerBound)...\(range.upperBound)"
    }

    /// Where the current value sits across the track, 0…1.
    private var fraction: Float {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max(0, (value.wrappedValue - range.lowerBound) / span), 1)
    }

    public func mountPrimitive() -> any AnyViewNode {
        let leaf = LeafNode(kind: .slider, label: "Slider", width: .auto, height: .auto)
        leaf.sliderKnobScale = Animated(1)
        configure(leaf)
        leaf.installTextMeasure()
        return leaf
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let leaf = node as? LeafNode, leaf.kind == .slider else {
            return mountPrimitive()
        }
        configure(leaf)
        if !leaf.usesTextMeasure { leaf.installTextMeasure() }
        leaf.markMeasureDirty()
        return leaf
    }

    private func configure(_ leaf: LeafNode) {
        leaf.font = resolvedFont
        leaf.color = isEnabled ? style.foreground : style.disabledForeground
        leaf.sliderStyle = style
        leaf.isEnabled = isEnabled
        // The readout rides in `text`, which the measure and emit paths already
        // understand; the node does not need to know the value itself.
        leaf.text = format?(value.wrappedValue) ?? ""
        // Re-read every reconcile, so a value changed from elsewhere moves the
        // knob without the drag handler being involved.
        leaf.sliderFraction = fraction
        leaf.applyStyle()

        leaf.onHover = { [weak leaf] inside in
            guard let leaf, leaf.isEnabled else { return }
            leaf.retargetSliderKnob(active: inside || leaf.isPressed)
        }
        HoverState.register(leaf.id) { [weak leaf] inside in
            leaf?.onHover?(inside)
        }

        let commit = self.commit
        leaf.onClickLocal = { [weak leaf] localX, _, originX, _ in
            guard let leaf, leaf.isEnabled else { return }
            leaf.isPressed = true
            leaf.retargetSliderKnob(active: true)
            // Pressing anywhere on the track jumps there, then drags — the
            // behaviour every desktop slider has.
            commit(leaf, localX)

            PointerCapture.capture(
                leaf.id,
                // `originX` is the node's absolute origin from the hit test.
                // Pointer capture delivers window coordinates long after that
                // hit test, so the origin has to be carried in the closure.
                onMove: { [weak leaf] windowX, _ in
                    guard let leaf else { return }
                    commit(leaf, windowX - originX)
                },
                onUp: { [weak leaf] in
                    guard let leaf else { return }
                    leaf.isPressed = false
                    leaf.retargetSliderKnob(active: HoverState.isHovered(leaf.id))
                }
            )
        }
    }

    /// Converts a node-local x to a value and writes it through the binding.
    private var commit: (LeafNode, Float) -> Void {
        let binding = value
        let lo = range.lowerBound
        let hi = range.upperBound
        let step = self.step
        // Captured so a drag can refresh the readout without a body recompute.
        // The reserved `valueWidth` is what makes this safe: the string changes
        // but the node's measured size cannot, so no re-layout is owed.
        let format = self.format
        return { leaf, localX in
            guard leaf.sliderTravel > 0, hi > lo else { return }
            let f = min(max(0, (localX - leaf.sliderInset) / leaf.sliderTravel), 1)
            var v = lo + f * (hi - lo)
            if let step, step > 0 {
                v = lo + ((v - lo) / step).rounded() * step
            }
            v = min(max(lo, v), hi)
            // Skipping the no-op matters most for a stepped slider, where many
            // pixels quantise onto the same value and each write would
            // otherwise notify whatever observes it.
            guard v != binding.wrappedValue else { return }
            binding.wrappedValue = v
            // Both updated here rather than waiting for `configure`: if nothing
            // observes the bound value there is no body pass to wait for, and
            // these are the only two things a drag changes.
            leaf.sliderFraction = (v - lo) / (hi - lo)
            leaf.text = format?(v) ?? ""
        }
    }
}

/// Colours and metrics for a `Slider`.
public struct SliderStyle {
    /// Track length when nothing stretches it.
    public var trackWidth: Float
    public var trackThickness: Float
    public var knobRadius: Float
    /// Knob size multiplier while hovered or dragged.
    public var knobHoverScale: Float
    public var activeTrack: Color
    public var inactiveTrack: Color
    public var knob: Color
    public var disabledTrack: Color
    public var disabledKnob: Color
    public var foreground: Color
    public var disabledForeground: Color
    public var valueGap: Float
    /// Space reserved for the readout, wide enough that its text changing
    /// width cannot resize the track mid-drag.
    public var valueWidth: Float
    public var duration: Double

    public init(
        trackWidth: Float = 140,
        trackThickness: Float = 4,
        knobRadius: Float = 7,
        knobHoverScale: Float = 1.25,
        activeTrack: Color? = nil,
        inactiveTrack: Color? = nil,
        knob: Color? = nil,
        disabledTrack: Color? = nil,
        disabledKnob: Color? = nil,
        foreground: Color? = nil,
        disabledForeground: Color? = nil,
        valueGap: Float = 8,
        valueWidth: Float = 44,
        duration: Double = 0.1
    ) {
        let theme = Theme.current
        self.trackWidth = trackWidth
        self.trackThickness = trackThickness
        self.knobRadius = knobRadius
        self.knobHoverScale = knobHoverScale
        self.activeTrack = activeTrack ?? theme.accent
        self.inactiveTrack = inactiveTrack ?? theme.border
        // The knob sits on the window background, not on the track, so unlike
        // `Toggle`'s it contrasts against the surface and a text token works.
        self.knob = knob ?? theme.textPrimary
        self.disabledTrack = disabledTrack ?? theme.panel
        self.disabledKnob = disabledKnob ?? theme.textSecondary
        self.foreground = foreground ?? theme.textSecondary
        self.disabledForeground = disabledForeground ?? theme.textSecondary
        self.valueGap = valueGap
        self.valueWidth = valueWidth
        self.duration = duration
    }
}

extension LeafNode {
    /// Grows the knob while the control is hovered or being dragged.
    func retargetSliderKnob(active: Bool) {
        guard let style = sliderStyle else { return }
        let target: Float = (active && isEnabled) ? style.knobHoverScale : 1
        guard sliderKnobScale?.target != target else { return }

        sliderKnobScale?.animate(to: target, duration: style.duration)
        let id = self.id
        AnimationDriver.register(id) { [weak self] in
            guard let self else { return false }
            return self.sliderKnobScale?.step(FrameScheduler.now()) ?? false
        }
        ViewInvalidation.markNeedsRedraw()
    }
}

#endif
