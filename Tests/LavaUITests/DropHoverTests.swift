import XCTest

@testable import LavaUI

/// A drag of files over drop targets, before any drop: which target hears it
/// is aimed at, and when a spring-loaded one opens.
final class DropHoverTests: XCTestCase {
    private var ids: Set<NodeID> = []

    override func tearDown() {
        DropRouter.dragLeave()
        DropRouter.unregisterAll(ids: ids)
        ids = []
        super.tearDown()
    }

    private func target(
        targeted: @escaping (Bool) -> Void = { _ in },
        springLoaded: (() -> Void)? = nil
    ) -> NodeID {
        let id = NodeID.generate()
        ids.insert(id)
        DropRouter.register(
            id, hover: DropRouter.Hover(targeted: targeted, springLoaded: springLoaded)
        ) { _ in }
        return id
    }

    func testMovingBetweenTargetsTellsBoth() {
        var log: [String] = []
        let folder = target(targeted: { log.append("folder \($0)") })
        let list = target(targeted: { log.append("list \($0)") })

        DropRouter.dragOver(folder)
        DropRouter.dragOver(folder)  // moving within it says nothing new
        DropRouter.dragOver(list)
        DropRouter.dragLeave()
        XCTAssertEqual(log, ["folder true", "folder false", "list true", "list false"])
    }

    func testATabOpensOnlyAfterTheDragRestsOnIt() {
        var opened = 0
        let tab = target(springLoaded: { opened += 1 })
        let entered = FrameScheduler.now()

        DropRouter.dragOver(tab)
        DropRouter.tickSpring(now: entered + DropRouter.springDelay / 2)
        XCTAssertEqual(opened, 0, "sweeping across a tab must not open it")
        DropRouter.tickSpring(now: entered + DropRouter.springDelay + 0.05)
        XCTAssertEqual(opened, 1)
        DropRouter.tickSpring(now: entered + DropRouter.springDelay * 3)
        XCTAssertEqual(opened, 1, "once per visit, not once per frame")
    }

    func testLeavingBeforeTheDelayOpensNothing() {
        var opened = 0
        let tab = target(springLoaded: { opened += 1 })
        let entered = FrameScheduler.now()

        DropRouter.dragOver(tab)
        DropRouter.dragLeave()
        DropRouter.tickSpring(now: entered + DropRouter.springDelay * 2)
        XCTAssertEqual(opened, 0)
    }

    func testATargetThatGoesAwayIsForgotten() {
        var opened = 0
        let tab = target(springLoaded: { opened += 1 })
        DropRouter.dragOver(tab)
        DropRouter.unregisterAll(ids: [tab])
        DropRouter.tickSpring(now: FrameScheduler.now() + DropRouter.springDelay * 2)
        XCTAssertEqual(opened, 0)
    }

    func testTheInnermostTargetAnswersForTheDrag() {
        let host = LayoutHost()
        host.setRoot(
            VStack(width: .pt(300), height: .pt(200), alignment: .start, spacing: 0) {
                VStack(width: .pt(300), height: .pt(200), alignment: .start, spacing: 0) {
                    Text("folder").frame(width: .pt(300), height: .pt(28))
                        .onDrop(targeted: { _ in }) { _ in }
                    Text("file").frame(width: .pt(300), height: .pt(28))
                }
                .onDrop(targeted: { _ in }) { _ in }
            }
        )
        _ = host.calculateLayout(width: 300, height: 200)
        let onFolder = host.dropTarget(x: 10, y: 10)
        let onFile = host.dropTarget(x: 10, y: 40)
        XCTAssertNotNil(onFolder)
        XCTAssertNotNil(onFile)
        XCTAssertNotEqual(onFolder, onFile, "a file row falls through to the list")
    }
}
