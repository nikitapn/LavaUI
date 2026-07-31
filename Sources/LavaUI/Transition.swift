#if canImport(CxxCanvas)
import Foundation

/// How a view animates as it appears and disappears.
///
/// Value animation (`Animated<T>`) covers a property changing on a node that
/// stays put. A transition is the other half: the node itself arriving or
/// leaving. Leaving is the hard direction — by the time a reconciler knows a
/// child is gone, the view describing it no longer exists, so the *node* has to
/// outlive its own removal. That is what `FragmentNode.departingChildren` is
/// for, and it is why this touches the three reconcilers that drop nodes rather
/// than living entirely in a modifier.
public struct Transition: Equatable, Sendable {
    /// Fade between transparent and opaque.
    public var fades: Bool
    /// Where the view comes from and returns to, relative to its final place.
    public var offsetX: Float
    public var offsetY: Float
    public var duration: Double
    public var curve: AnimationCurve

    public init(
        fades: Bool = true,
        offsetX: Float = 0,
        offsetY: Float = 0,
        duration: Double = 0.18,
        curve: AnimationCurve = .easeOut
    ) {
        self.fades = fades
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.duration = duration
        self.curve = curve
    }

    public static let opacity = Transition()

    /// Slides in from `dy` above (negative) or below (positive), fading.
    public static func slide(dx: Float = 0, dy: Float = -8) -> Transition {
        Transition(offsetX: dx, offsetY: dy)
    }
}

/// Live transition on a node: how far in it is, and which way it is going.
final class TransitionState {
    let spec: Transition
    /// 1 = fully present, 0 = fully gone.
    private var progress: Animated<Float>
    private(set) var isLeaving = false
    private let nodeID: NodeID

    init(spec: Transition, nodeID: NodeID) {
        self.spec = spec
        self.nodeID = nodeID
        // Starts absent, so a node that appears has somewhere to animate from.
        progress = Animated(0)
    }

    /// Anything other than fully present needs the emitter's help.
    var isTransitioning: Bool { progress.current < 0.999 }

    var alpha: Float { spec.fades ? max(0, min(1, progress.current)) : 1 }

    var translation: (x: Float, y: Float) {
        let away = 1 - max(0, min(1, progress.current))
        return (spec.offsetX * away, spec.offsetY * away)
    }

    func enter() {
        isLeaving = false
        progress.animate(to: 1, duration: spec.duration, curve: spec.curve)
        drive(onFinish: nil)
    }

    /// Animates out, calling `onFinish` once there is nothing left to draw.
    func leave(onFinish: @escaping () -> Void) {
        guard !isLeaving else { return }
        isLeaving = true
        progress.animate(to: 0, duration: spec.duration, curve: spec.curve)
        drive(onFinish: onFinish)
    }

    private func drive(onFinish: (() -> Void)?) {
        AnimationDriver.register(nodeID) { [weak self] in
            guard let self else { return false }
            let running = self.progress.step(FrameScheduler.now())
            if !running, let onFinish {
                // The node is invisible now, so dropping it is what finally
                // lets the layout close the gap. That needs a body pass —
                // a redraw would leave the hole.
                onFinish()
                ViewInvalidation.markNeedsBody()
            }
            return running
        }
        ViewInvalidation.markNeedsRedraw()
    }
}

/// `content.transition(...)`
///
/// Attaches to the content's own node where it can, exactly like
/// `ModifiedView`, so a transition costs no extra layout box unless the content
/// is a fragment with no single node to carry it.
public struct TransitionView<Content: View>: PrimitiveView {
    public var content: Content
    public var transition: Transition

    public init(content: Content, transition: Transition) {
        self.content = content
        self.transition = transition
    }

    public var dumpDetail: String { "transition" }

    public func structureLines(indent: Int = 0) -> [String] {
        Dump.structureLines(
            indent: indent, label: "Transition",
            childLines: [content.structureLines(indent: indent + 1)]
        )
    }

    public func mountPrimitive() -> any AnyViewNode {
        attach(to: ViewGraph.mount(content))
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        // Wrapper *we* created for fragment content — `label` is only ever
        // "Transition" via `attach`'s wrap branch below, so this can't fire
        // for a box some other modifier owns. `transitionState != nil` alone
        // used to be treated as proof we owned the box, which also holds for
        // one we merely attached state to without wrapping (still someone
        // else's box) — see the identical bug and fix in `AgentId.swift`.
        if let box = node as? StyleBoxNode, box.label == "Transition" {
            box.updateContent(ViewGraph.reconcile(box.contentNode, with: content))
            return box
        }
        return attach(to: ViewGraph.reconcile(node, with: content))
    }

    private func attach(to node: any AnyViewNode) -> any AnyViewNode {
        if let box = node as? YogaBoxNode {
            // Only on first sight. Re-creating it every reconcile would
            // restart the animation on every frame, which reads as the view
            // never arriving.
            if box.transitionState == nil {
                box.transitionState = TransitionState(spec: transition, nodeID: box.id)
            }
            return box
        }
        let wrapper = StyleBoxNode(content: node)
        wrapper.transitionState = TransitionState(spec: transition, nodeID: wrapper.id)
        wrapper.label = "Transition"
        return wrapper
    }
}

extension View {
    /// Animates this view appearing and disappearing.
    ///
    /// Only meaningful where a reconciler can actually insert or remove it: an
    /// `if`, an optional, or a `ForEach` row. On a view that is always present
    /// it animates in once, on first mount.
    public func transition(_ transition: Transition = .opacity) -> TransitionView<Self> {
        TransitionView(content: self, transition: transition)
    }
}

#endif
