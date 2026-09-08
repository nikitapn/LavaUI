import Foundation
import Testing

@testable import LavaShotCore

// The arithmetic a screenshot tool gets wrong, none of which is visible by
// looking at a screenshot of it.

@Suite("Selection geometry")
struct GeometryTests {
    @Test("A drag in any direction is the same rectangle")
    func dragDirection() {
        let a = ShotPoint(x: 100, y: 80)
        let b = ShotPoint(x: 40, y: 20)
        // Up and to the left is how you select something above where you
        // started, and it is the direction that produces negative width if
        // nobody normalises it.
        #expect(ShotRect.between(a, b) == ShotRect.between(b, a))
        #expect(ShotRect.between(a, b) == ShotRect(x: 40, y: 20, w: 60, h: 60))
    }

    @Test("A drag off the screen keeps the part that was on it")
    func clamping() {
        let screen = ShotRect(x: 0, y: 0, w: 1000, h: 800)
        let flicked = ShotRect(x: -200, y: 700, w: 500, h: 400)
        #expect(flicked.clamped(to: screen) == ShotRect(x: 0, y: 700, w: 300, h: 100))
    }

    @Test("A rectangle entirely off the screen clamps to nothing")
    func clampingAway() {
        let screen = ShotRect(x: 0, y: 0, w: 100, h: 100)
        let gone = ShotRect(x: 200, y: 200, w: 50, h: 50)
        #expect(gone.clamped(to: screen).isEmpty)
    }

    @Test("Moving a selection keeps its size and stays on screen")
    func moving() {
        let screen = ShotRect(x: 0, y: 0, w: 1000, h: 800)
        let region = ShotRect(x: 900, y: 700, w: 200, h: 200)
        let moved = region.moved(dx: 500, dy: 500, within: screen)
        #expect(moved.w == 200 && moved.h == 200)
        #expect(moved.maxX <= 1000.001 && moved.maxY <= 800.001)
    }

    @Test("Rounding goes outwards, so a lined-up edge is not shaved off")
    func rounding() {
        let region = ShotRect(x: 10.4, y: 20.7, w: 100.2, h: 50.9)
        let out = region.rounded
        #expect(out.x == 10 && out.y == 20)
        #expect(out.maxX >= region.maxX && out.maxY >= region.maxY)
    }

    @Test("Layout units scale to framebuffer pixels")
    func scaling() {
        let region = ShotRect(x: 10, y: 20, w: 100, h: 50)
        #expect(region.scaled(by: 2) == ShotRect(x: 20, y: 40, w: 200, h: 100))
    }
}

@Suite("Annotations")
struct DocumentTests {
    private func stroke(
        _ tool: ShotTool, from: ShotPoint, to: ShotPoint
    ) -> ShotStroke {
        ShotStroke(
            tool: tool, color: ShotColor.palette[0], width: 4,
            points: [from, to]
        )
    }

    @Test("A click that did not move is not a mark")
    func degenerate() {
        var document = ShotDocument()
        let point = ShotPoint(x: 50, y: 50)
        document.add(stroke(.rectangle, from: point, to: point))
        #expect(document.isEmpty)
        // Somebody changing their mind should not leave an invisible
        // zero-sized rectangle behind that undo then has to eat.
        #expect(!document.canUndo)
    }

    @Test("A pen stroke of one point is not a mark either")
    func singlePoint() {
        var document = ShotDocument()
        document.add(
            ShotStroke(
                tool: .pen, color: ShotColor.palette[0], width: 4,
                points: [ShotPoint(x: 1, y: 1)]
            )
        )
        #expect(document.isEmpty)
    }

    @Test("Undo and redo walk the same strokes")
    func undoRedo() {
        var document = ShotDocument()
        document.add(
            stroke(.rectangle, from: ShotPoint(x: 0, y: 0), to: ShotPoint(x: 50, y: 50))
        )
        document.add(
            stroke(.arrow, from: ShotPoint(x: 10, y: 10), to: ShotPoint(x: 90, y: 90))
        )
        #expect(document.strokes.count == 2)

        document.undo()
        #expect(document.strokes.count == 1)
        #expect(document.canRedo)

        document.redo()
        #expect(document.strokes.count == 2)
        #expect(document.strokes[1].tool == .arrow)
    }

