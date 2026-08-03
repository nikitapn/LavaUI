#if canImport(CxxCanvas)
import Foundation

/// A value that can be interpolated between two endpoints.
public protocol Animatable {
    static func interpolate(_ from: Self, _ to: Self, _ t: Float) -> Self
}

extension Float: Animatable {
    public static func interpolate(_ from: Float, _ to: Float, _ t: Float) -> Float {
        from + (to - from) * t
    }
}

extension Color: Animatable {
    public static func interpolate(_ from: Color, _ to: Color, _ t: Float) -> Color {
        Color(
            r: from.r + (to.r - from.r) * t,
            g: from.g + (to.g - from.g) * t,
            b: from.b + (to.b - from.b) * t,
            a: from.a + (to.a - from.a) * t
        )
    }
}

public enum AnimationCurve: Equatable, Sendable {
    case linear
    /// Fast out, settling in — the right default for a press or hover, where
    /// the response should feel immediate and the settle should not.
    case easeOut
    case easeInOut
    /// A damped harmonic response. `response` is the undamped period in
    /// seconds; lower values react faster. Values below one for
    /// `dampingFraction` overshoot, one is critically damped, and values above
    /// one settle without overshoot.
    case spring(response: Double, dampingFraction: Double)

    func apply(_ t: Float, duration: Double = 1) -> Float {
        switch self {
        case .linear: return t
        case .easeOut: return 1 - (1 - t) * (1 - t)
        case .easeInOut: return t < 0.5 ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t)
        case .spring(let response, let dampingFraction):
            let response = max(0.01, response)
            let damping = max(0.01, dampingFraction)
            let elapsed = Double(t) * duration
            let omega = 2 * Double.pi / response
            if damping < 1 {
                let root = sqrt(1 - damping * damping)
                let phase = omega * root * elapsed
                let envelope = exp(-damping * omega * elapsed)
                return Float(1 - envelope * (
                    cos(phase) + damping / root * sin(phase)
                ))
            }
            if damping == 1 {
                return Float(1 - exp(-omega * elapsed) * (1 + omega * elapsed))
            }
            let root = sqrt(damping * damping - 1)
            let slow = -omega * (damping - root)
            let fast = -omega * (damping + root)
            let slowWeight = (damping + root) / (2 * root)
            let fastWeight = -(damping - root) / (2 * root)
            return Float(1 - slowWeight * exp(slow * elapsed)
                - fastWeight * exp(fast * elapsed))
        }
    }
}

/// A property that moves toward a target over time.
///
/// Lives on the **node**, not in a view. Views are rebuilt every frame and
/// carry no identity; nodes persist, already own visual state like `fillColor`
/// and `scrollOffset`, and can therefore interpolate without re-running a
/// single `body`. Driving animation from the view side would recompute the
/// whole tree — `Mirror`-based state transplant included — sixty times a second
/// to change a colour.
public struct Animated<T: Animatable> {
    public private(set) var current: T
    public private(set) var target: T
    private var origin: T
    private var startedAt: Double = 0
    private var duration: Double = 0
    private var curve: AnimationCurve = .easeOut

    public init(_ value: T) {
        current = value
        target = value
        origin = value
    }

    public var isAnimating: Bool { duration > 0 }

    /// Starts moving toward `value`. Retargeting mid-flight restarts from
    /// wherever the value currently is, so an interrupted animation continues
    /// smoothly rather than jumping back to its original start.
    public mutating func animate(
        to value: T, duration seconds: Double = 0.12, curve: AnimationCurve = .easeOut
    ) {
        guard seconds > 0 else { return snap(to: value) }
        origin = current
        target = value
        startedAt = FrameScheduler.now()
        duration = seconds
        self.curve = curve
    }

    /// Jumps immediately, cancelling any animation in flight.
    public mutating func snap(to value: T) {
        current = value
        target = value
        origin = value
        duration = 0
    }

    /// Advances to `now`. Returns true while still animating.
    public mutating func step(_ now: Double) -> Bool {
        guard duration > 0 else { return false }
        let elapsed = now - startedAt
        if elapsed >= duration {
            current = target
            duration = 0
            return false
        }
        let t = curve.apply(Float(max(0, elapsed / duration)), duration: duration)
        current = T.interpolate(origin, target, t)
        return true
    }
}

