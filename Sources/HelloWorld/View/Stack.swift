/// Horizontal flex row. Stores `Content` directly (`Body == Never`).
public struct HStack<Content: View>: PrimitiveView {
    public var flexGrow: Float
    public var width: Float
    public var height: Float
    public var padding: Float
    public var content: Content

    public init(
        flexGrow: Float = 0,
        width: Float = -1,
        height: Float = -1,
        padding: Float = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.flexGrow = flexGrow
        self.width = width
        self.height = height
        self.padding = padding
        self.content = content()
    }

    public var dumpDetail: String {
        "flexGrow=\(flexGrow) w=\(width) h=\(height) pad=\(padding)"
    }

    public func structureLines(indent: Int = 0) -> [String] {
        let pad = String(repeating: "  ", count: indent)
        var lines = ["\(pad)HStack \(dumpDetail)"]
        lines += content.structureLines(indent: indent + 1)
        return lines
    }
}

/// Vertical flex column. Stores `Content` directly (`Body == Never`).
public struct VStack<Content: View>: PrimitiveView {
    public var flexGrow: Float
    public var width: Float
    public var height: Float
    public var padding: Float
    public var content: Content

    public init(
        flexGrow: Float = 0,
        width: Float = -1,
        height: Float = -1,
        padding: Float = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.flexGrow = flexGrow
        self.width = width
        self.height = height
        self.padding = padding
        self.content = content()
    }

    public var dumpDetail: String {
        "flexGrow=\(flexGrow) w=\(width) h=\(height) pad=\(padding)"
    }

    public func structureLines(indent: Int = 0) -> [String] {
        let pad = String(repeating: "  ", count: indent)
        var lines = ["\(pad)VStack \(dumpDetail)"]
        lines += content.structureLines(indent: indent + 1)
        return lines
    }
}
