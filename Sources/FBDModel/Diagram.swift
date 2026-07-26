/// The whole FBD graph: every placed block and every wire connecting them.
///
/// This is the "generic editor, not tied to a particular microcontroller"
/// layer — it only knows about blocks/slots/wires as data, with no
/// execution or code-generation baked in. What a diagram *means* on real
/// hardware (AVR, STM32, or none at all — a pure simulation) is entirely
/// up to whatever consumes it later.
public final class Diagram {
    public private(set) var blocks: [BlockID: Block] = [:]
    public private(set) var wires: [WireID: Wire] = [:]

    private var nextBlockID = 0
    private var nextSlotID = 0
    private var nextWireID = 0

    public init() {}

    // MARK: - Block management

    /// Places a new block of the given kind, using its default slot shape
    /// and configuration (see `BlockKind.defaultInputs`/`defaultOutputs`/
    /// `defaultProperties`).
    @discardableResult
    public func addBlock(kind: BlockKind, name: String, position: Point) -> BlockID {
        let blockID = BlockID(nextBlockID)
        nextBlockID += 1

        func makeSlots(_ specs: [SlotSpec], direction: Direction) -> [Slot] {
            specs.map { spec in
                defer { nextSlotID += 1 }
                return Slot(id: SlotID(nextSlotID), name: spec.name, type: spec.type, direction: direction)
            }
        }

        let block = Block(
            id: blockID,
            kind: kind,
            name: name,
            position: position,
            inputs: makeSlots(kind.defaultInputs, direction: .input),
            outputs: makeSlots(kind.defaultOutputs, direction: .output),
            properties: kind.defaultProperties
        )
        blocks[blockID] = block
        return blockID
    }

    /// Removes a block and every wire touching any of its slots.
    public func removeBlock(_ id: BlockID) {
        guard let block = blocks[id] else { return }
        let slotIDs = Set((block.inputs + block.outputs).map(\.id))
        let danglingWires = wires.values
            .filter { slotIDs.contains($0.from) || slotIDs.contains($0.to) }
            .map(\.id)
        for wireID in danglingWires {
            wires.removeValue(forKey: wireID)
        }
        blocks.removeValue(forKey: id)
    }

    // MARK: - Slot lookup

    private func find(_ slotID: SlotID) -> (block: Block, slot: Slot)? {
        for block in blocks.values {
            if let slot = block.slot(slotID) {
                return (block, slot)
            }
        }
        return nil
    }

    // MARK: - Wiring

    /// Connects an output slot to an input slot, after checking:
    /// - both slots exist and have the right direction,
    /// - they don't belong to the same block,
    /// - their types are compatible,
    /// - the input isn't already wired to something else,
    /// - adding the wire wouldn't create a cycle.
    @discardableResult
    public func connect(from: SlotID, to: SlotID) throws -> WireID {
        guard let (fromBlock, fromSlot) = find(from) else {
            throw DiagramError.slotNotFound(from)
        }
        guard let (toBlock, toSlot) = find(to) else {
            throw DiagramError.slotNotFound(to)
        }
        guard fromSlot.direction == .output else {
            throw DiagramError.wrongDirection(expected: .output, slot: from)
        }
        guard toSlot.direction == .input else {
            throw DiagramError.wrongDirection(expected: .input, slot: to)
        }
        guard fromBlock.id != toBlock.id else {
            throw DiagramError.selfConnection
        }
        guard fromSlot.type.isCompatible(with: toSlot.type) else {
            throw DiagramError.typeMismatch(from: fromSlot.type, to: toSlot.type)
        }
        guard !wires.values.contains(where: { $0.to == to }) else {
            throw DiagramError.inputAlreadyConnected(to)
        }
        guard !canReach(from: toBlock.id, to: fromBlock.id) else {
            throw DiagramError.wouldCreateCycle
        }

        let wireID = WireID(nextWireID)
        nextWireID += 1
        wires[wireID] = Wire(id: wireID, from: from, to: to)
        return wireID
    }

    public func disconnect(_ wireID: WireID) {
        wires.removeValue(forKey: wireID)
    }

    // MARK: - Graph queries

    /// Blocks fed directly by `blockID`'s outputs.
    private func downstreamBlocks(of blockID: BlockID) -> Set<BlockID> {
        guard let block = blocks[blockID] else { return [] }
        let outputSlotIDs = Set(block.outputs.map(\.id))
        var result = Set<BlockID>()
        for wire in wires.values where outputSlotIDs.contains(wire.from) {
            if let (toBlock, _) = find(wire.to) {
                result.insert(toBlock.id)
            }
        }
        return result
    }

    /// Blocks that feed directly into `blockID`'s inputs.
    private func upstreamBlocks(of blockID: BlockID) -> Set<BlockID> {
        guard let block = blocks[blockID] else { return [] }
        let inputSlotIDs = Set(block.inputs.map(\.id))
        var result = Set<BlockID>()
        for wire in wires.values where inputSlotIDs.contains(wire.to) {
            if let (fromBlock, _) = find(wire.from) {
                result.insert(fromBlock.id)
            }
        }
        return result
    }

    /// Depth-first reachability: can you get from `start` to `target` by
    /// following wires forward (output -> input -> owning block)?
    private func canReach(from start: BlockID, to target: BlockID) -> Bool {
        if start == target { return true }
        var visited = Set<BlockID>()
        var stack = [start]
        while let current = stack.popLast() {
            if current == target { return true }
            guard visited.insert(current).inserted else { continue }
            stack.append(contentsOf: downstreamBlocks(of: current))
        }
        return false
    }

    // MARK: - Execution order

    /// Topologically sorts the blocks (Kahn's algorithm) so every block
    /// appears after everything that feeds it. Blocks with no path between
    /// them come out in a stable but otherwise unspecified relative order.
    ///
    /// Mirrors what npsystem's `CFBDControlUnit::Translate` computes once
    /// per diagram to order code-gen output — this model doesn't generate
    /// code, but the same ordering is just as useful here for validating
    /// the diagram (a cycle here is almost certainly a mistake, and
    /// `connect` already refuses to create one directly — this catches any
    /// other way one might sneak in) and for showing users a scan order.
    public func executionOrder() throws -> [BlockID] {
        var inDegree: [BlockID: Int] = [:]
        for id in blocks.keys {
            inDegree[id] = upstreamBlocks(of: id).count
        }

        var queue = inDegree.filter { $0.value == 0 }.map(\.key)
        var order: [BlockID] = []

        while !queue.isEmpty {
            queue.sort { $0.rawValue < $1.rawValue }  // deterministic output
            let current = queue.removeFirst()
            order.append(current)

            for next in downstreamBlocks(of: current) {
                inDegree[next]! -= 1
                if inDegree[next] == 0 {
                    queue.append(next)
                }
            }
        }

        guard order.count == blocks.count else {
            throw DiagramError.cycleDetected
        }
        return order
    }
}