/// Which nodes actually painted on the most recent `DrawList.emitTree()`
/// pass — the source of truth `AnimationDriver` consults to stop paying for
/// nodes nobody can currently see: scrolled out of a `ScrollView`, behind a
/// collapsed `Expand`, or covered by an overlay.
///
/// Rebuilt from scratch every `emitTree()` rather than written as a flag on
/// the node itself, because the cheap subtree-skip in `DrawList` (a
/// container failing its cull check returns before visiting any of its
/// children) means a culled node's descendants are never visited at all
/// that frame — a flag only ever written by visited nodes would stay stale
/// at whatever it last saw, exactly the case this exists to catch. Absence
/// this frame *is* "not visible", not "unknown".
enum NodeVisibility {
    nonisolated(unsafe) private static var visible: Set<NodeID> = []

    static func beginFrame() { visible.removeAll(keepingCapacity: true) }
    static func mark(_ id: NodeID) { visible.insert(id) }

    /// One frame stale by construction: `AnimationDriver.tick()` runs before
    /// `emitTree()` in the loop, so this reflects the previous frame's cull
    /// result, not the one about to be drawn. Harmless — worst case a node
    /// ticks one extra frame after leaving the screen, or resumes one frame
    /// late after returning to it.
    static func isVisible(_ id: NodeID) -> Bool { visible.contains(id) }
}

/// Steps every node with animation in flight, once per frame.
///
/// A registry rather than a tree walk: only animating nodes are visited, so an
/// idle window does no work at all and a single animating button does not cost
/// a traversal of the whole tree.
public enum AnimationDriver {
    /// Steppers keyed by node, returning whether that node is still animating.
    nonisolated(unsafe) private static var active: [NodeID: () -> Bool] = [:]

    public static func register(_ id: NodeID, step: @escaping () -> Bool) {
        active[id] = step
        // Registering has to ask for the next frame itself, because `tick()`
        // runs before `renderFrame` in the loop — anything that starts an
        // animation during mount or reconcile, which is where transitions
        // start, has already missed this frame's tick. Without this the loop
        // blocks in `pumpEvents` and the animation stays frozen at its first
        // value until some unrelated input happens to wake it.
        FrameScheduler.requestWake(in: 1.0 / 60.0)
    }

    public static func unregister(_ id: NodeID) { active[id] = nil }

    public static var isAnimating: Bool { !active.isEmpty }

    /// Call once after a frame has emitted, i.e. after `NodeVisibility` was
    /// just refreshed. `tick()` reads visibility captured *before* that same
    /// frame's `emitTree` — one iteration stale by design — so a node whose
    /// box just scrolled, resized, or expanded into view has no wake queued
    /// yet: the `tick()` earlier this same iteration still saw it as
    /// off-screen and correctly asked for nothing. Without this, such a node
    /// stays frozen until some unrelated input happens to wake the loop,
    /// rather than resuming on its own next frame. A no-op once nothing is
    /// registered, and otherwise just re-arms the same 60fps wake `tick()`
    /// would have asked for had it seen current visibility — it does not
    /// step or mark redraw itself, so an actually-still-invisible node costs
    /// nothing beyond one harmless extra wake that `tick()` immediately
    /// suppresses again.
    public static func requestRevisibilityCheck() {
        guard !active.isEmpty else { return }
        FrameScheduler.requestWake(in: 1.0 / 60.0)
    }

    /// Advances every registered animation. Everything still gets stepped —
    /// cheap, and it is what lets a `[weak self]` stepper on a since-deallocated
    /// node reap itself out of `active` even while its node was invisible — but
    /// only a *visible* node's progress justifies a redraw and another 60fps
    /// wake. A `Canvas(continuousRedraw: true)` scrolled out of view, or
    /// collapsed behind an `Expand`, otherwise never stops asking for one:
    /// its own stepper has no notion of "am I on screen", only of the state
    /// the widget handed it (playing/not playing).
    public static func tick() {
        guard !active.isEmpty else { return }
        var finished: [NodeID] = []
        var visibleActive = false
        var stillRunning = false

        for (id, step) in active {
            let visible = NodeVisibility.isVisible(id)
            if visible { visibleActive = true }
            if step() {
                if visible { stillRunning = true }
            } else {
                finished.append(id)
            }
        }
        for id in finished { active[id] = nil }

        if visibleActive {
            ViewInvalidation.markNeedsRedraw()
        }
        if stillRunning {
            // ~60fps while something visible is in flight; the loop sleeps
            // otherwise — including while every registrant is off-screen.
            FrameScheduler.requestWake(in: 1.0 / 60.0)
        }
    }
}

#endif
