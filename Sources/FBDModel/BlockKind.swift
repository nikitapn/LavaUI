/// The name and type of a slot a freshly-created block should start with,
/// before it has a real `SlotID` (that gets assigned when a `Diagram`
/// actually instantiates the block — see `Diagram.addBlock(kind:...)`).
public struct SlotSpec: Sendable {
    public let name: String
    public let type: SignalType

    public init(_ name: String, _ type: SignalType) {
        self.name = name
        self.type = type
    }
}

/// Every block type the editor knows how to place, matching npsystem's
/// `NPSYSTEM_BLOCKS()` catalog (`blockdecl.h`) one-for-one so existing
/// diagrams/knowledge carry over, but with no AVR-specific assumptions
/// baked in anywhere — this editor is meant to target multiple
/// microcontroller families (AVR today, STM32 later), so "how a block's
/// logic actually gets executed" is entirely a concern for a future
/// code-gen backend, not this model.
public enum BlockKind: String, CaseIterable, Sendable {
    case input, output

    // Logic
    case and, or, not, rsTrigger
    case binaryEncoder, binaryDecoder
    case positiveEdge, negativeEdge, anyEdge
    case delay, time, schedule, counter, pulse

    // Math
    case add, subtract, multiply, divide
    case comparator, function

    // Alarm
    case alarmHigh, alarmLow

    // Control
    case pid
}

extension BlockKind {
    /// The label shown in the block's header (matches the reference app's
    /// "AND"/"OR"/"NOT"/"RS"/"DELAY" etc.).
    public var displayName: String {
        switch self {
        case .input: return "INPUT"
        case .output: return "OUTPUT"
        case .and: return "AND"
        case .or: return "OR"
        case .not: return "NOT"
        case .rsTrigger: return "RS"
        case .binaryEncoder: return "BE"
        case .binaryDecoder: return "BD"
        case .positiveEdge: return "PE"
        case .negativeEdge: return "NE"
        case .anyEdge: return "AE"
        case .delay: return "DELAY"
        case .time: return "TIME"
        case .schedule: return "SCHEDULE"
        case .counter: return "COUNTER"
        case .pulse: return "PULSE"
        case .add: return "ADD"
        case .subtract: return "SUB"
        case .multiply: return "MUL"
        case .divide: return "DIV"
        case .comparator: return "CMP"
        case .function: return "FUNCTION"
        case .alarmHigh: return "ALARM_HIGH"
        case .alarmLow: return "ALARM_LOW"
        case .pid: return "PID"
        }
    }

    /// Input slots a freshly-placed block of this kind starts with.
    ///
    /// A few of these (`binaryEncoder`/`binaryDecoder`/`time`/`schedule`/
    /// `counter`/`pulse`/`pid`'s gains) are best-guess defaults — the
    /// research this is based on confirmed exact shapes for `and`/`or`/
    /// `not`/`rsTrigger`/`delay`/`alarmLow` (all visible directly in the
    /// reference screenshot) but not every one of the 25; adjust these
    /// once you're ready to nail down the less common ones.
    public var defaultInputs: [SlotSpec] {
        switch self {
        case .input: return []
        case .output: return [SlotSpec("IN", .bool)]
        case .and, .or: return [SlotSpec("IN_1", .bool), SlotSpec("IN_2", .bool)]
        case .not: return [SlotSpec("IN", .bool)]
        case .rsTrigger: return [SlotSpec("SET", .bool), SlotSpec("RESET", .bool)]
        case .binaryEncoder: return (0..<8).map { SlotSpec("IN_\($0)", .bool) }
        case .binaryDecoder: return [SlotSpec("IN", .int(bits: 8, signed: false))]
        case .positiveEdge, .negativeEdge, .anyEdge: return [SlotSpec("IN", .bool)]
        case .delay: return [SlotSpec("IN", .bool)]
        case .time: return []
        case .schedule: return []
        case .counter: return [SlotSpec("COUNT", .bool), SlotSpec("RESET", .bool)]
        case .pulse: return [SlotSpec("IN", .bool)]
        case .add, .subtract, .multiply, .divide:
            return [SlotSpec("IN_1", .float), SlotSpec("IN_2", .float)]
        case .comparator: return [SlotSpec("IN_1", .float), SlotSpec("IN_2", .float)]
        case .function: return [SlotSpec("IN", .float)]
        case .alarmHigh, .alarmLow: return [SlotSpec("IN", .float), SlotSpec("L", .float)]
        case .pid: return [SlotSpec("SP", .float), SlotSpec("PV", .float)]
        }
    }

    /// Output slots a freshly-placed block of this kind starts with.
    public var defaultOutputs: [SlotSpec] {
        switch self {
        case .input: return [SlotSpec("OUT", .bool)]
        case .output: return []
        case .and, .or, .not, .rsTrigger: return [SlotSpec("OUT", .bool)]
        case .binaryEncoder: return [SlotSpec("OUT", .int(bits: 8, signed: false))]
        case .binaryDecoder: return (0..<8).map { SlotSpec("OUT_\($0)", .bool) }
        case .positiveEdge, .negativeEdge, .anyEdge: return [SlotSpec("OUT", .bool)]
        case .delay: return [SlotSpec("OUT", .bool)]
        case .time: return [SlotSpec("OUT", .int(bits: 32, signed: false))]
        case .schedule: return [SlotSpec("OUT", .bool)]
        case .counter: return [SlotSpec("OUT", .int(bits: 32, signed: false))]
        case .pulse: return [SlotSpec("OUT", .bool)]
        case .add, .subtract, .multiply, .divide: return [SlotSpec("OUT", .float)]
        case .comparator: return [SlotSpec("OUT", .bool)]
        case .function: return [SlotSpec("OUT", .float)]
        case .alarmHigh, .alarmLow: return [SlotSpec("OUT", .bool)]
        case .pid: return [SlotSpec("CV", .float)]
        }
    }

    /// Configuration values a freshly-placed block of this kind starts
    /// with (e.g. `DELAY`'s `timeout`, matching the reference app's
    /// "Timeout 120000" field).
    public var defaultProperties: [String: PropertyValue] {
        switch self {
        case .delay: return ["timeout": .int(1000)]
        case .comparator: return ["operator": .string(">")]
        case .function: return ["expression": .string("")]
        case .pid: return ["kp": .double(1.0), "ki": .double(0.0), "kd": .double(0.0)]
        case .schedule: return ["schedule": .string("")]
        default: return [:]
        }
    }
}
