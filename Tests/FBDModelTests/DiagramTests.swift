import XCTest

@testable import FBDModel

final class DiagramTests: XCTestCase {
    func testConnectSucceedsBetweenCompatibleSlots() throws {
        let diagram = Diagram()
        let input = diagram.addBlock(kind: .input, name: "INPUT_1", position: Point(x: 0, y: 0))
        let not = diagram.addBlock(kind: .not, name: "NOT_1", position: Point(x: 100, y: 0))

        let outSlot = diagram.blocks[input]!.outputs[0].id
        let inSlot = diagram.blocks[not]!.inputs[0].id

        let wireID = try diagram.connect(from: outSlot, to: inSlot)

        XCTAssertEqual(diagram.wires.count, 1)
        XCTAssertEqual(diagram.wires[wireID]?.from, outSlot)
        XCTAssertEqual(diagram.wires[wireID]?.to, inSlot)
    }

    func testConnectRejectsWrongDirection() {
        let diagram = Diagram()
        let a = diagram.addBlock(kind: .not, name: "NOT_1", position: Point(x: 0, y: 0))
        let b = diagram.addBlock(kind: .not, name: "NOT_2", position: Point(x: 100, y: 0))

        let aIn = diagram.blocks[a]!.inputs[0].id
        let bIn = diagram.blocks[b]!.inputs[0].id

        XCTAssertThrowsError(try diagram.connect(from: aIn, to: bIn)) { error in
            guard case DiagramError.wrongDirection(expected: .output, slot: aIn) = error else {
                return XCTFail("expected wrongDirection, got \(error)")
            }
        }
    }

    func testConnectRejectsSecondWireToSameInput() throws {
        let diagram = Diagram()
        let in1 = diagram.addBlock(kind: .input, name: "INPUT_1", position: Point(x: 0, y: 0))
        let in2 = diagram.addBlock(kind: .input, name: "INPUT_2", position: Point(x: 0, y: 50))
        let not = diagram.addBlock(kind: .not, name: "NOT_1", position: Point(x: 100, y: 0))

        let out1 = diagram.blocks[in1]!.outputs[0].id
        let out2 = diagram.blocks[in2]!.outputs[0].id
        let notIn = diagram.blocks[not]!.inputs[0].id

        try diagram.connect(from: out1, to: notIn)

        XCTAssertThrowsError(try diagram.connect(from: out2, to: notIn)) { error in
            guard case DiagramError.inputAlreadyConnected(notIn) = error else {
                return XCTFail("expected inputAlreadyConnected, got \(error)")
            }
        }
    }

    func testConnectRejectsTypeMismatch() {
        let diagram = Diagram()
        let input = diagram.addBlock(kind: .input, name: "INPUT_1", position: Point(x: 0, y: 0))
        let add = diagram.addBlock(kind: .add, name: "ADD_1", position: Point(x: 100, y: 0))

        // INPUT's output is .bool by default; ADD's inputs are .float.
        let boolOut = diagram.blocks[input]!.outputs[0].id
        let floatIn = diagram.blocks[add]!.inputs[0].id

        XCTAssertThrowsError(try diagram.connect(from: boolOut, to: floatIn)) { error in
            guard case DiagramError.typeMismatch(from: .bool, to: .float) = error else {
                return XCTFail("expected typeMismatch, got \(error)")
            }
        }
    }

    func testConnectRejectsSelfConnection() {
        let diagram = Diagram()
        // RS has both an input and an output, so it can plausibly wire to itself.
        let rs = diagram.addBlock(kind: .rsTrigger, name: "RS_1", position: Point(x: 0, y: 0))
        let out = diagram.blocks[rs]!.outputs[0].id
        let setIn = diagram.blocks[rs]!.inputs[0].id

        XCTAssertThrowsError(try diagram.connect(from: out, to: setIn)) { error in
            XCTAssertEqual(error as? DiagramError, .selfConnection)
        }
    }

