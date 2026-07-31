/// Maps onto Yoga's width/height states (not a single `-1` sentinel).
public enum Dimension: Equatable, Sendable, Hashable {
    /// Leave unspecified / `YGUndefined` — parent or content decides.
    case undefined
    /// `YGNodeStyleSetWidthAuto` / height auto.
    case auto
    /// Fixed point size in pixels.
    case point(Float)
    /// `YGNodeStyleSetWidthPercent` / height percent, 0–100, of the
    /// containing block — a split workspace panel that should stay 38% of
    /// the window rather than a fixed point width, still shrinkable no
    /// further than whatever `minWidth`/`minHeight` says separately.
    case percent(Float)

    public static func pt(_ value: Float) -> Dimension { .point(value) }
    public static func pct(_ value: Float) -> Dimension { .percent(value) }
}
