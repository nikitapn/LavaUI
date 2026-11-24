/// A horizontal shake triggered by a change to an equatable value.
public struct ShakeView<Content: View, Trigger: Equatable>: PrimitiveView {
    let content: Content
    let trigger: Trigger
    let distance: Float
    let duration: Double

    public func mountPrimitive() -> any AnyViewNode {
        ShakeNode(content: ViewGraph.mount(content), trigger: trigger)
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let box = node as? ShakeNode<Trigger> else { return mountPrimitive() }
        box.updateContent(ViewGraph.reconcile(box.contentNode, with: content))
        box.updateTrigger(trigger, distance: distance, duration: duration)
        return box
    }
}

extension View {
    /// Shakes horizontally when `trigger` changes. The view keeps its layout,
    /// mounted state and keyboard focus throughout the effect.
    public func shake<Trigger: Equatable>(
        trigger: Trigger, distance: Float = 6, duration: Double = 0.35
    ) -> ShakeView<Self, Trigger> {
        ShakeView(content: self, trigger: trigger, distance: distance, duration: duration)
    }
}

final class ShakeNode<Trigger: Equatable>: StyleBoxNode {
    private var trigger: Trigger

    init(content: any AnyViewNode, trigger: Trigger) {
        self.trigger = trigger
        super.init(content: content)
        label = "Shake"
    }

    func updateTrigger(_ next: Trigger, distance: Float, duration: Double) {
        guard trigger != next else { return }
        trigger = next
        visualOffsetX = 0
        guard distance.isFinite, duration.isFinite, distance > 0, duration > 0 else {
            AnimationDriver.unregister(id)
            return
        }
        let start = FrameScheduler.now()
        AnimationDriver.register(id) { [weak self] in
            guard let self else { return false }
            let progress = (FrameScheduler.now() - start) / duration
            self.visualOffsetX = Self.offset(at: progress) * distance
            return progress < 1
        }
    }

    static func offset(at progress: Double) -> Float {
        guard progress > 0, progress < 1 else { return 0 }
        let positions: [Float] = [0, -1, 1, -1, 1, 0]
        let phase = progress * 5
        let index = min(Int(phase), positions.count - 2)
        let local = Float(phase - Double(index))
        let eased = local * local * (3 - 2 * local)
        return positions[index] + (positions[index + 1] - positions[index]) * eased
    }
}
