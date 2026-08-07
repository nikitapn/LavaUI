import XCTest

@testable import LavaUI

final class StackSpacingTests: XCTestCase {
    func testHStackAppliesSpacingOnlyBetweenChildren() throws {
        let host = LayoutHost()
        host.setRoot(HStack(spacing: 7) {
            EmptyView().frame(width: .pt(10), height: .pt(10))
            EmptyView().frame(width: .pt(20), height: .pt(10))
        })

        let emptyFrames = host.calculateLayout(width: 100, height: 40)
            .filter { $0.label == "EmptyView" }
        XCTAssertEqual(emptyFrames.count, 2)
        let first = emptyFrames[0]
        let second = emptyFrames[1]
        XCTAssertEqual(second.x - first.x, 17, accuracy: 0.01)
    }

    func testVStackDistinguishesZeroFromDefaultSpacing() throws {
        let host = LayoutHost()
        host.setRoot(VStack(spacing: 0) {
            EmptyView().frame(width: .pt(10), height: .pt(10))
            EmptyView().frame(width: .pt(10), height: .pt(10))
        })

        var emptyFrames = host.calculateLayout(width: 40, height: 100)
            .filter { $0.label == "EmptyView" }
        XCTAssertEqual(emptyFrames[1].y - emptyFrames[0].y, 10, accuracy: 0.01)

        host.setRoot(VStack {
            EmptyView().frame(width: .pt(10), height: .pt(10))
            EmptyView().frame(width: .pt(10), height: .pt(10))
        })
        emptyFrames = host.calculateLayout(width: 40, height: 100)
            .filter { $0.label == "EmptyView" }
        XCTAssertEqual(emptyFrames[1].y - emptyFrames[0].y, 18, accuracy: 0.01)
        XCTAssertEqual(host.mountCount, 1)
        XCTAssertEqual(host.reconcileCount, 1)
    }
}
