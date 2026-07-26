import FBDModel

#if canImport(CanvasKit)
    import CanvasKit

    /// Fixed layout constants for drawing a `Diagram` onto a `CanvasEngine`.
    /// A block's width is fixed; its height grows with however many
    /// input/output slots it has. `Block.position` is treated as the
    /// top-left corner, matching every other shape's convention in
    /// CanvasEngine.
    private enum FBDLayout {
        static let blockWidth = 130.0
        static let headerHeight = 22.0
        static let rowHeight = 18.0
        static let bottomPadding = 8.0
        static let portRadius = 5.0

        static func blockHeight(for block: Block) -> Double {
            let rows = max(block.inputs.count, block.outputs.count, 1)
            return headerHeight + Double(rows) * rowHeight + bottomPadding
        }
    }

    /// Renders a `Diagram` onto `engine`'s retained scene and repaints.
    ///
    /// Slot positions aren't part of the data model (see the note on
    /// `Wire`) — they're derived here, purely from each block's position
    /// and its slot's index within `inputs`/`outputs`, then used both to
    /// draw the ports themselves and to route wires between them.
    ///
    /// Ports are drawn centered *outside* each block's bounding box (at
    /// x, and x+width, not clamped inside it). That's not just cosmetic:
    /// GeometryRenderer draws every frame's Circles before its Rectangles/
    /// RoundedRectangles (see GeometryRenderer::Type's declaration order),
    /// so a port circle overlapping a block would get painted over by the
    /// block body. Keeping ports outside the block sidesteps that
    /// draw-order dependency entirely rather than fighting it.
    func renderDiagram(_ diagram: Diagram, into engine: CanvasEngine) {
        engine.clearShapes()
        engine.clearLines()
        engine.clearLabels()

        var slotPositions: [SlotID: (x: Double, y: Double)] = [:]

        for block in diagram.blocks.values.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            let width = FBDLayout.blockWidth
            let height = FBDLayout.blockHeight(for: block)
            let x = block.position.x
            let y = block.position.y

            engine.addRoundedRect(
                x: x, y: y, width: width, height: height,
                r: 0.20, g: 0.22, b: 0.30
            )
            engine.addLabel(block.name, x: x + 6, y: y + 16, r: 0.95, g: 0.95, b: 0.95)

            for (index, slot) in block.inputs.enumerated() {
                let position = (
                    x: x,
                    y: y + FBDLayout.headerHeight + Double(index) * FBDLayout.rowHeight + FBDLayout.rowHeight / 2
                )
                slotPositions[slot.id] = position
                engine.addCircle(
                    centerX: position.x, centerY: position.y, radius: FBDLayout.portRadius,
                    r: 0.9, g: 0.7, b: 0.2
                )
                engine.addLabel(slot.name, x: x + 10, y: position.y + 4, r: 0.8, g: 0.8, b: 0.8)
            }

            for (index, slot) in block.outputs.enumerated() {
                let position = (
                    x: x + width,
                    y: y + FBDLayout.headerHeight + Double(index) * FBDLayout.rowHeight + FBDLayout.rowHeight / 2
                )
                slotPositions[slot.id] = position
                engine.addCircle(
                    centerX: position.x, centerY: position.y, radius: FBDLayout.portRadius,
                    r: 0.3, g: 0.8, b: 0.9
                )
            }
        }

        for wire in diagram.wires.values {
            guard let from = slotPositions[wire.from], let to = slotPositions[wire.to] else { continue }
            engine.addLine(
                x1: from.x, y1: from.y, x2: to.x, y2: to.y,
                r: 0.85, g: 0.85, b: 0.85
            )
        }

        engine.repaint()
    }

    /// A small sample diagram to render until there's an actual editor UI:
    /// two inputs feed an AND, whose output (together with a third input)
    /// feeds an OR, whose output drives an OUTPUT terminal — the same
    /// shape as `DiagramTests.testExecutionOrderMatchesDataFlow`.
    func makeSampleDiagram() -> Diagram {
        let diagram = Diagram()

        let in1 = diagram.addBlock(kind: .input, name: "INPUT_1", position: Point(x: 20, y: 20))
        let in2 = diagram.addBlock(kind: .input, name: "INPUT_2", position: Point(x: 20, y: 100))
        let in3 = diagram.addBlock(kind: .input, name: "INPUT_3", position: Point(x: 20, y: 180))
        let and = diagram.addBlock(kind: .and, name: "AND_1", position: Point(x: 220, y: 50))
        let or = diagram.addBlock(kind: .or, name: "OR_1", position: Point(x: 420, y: 90))
        let out = diagram.addBlock(kind: .output, name: "OUTPUT_1", position: Point(x: 620, y: 110))

        _ = try? diagram.connect(from: diagram.blocks[in1]!.outputs[0].id, to: diagram.blocks[and]!.inputs[0].id)
        _ = try? diagram.connect(from: diagram.blocks[in2]!.outputs[0].id, to: diagram.blocks[and]!.inputs[1].id)
        _ = try? diagram.connect(from: diagram.blocks[and]!.outputs[0].id, to: diagram.blocks[or]!.inputs[0].id)
        _ = try? diagram.connect(from: diagram.blocks[in3]!.outputs[0].id, to: diagram.blocks[or]!.inputs[1].id)
        _ = try? diagram.connect(from: diagram.blocks[or]!.outputs[0].id, to: diagram.blocks[out]!.inputs[0].id)

        return diagram
    }
#endif
