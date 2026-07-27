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

    /// Pushes diagram geometry into the editor in **diagram-local** coordinates
    /// (0,0 = top-left of the Yoga diagram panel).
    func renderDiagram(_ diagram: Diagram, into editor: Editor) {
        editor.clearShapes()
        editor.clearLines()
        editor.clearLabels()

        var slotPositions: [SlotID: (x: Float, y: Float)] = [:]

        for block in diagram.blocks.values.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            let width = FBDLayout.blockWidth
            let height = FBDLayout.blockHeight(for: block)
            let x = Float(block.position.x)
            let y = Float(block.position.y)

            editor.addRoundedRect(
                x: x, y: y, w: width, h: height,
                r: 0.20, g: 0.22, b: 0.30
            )
            editor.addLabel(block.name, x: x + 6, y: y + 16, r: 0.95, g: 0.95, b: 0.95)

            for (index, slot) in block.inputs.enumerated() {
                let position = (
                    x: x,
                    y: y + FBDLayout.headerHeight + Float(index) * FBDLayout.rowHeight
                        + FBDLayout.rowHeight / 2
                )
                slotPositions[slot.id] = position
                editor.addCircle(
                    cx: position.x, cy: position.y, radius: FBDLayout.portRadius,
                    r: 0.9, g: 0.7, b: 0.2
                )
                editor.addLabel(slot.name, x: x + 10, y: position.y + 4, r: 0.8, g: 0.8, b: 0.8)
            }

            for (index, slot) in block.outputs.enumerated() {
                let position = (
                    x: x + width,
                    y: y + FBDLayout.headerHeight + Float(index) * FBDLayout.rowHeight
                        + FBDLayout.rowHeight / 2
                )
                slotPositions[slot.id] = position
                editor.addCircle(
                    cx: position.x, cy: position.y, radius: FBDLayout.portRadius,
                    r: 0.3, g: 0.8, b: 0.9
                )
            }
        }

        for wire in diagram.wires.values {
            guard let from = slotPositions[wire.from], let to = slotPositions[wire.to] else {
                continue
            }
            editor.addLine(
                x1: from.x, y1: from.y, x2: to.x, y2: to.y,
                r: 0.85, g: 0.85, b: 0.85
            )
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
