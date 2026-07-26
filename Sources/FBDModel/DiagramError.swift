public enum DiagramError: Error, Equatable, Sendable {
    case blockNotFound(BlockID)
    case slotNotFound(SlotID)
    case wrongDirection(expected: Direction, slot: SlotID)
    case inputAlreadyConnected(SlotID)
    case typeMismatch(from: SignalType, to: SignalType)
    case selfConnection
    case wouldCreateCycle
    case cycleDetected
}

extension DiagramError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .blockNotFound(let id):
            return "no block with id \(id)"
        case .slotNotFound(let id):
            return "no slot with id \(id)"
        case .wrongDirection(let expected, let slot):
            return "slot \(slot) is not an \(expected) slot"
        case .inputAlreadyConnected(let slot):
            return "input slot \(slot) already has a wire connected to it"
        case .typeMismatch(let from, let to):
            return "cannot connect a \(from) output to a \(to) input"
        case .selfConnection:
            return "cannot connect a block to itself"
        case .wouldCreateCycle:
            return "this connection would create a cycle"
        case .cycleDetected:
            return "the diagram contains a cycle, so it has no valid execution order"
        }
    }
}

extension Direction: CustomStringConvertible {
    public var description: String {
        switch self {
        case .input: return "input"
        case .output: return "output"
        }
    }
}