    @Test("A new mark ends the old future")
    func redoIsDiscarded() {
        var document = ShotDocument()
        document.add(
            stroke(.rectangle, from: ShotPoint(x: 0, y: 0), to: ShotPoint(x: 50, y: 50))
        )
        document.undo()
        #expect(document.canRedo)
        document.add(
            stroke(.ellipse, from: ShotPoint(x: 0, y: 0), to: ShotPoint(x: 30, y: 30))
        )
        #expect(!document.canRedo)
        #expect(document.strokes.count == 1)
        #expect(document.strokes[0].tool == .ellipse)
    }

    @Test("Undoing an empty document does nothing rather than crashing")
    func undoEmpty() {
        var document = ShotDocument()
        document.undo()
        document.redo()
        #expect(document.isEmpty)
    }
}

@Suite("Toolbar")
struct ToolbarTests {
    private let screen = ShotRect(x: 0, y: 0, w: 1920, h: 1080)

    @Test("Every button is inside the plate that draws behind it")
    func buttonsInsidePlate() {
        let (plate, buttons) = ShotToolbar.layout(in: screen)
        #expect(!buttons.isEmpty)
        for button in buttons {
            #expect(button.frame.x >= plate.x)
            #expect(button.frame.maxX <= plate.maxX + 0.001)
            #expect(button.frame.y >= plate.y)
            #expect(button.frame.maxY <= plate.maxY + 0.001)
        }
    }

    @Test("Buttons do not overlap, in order, left to right")
    func buttonsDoNotOverlap() {
        let (_, buttons) = ShotToolbar.layout(in: screen)
        for i in 1..<buttons.count {
            #expect(buttons[i].frame.x >= buttons[i - 1].frame.maxX)
        }
    }

    @Test("A click lands on the button that was drawn there")
    func hitTesting() {
        let (_, buttons) = ShotToolbar.layout(in: screen)
        // The whole point of laying the strip out here rather than with a
        // layout engine: the paint and the hit test read the same numbers,
        // and a toolbar whose clicks are one button to the left of its icons
        // is the failure this rules out.
        for button in buttons {
            let cx = button.frame.x + button.frame.w / 2
            let cy = button.frame.y + button.frame.h / 2
            #expect(ShotToolbar.hit(buttons, x: cx, y: cy) == button.action)
        }
    }

    @Test("A click off the strip hits nothing")
    func missing() {
        let (plate, buttons) = ShotToolbar.layout(in: screen)
        #expect(ShotToolbar.hit(buttons, x: 5, y: 5) == nil)
        #expect(ShotToolbar.hit(buttons, x: plate.x - 20, y: plate.y + 10) == nil)
        #expect(ShotToolbar.hit(buttons, x: plate.x + 10, y: plate.y - 20) == nil)
    }

    @Test("The strip is centred and on screen, from a phone to a wall")
    func centred() {
        for width in [Float(800), 1280, 1920, 3840] {
            let bounds = ShotRect(x: 0, y: 0, w: width, h: width * 0.6)
            let (plate, _) = ShotToolbar.layout(in: bounds)
            #expect(plate.x >= 0)
            #expect(plate.maxX <= width + 0.001)
            #expect(abs((plate.x + plate.w / 2) - width / 2) < 0.5)
            #expect(plate.maxY <= bounds.maxY)
        }
    }

    @Test("Every tool has a button")
    func everyTool() {
        let (_, buttons) = ShotToolbar.layout(in: screen)
        for tool in ShotTool.allCases {
            #expect(buttons.contains { $0.action == .tool(tool) })
        }
    }
}

@Suite("Where a shot goes")
struct OutputTests {
    @Test("Two shots in the same session do not collide")
    func namesAreDistinct() {
        let home = URL(fileURLWithPath: "/home/somebody")
        let first = ShotOutput.defaultURL(
            now: Date(timeIntervalSince1970: 1_757_000_000), home: home
        )
        let second = ShotOutput.defaultURL(
            now: Date(timeIntervalSince1970: 1_757_000_001), home: home
        )
        #expect(first != second)
    }

    @Test("A shot lands under Pictures/Screenshots, named by its second")
    func naming() {
        let url = ShotOutput.defaultURL(
            now: Date(timeIntervalSince1970: 0), home: URL(fileURLWithPath: "/h")
        )
        #expect(url.deletingLastPathComponent().path == "/h/Pictures/Screenshots")
        #expect(url.pathExtension == "png")
        #expect(url.lastPathComponent.hasPrefix("Screenshot "))
        // No colons: a name that cannot be copied onto a memory stick is a
        // name that fails in the one place people put screenshots.
        #expect(!url.lastPathComponent.contains(":"))
    }
}