    func testConnectRejectsCycle() throws {
        let diagram = Diagram()
        let a = diagram.addBlock(kind: .not, name: "NOT_1", position: Point(x: 0, y: 0))
        let b = diagram.addBlock(kind: .not, name: "NOT_2", position: Point(x: 100, y: 0))
        let c = diagram.addBlock(kind: .not, name: "NOT_3", position: Point(x: 200, y: 0))

        // a -> b -> c
        try diagram.connect(from: diagram.blocks[a]!.outputs[0].id, to: diagram.blocks[b]!.inputs[0].id)
        try diagram.connect(from: diagram.blocks[b]!.outputs[0].id, to: diagram.blocks[c]!.inputs[0].id)

        // c -> a would close the loop.
        XCTAssertThrowsError(
            try diagram.connect(from: diagram.blocks[c]!.outputs[0].id, to: diagram.blocks[a]!.inputs[0].id)
        ) { error in
            XCTAssertEqual(error as? DiagramError, .wouldCreateCycle)
        }
    }

    /// Mirrors a small piece of the reference app's FBD diagram:
    /// two inputs feed an AND, whose output (together with a third input)
    /// feeds an OR, whose output drives an OUTPUT terminal.
    func testExecutionOrderMatchesDataFlow() throws {
        let diagram = Diagram()
        let in1 = diagram.addBlock(kind: .input, name: "INPUT_1", position: Point(x: 0, y: 0))
        let in2 = diagram.addBlock(kind: .input, name: "INPUT_2", position: Point(x: 0, y: 50))
        let in3 = diagram.addBlock(kind: .input, name: "INPUT_3", position: Point(x: 0, y: 100))
        let and = diagram.addBlock(kind: .and, name: "AND_1", position: Point(x: 100, y: 0))
        let or = diagram.addBlock(kind: .or, name: "OR_1", position: Point(x: 200, y: 0))
        let out = diagram.addBlock(kind: .output, name: "OUTPUT_1", position: Point(x: 300, y: 0))

        try diagram.connect(from: diagram.blocks[in1]!.outputs[0].id, to: diagram.blocks[and]!.inputs[0].id)
        try diagram.connect(from: diagram.blocks[in2]!.outputs[0].id, to: diagram.blocks[and]!.inputs[1].id)
        try diagram.connect(from: diagram.blocks[and]!.outputs[0].id, to: diagram.blocks[or]!.inputs[0].id)
        try diagram.connect(from: diagram.blocks[in3]!.outputs[0].id, to: diagram.blocks[or]!.inputs[1].id)
        try diagram.connect(from: diagram.blocks[or]!.outputs[0].id, to: diagram.blocks[out]!.inputs[0].id)

        let order = try diagram.executionOrder()

        XCTAssertEqual(order.count, diagram.blocks.count)
        XCTAssertTrue(order.firstIndex(of: in1)! < order.firstIndex(of: and)!)
        XCTAssertTrue(order.firstIndex(of: in2)! < order.firstIndex(of: and)!)
        XCTAssertTrue(order.firstIndex(of: and)! < order.firstIndex(of: or)!)
        XCTAssertTrue(order.firstIndex(of: in3)! < order.firstIndex(of: or)!)
        XCTAssertTrue(order.firstIndex(of: or)! < order.firstIndex(of: out)!)
    }

    func testRemoveBlockDropsItsWires() throws {
        let diagram = Diagram()
        let input = diagram.addBlock(kind: .input, name: "INPUT_1", position: Point(x: 0, y: 0))
        let not = diagram.addBlock(kind: .not, name: "NOT_1", position: Point(x: 100, y: 0))
        try diagram.connect(from: diagram.blocks[input]!.outputs[0].id, to: diagram.blocks[not]!.inputs[0].id)

        XCTAssertEqual(diagram.wires.count, 1)

        diagram.removeBlock(input)

        XCTAssertNil(diagram.blocks[input])
        XCTAssertEqual(diagram.wires.count, 0)
    }
}
