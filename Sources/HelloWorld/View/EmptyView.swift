/// Placeholder / terminator for builders and primitive bodies.
public struct EmptyView: PrimitiveView {
    public init() {}

    public var dumpDetail: String { "(empty)" }
}
