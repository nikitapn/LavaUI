/// Identifies a `Block` within a `Diagram`. Distinct types for block/slot/
/// wire ids so they can't be mixed up at the call site, even though all
/// three happen to wrap a plain `Int` underneath.
public struct BlockID: Hashable, Sendable {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
}

/// Identifies a `Slot` (a single named input or output pin on a block).
/// Unique across the whole diagram, not just within one block.
public struct SlotID: Hashable, Sendable {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
}

/// Identifies a `Wire` connecting one output slot to one input slot.
public struct WireID: Hashable, Sendable {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
}

extension BlockID: CustomStringConvertible {
    public var description: String { "Block#\(rawValue)" }
}
extension SlotID: CustomStringConvertible {
    public var description: String { "Slot#\(rawValue)" }
}
extension WireID: CustomStringConvertible {
    public var description: String { "Wire#\(rawValue)" }
}
