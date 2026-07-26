/// A block placed on the diagram: an instance of a `BlockKind` with its own
/// position, slots, and configuration values.
public struct Block: Identifiable, Sendable {
    public let id: BlockID
    public var kind: BlockKind
    /// User-assigned instance name, e.g. "AND_1", "DELAY_1" — matches the
    /// reference app's per-instance naming convention.
    public var name: String
    /// Top-left corner. Purely for the editor's benefit; nothing in this
    /// model reads it.
    public var position: Point
    public var inputs: [Slot]
    public var outputs: [Slot]
    public var properties: [String: PropertyValue]

    public init(
        id: BlockID,
        kind: BlockKind,
        name: String,
        position: Point,
        inputs: [Slot],
        outputs: [Slot],
        properties: [String: PropertyValue] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.position = position
        self.inputs = inputs
        self.outputs = outputs
        self.properties = properties
    }

    /// Finds a slot (input or output) by id.
    public func slot(_ id: SlotID) -> Slot? {
        inputs.first(where: { $0.id == id }) ?? outputs.first(where: { $0.id == id })
    }
}
