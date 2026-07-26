/// Whether a slot is a block's input or output. The original C++ model
/// encoded this via subclassing (`CInputSlot`/`COutputSlot`); a plain enum
/// field is simpler in Swift and just as effective at the call sites that
/// matter (`Diagram.connect` checks it).
public enum Direction: Sendable {
    case input
    case output
}

/// Where a slot's value ultimately comes from/goes to. `.internal` slots
/// only ever get their value from a `Wire`; `.external` slots are bound to
/// something outside the diagram — a hardware pin, another controller's
/// output, a module register. The original C++ model split this into a
/// whole polymorphic `CSlotType` family per external-reference kind
/// (`CAvrInternalPin`, `CModuleValue`, ...); here it's collapsed to one
/// opaque, target-agnostic key, since deciding what that key *means* (an
/// AVR port pin vs. an STM32 GPIO vs. something else entirely) is a
/// concern for whatever code-gen/runtime backend consumes the diagram, not
/// for the editor itself.
public enum SlotSource: Hashable, Sendable {
    case internalWire
    case external(String)
}

/// A single named input or output pin on a `Block`.
public struct Slot: Identifiable, Sendable {
    public let id: SlotID
    public var name: String
    public var type: SignalType
    public var direction: Direction
    public var source: SlotSource

    public init(
        id: SlotID,
        name: String,
        type: SignalType,
        direction: Direction,
        source: SlotSource = .internalWire
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.direction = direction
        self.source = source
    }
}
