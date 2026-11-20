import XCTest
@testable import LavaUI

/// The lookups the editor's paint runs per visible row: which mark covers a
/// line, and which removals sit above it.
final class EditorLineMarkTests: XCTestCase {
    private let green = Color(r: 0, g: 1, b: 0)
    private let blue = Color(r: 0, g: 0, b: 1)
    private let red = Color(r: 1, g: 0, b: 0)

    private var marks: [EditorLineMark] {
        [
            EditorLineMark(lines: 2..<4, bar: green),
            EditorLineMark(lines: 6..<6, bar: red),
            EditorLineMark(lines: 6..<7, bar: blue),
            EditorLineMark(lines: 10..<10, bar: red),
        ]
    }

    func testCovering() {
        XCTAssertNil(DrawList.lineMark(covering: 0, in: marks))
        XCTAssertEqual(DrawList.lineMark(covering: 2, in: marks)?.bar, green)
        XCTAssertEqual(DrawList.lineMark(covering: 3, in: marks)?.bar, green)
        XCTAssertNil(DrawList.lineMark(covering: 4, in: marks))
        // A removal starting on the same line does not hide the change there.
        XCTAssertEqual(DrawList.lineMark(covering: 6, in: marks)?.bar, blue)
        XCTAssertNil(DrawList.lineMark(covering: 7, in: marks))
        // Past an empty mark, the search keeps looking back and finds nothing.
        XCTAssertNil(DrawList.lineMark(covering: 11, in: marks))
        XCTAssertNil(DrawList.lineMark(covering: 5, in: []))
    }

    func testRemovals() {
        XCTAssertEqual(DrawList.removals(at: 6, in: marks), [red])
        XCTAssertEqual(DrawList.removals(at: 10, in: marks), [red])
        XCTAssertEqual(DrawList.removals(at: 2, in: marks), [])
        XCTAssertEqual(DrawList.removals(at: 0, in: []), [])
    }
}
