/// A two-stop linear ramp, for `.background(_:)`.
///
/// Two stops rather than an arbitrary list, and linear rather than radial,
/// because that is what the renderer evaluates exactly: the ramp is computed
/// per vertex and interpolated across the quad, and a two-stop linear gradient
/// is the one family that survives that without error. Multi-stop and radial
/// would need the ramp evaluated per fragment, which is a different pipeline
/// rather than a longer array here.
///
/// Both stops carry their own alpha, so a fade to transparent is an ordinary
/// gradient with `to: .clear` rather than a separate mechanism.
public struct Gradient: Equatable, Sendable {
    public var from: Color
    public var to: Color
    /// Radians, from +x towards +y: 0 runs left to right, `.pi / 2` top to
    /// bottom. The ramp spans the box exactly whatever the angle and whatever
    /// the aspect ratio, so a 45° gradient looks like 45° on a wide box rather
    /// than being sheared by it.
    public var angle: Float

    public init(from: Color, to: Color, angle: Float = .pi / 2) {
        self.from = from
        self.to = to
        self.angle = angle
    }

    /// Top to bottom — the direction nearly every panel and header wants.
    public static func vertical(_ from: Color, _ to: Color) -> Gradient {
        Gradient(from: from, to: to, angle: .pi / 2)
    }

    /// Left to right.
    public static func horizontal(_ from: Color, _ to: Color) -> Gradient {
        Gradient(from: from, to: to, angle: 0)
    }
}
