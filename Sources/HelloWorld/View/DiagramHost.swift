/// Reserves the center panel for the FBD diagram (flex-grow host).
public struct DiagramHost: PrimitiveView {
    public var flexGrow: Float

    public init(flexGrow: Float = 1) {
        self.flexGrow = flexGrow
    }

    public var dumpDetail: String { "flexGrow=\(flexGrow)" }
}
