/// Text label primitive (Phase 1: description only; no draw / hit-test yet).
public struct Text: PrimitiveView {
    public var string: String
    public var r: Float
    public var g: Float
    public var b: Float
    /// Stored for later phases; not invoked by dump.
    public var onClick: (() -> Void)?

    public init(
        _ string: String,
        r: Float = 0.90,
        g: Float = 0.90,
        b: Float = 0.90,
        onClick: (() -> Void)? = nil
    ) {
        self.string = string
        self.r = r
        self.g = g
        self.b = b
        self.onClick = onClick
    }

    public var dumpDetail: String {
        let click = onClick == nil ? "" : " onClick"
        return "\"\(string)\"\(click)"
    }
}
