import XCTest

@testable import LavaUI

final class PaddingTests: XCTestCase {
    /// Nested under a fixed stack so the padded box is not stretched to the
    /// full host size (root Yoga nodes fill the offered width/height).
    private func frames(of view: some View) -> [LayoutFrame] {
        let host = LayoutHost()
        host.setRoot(
            VStack(width: .pt(200), height: .pt(200), alignment: .start) {
                view
            }
        )
        return host.calculateLayout(width: 200, height: 200)
    }

    func testUniformPaddingInsetsAllEdges() throws {
        let frames = frames(
            of: EmptyView()
                .frame(width: .pt(10), height: .pt(10))
                .padding(5)
        )
        // Outer Modified box wraps the EmptyView; child sits inset by 5.
        let empty = try XCTUnwrap(frames.first { $0.label == "EmptyView" })
        XCTAssertEqual(empty.x, 5, accuracy: 0.01)
        XCTAssertEqual(empty.y, 5, accuracy: 0.01)
        XCTAssertEqual(empty.w, 10, accuracy: 0.01)
        XCTAssertEqual(empty.h, 10, accuracy: 0.01)
    }

    func testHorizontalPaddingOnlyAffectsLeadingAndTrailing() throws {
        let frames = frames(
            of: EmptyView()
                .frame(width: .pt(10), height: .pt(10))
                .padding(.horizontal, 12)
        )
        let empty = try XCTUnwrap(frames.first { $0.label == "EmptyView" })
        XCTAssertEqual(empty.x, 12, accuracy: 0.01)
        XCTAssertEqual(empty.y, 0, accuracy: 0.01)
        XCTAssertEqual(empty.w, 10, accuracy: 0.01)
        XCTAssertEqual(empty.h, 10, accuracy: 0.01)

        // Wrapper should claim width = content + horizontal insets only.
        let wrapper = try XCTUnwrap(frames.first { $0.label == "Modified" })
        XCTAssertEqual(wrapper.w, 34, accuracy: 0.01) // 12 + 10 + 12
        XCTAssertEqual(wrapper.h, 10, accuracy: 0.01)
    }

    func testTopPaddingOnly() throws {
        let frames = frames(
            of: EmptyView()
                .frame(width: .pt(10), height: .pt(10))
                .padding(.top, 7)
        )
        let empty = try XCTUnwrap(frames.first { $0.label == "EmptyView" })
        XCTAssertEqual(empty.x, 0, accuracy: 0.01)
        XCTAssertEqual(empty.y, 7, accuracy: 0.01)
    }

    func testEdgeInsetsInitializer() throws {
        let frames = frames(
            of: EmptyView()
                .frame(width: .pt(10), height: .pt(10))
                .padding(EdgeInsets(top: 1, leading: 2, bottom: 3, trailing: 4))
        )
        let empty = try XCTUnwrap(frames.first { $0.label == "EmptyView" })
        XCTAssertEqual(empty.x, 2, accuracy: 0.01)
        XCTAssertEqual(empty.y, 1, accuracy: 0.01)

        let wrapper = try XCTUnwrap(frames.first { $0.label == "Modified" })
        XCTAssertEqual(wrapper.w, 16, accuracy: 0.01) // 2 + 10 + 4
        XCTAssertEqual(wrapper.h, 14, accuracy: 0.01) // 1 + 10 + 3
    }

    func testEdgeInsetsHelpers() {
        XCTAssertEqual(EdgeInsets.all(5), EdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5))
        XCTAssertEqual(EdgeInsets.horizontal(3), EdgeInsets(leading: 3, trailing: 3))
        XCTAssertEqual(EdgeInsets.vertical(4), EdgeInsets(top: 4, bottom: 4))
        XCTAssertEqual(EdgeInsets(.horizontal, 8).horizontalTotal, 16, accuracy: 0.01)
        XCTAssertEqual(EdgeInsets(.vertical, 2).verticalTotal, 4, accuracy: 0.01)
        XCTAssertTrue(Edge.horizontal.contains(.leading))
        XCTAssertFalse(Edge.horizontal.contains(.top))
    }
}
