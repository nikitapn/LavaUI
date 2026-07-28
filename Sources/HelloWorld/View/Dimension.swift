/// Maps onto Yoga's three width/height states (not a single `-1` sentinel).
public enum Dimension: Equatable, Sendable, Hashable {
    /// Leave unspecified / `YGUndefined` — parent or content decides.
    case undefined
    /// `YGNodeStyleSetWidthAuto` / height auto.
    case auto
    /// Fixed point size in pixels.
    case point(Float)

    public static func pt(_ value: Float) -> Dimension { .point(value) }
}
