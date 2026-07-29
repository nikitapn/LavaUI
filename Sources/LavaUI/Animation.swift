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

    func apply(_ t: Float) -> Float {
        switch self {
        case .linear: return t
        case .easeOut: return 1 - (1 - t) * (1 - t)
        case .easeInOut: return t < 0.5 ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t)
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
        let t = curve.apply(Float(max(0, elapsed / duration)))
        current = T.interpolate(origin, target, t)
        return true
    }
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

    /// Advances every registered animation. Anything still running asks for a
    /// wake and marks a **redraw** — not a body recompute, which is the whole
    /// point of the invalidation cascade.
    public static func tick() {
        guard !active.isEmpty else { return }
        var finished: [NodeID] = []
        var stillRunning = false

        for (id, step) in active {
            if step() {
                stillRunning = true
            } else {
                finished.append(id)
            }
        }
        for id in finished { active[id] = nil }

        ViewInvalidation.markNeedsRedraw()
        if stillRunning {
            // ~60fps while something is in flight; the loop sleeps otherwise.
            FrameScheduler.requestWake(in: 1.0 / 60.0)
        }
    }
}

#endif
