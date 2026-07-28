import FBDModel

#if canImport(CxxCanvas)

private enum FBDLayout {
    static let blockWidth: Float = 130
    static let headerHeight: Float = 22
    static let rowHeight: Float = 18
    static let bottomPadding: Float = 8
    static let portRadius: Float = 5

    static func blockHeight(for block: Block) -> Float {
        let rows = max(block.inputs.count, block.outputs.count, 1)
        return headerHeight + Float(rows) * rowHeight + bottomPadding
    }
}

/// Emit FBD geometry into a draw list in **window** coordinates
/// (diagram-local + host origin).
func emitDiagram(
    _ diagram: Diagram,
    into list: DrawList,
    hostX: Float,
    hostY: Float
) {
    var slotPositions: [SlotID: (x: Float, y: Float)] = [:]

    let blockFill = Color(r: 0.20, g: 0.22, b: 0.30)
    let labelColor = Color(r: 0.95, g: 0.95, b: 0.95)
    let portIn = Color(r: 0.9, g: 0.7, b: 0.2)
    let portOut = Color(r: 0.3, g: 0.8, b: 0.9)
    let wire = Color(r: 0.85, g: 0.85, b: 0.85)
    let slotLabel = Color(r: 0.8, g: 0.8, b: 0.8)

    for block in diagram.blocks.values.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
        let width = FBDLayout.blockWidth
        let height = FBDLayout.blockHeight(for: block)
        let x = hostX + Float(block.position.x)
        let y = hostY + Float(block.position.y)

        list.roundedRect(x: x, y: y, w: width, h: height, color: blockFill, radius: 4)
        list.text(block.name, x: x + 6, y: y + 2, w: width - 12, h: 20, color: labelColor)

        for (index, slot) in block.inputs.enumerated() {
            let px = x
            let py = y + FBDLayout.headerHeight + Float(index) * FBDLayout.rowHeight
                + FBDLayout.rowHeight / 2
            slotPositions[slot.id] = (px, py)
            list.circle(cx: px, cy: py, radius: FBDLayout.portRadius, color: portIn)
            list.text(slot.name, x: x + 10, y: py - 8, w: 80, h: 16, color: slotLabel)
        }

        for (index, slot) in block.outputs.enumerated() {
            let px = x + width
            let py = y + FBDLayout.headerHeight + Float(index) * FBDLayout.rowHeight
                + FBDLayout.rowHeight / 2
            slotPositions[slot.id] = (px, py)
            list.circle(cx: px, cy: py, radius: FBDLayout.portRadius, color: portOut)
        }
    }

    for wireLink in diagram.wires.values {
        guard let from = slotPositions[wireLink.from], let to = slotPositions[wireLink.to] else {
            continue
        }
        list.line(x1: from.x, y1: from.y, x2: to.x, y2: to.y, color: wire)
    }
}

func makeSampleDiagram() -> Diagram {
    let diagram = Diagram()

    let in1 = diagram.addBlock(kind: .input, name: "INPUT_1", position: Point(x: 20, y: 20))
    let in2 = diagram.addBlock(kind: .input, name: "INPUT_2", position: Point(x: 20, y: 100))
    let in3 = diagram.addBlock(kind: .input, name: "INPUT_3", position: Point(x: 20, y: 180))
    let and = diagram.addBlock(kind: .and, name: "AND_1", position: Point(x: 220, y: 50))
    let or = diagram.addBlock(kind: .or, name: "OR_1", position: Point(x: 420, y: 90))
    let out = diagram.addBlock(kind: .output, name: "OUTPUT_1", position: Point(x: 620, y: 110))

    _ = try? diagram.connect(
        from: diagram.blocks[in1]!.outputs[0].id,
        to: diagram.blocks[and]!.inputs[0].id
    )
    _ = try? diagram.connect(
        from: diagram.blocks[in2]!.outputs[0].id,
        to: diagram.blocks[and]!.inputs[1].id
    )
    _ = try? diagram.connect(
        from: diagram.blocks[and]!.outputs[0].id,
        to: diagram.blocks[or]!.inputs[0].id
    )
    _ = try? diagram.connect(
        from: diagram.blocks[in3]!.outputs[0].id,
        to: diagram.blocks[or]!.inputs[1].id
    )
    _ = try? diagram.connect(
        from: diagram.blocks[or]!.outputs[0].id,
        to: diagram.blocks[out]!.inputs[0].id
    )

    return diagram
}

#endif
