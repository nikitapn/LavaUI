/// Flex-grow filler.
public struct Spacer: PrimitiveView {
    public var flexGrow: Float

    public init(flexGrow: Float = 1) {
        self.flexGrow = flexGrow
    }

    public var dumpDetail: String { "flexGrow=\(flexGrow)" }
}
