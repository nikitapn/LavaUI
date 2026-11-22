import XCTest
@testable import SwiftTestExtension

final class SwiftTestDiscoveryTests: XCTestCase {
    func testFindsDeclarationsAndPreservesArgumentLabels() {
        let tests = discoverSwiftTests(in: """
        // @Test func phantom() {}
        struct Suite {
            let example = "@Test func example() {}"
            struct Nested {
                @Testing.Test("reads", arguments: [1])
                func read(_ byte: Int, from source: Int) async throws {}
            }
        }
        extension Suite {
            @Test func second() {}
        }
        @Test func standalone() {}
        """)
        XCTAssertEqual(tests.map(\.name), ["Suite/Nested/read(_:from:)", "Suite/second()", "standalone()"])
        XCTAssertEqual(tests.map(\.line), [4, 9, 11])
        XCTAssertTrue(tests.allSatisfy(\.swiftTesting))
    }

    func testXCTestRequiresInstanceMethodWithoutArguments() {
        let tests = discoverSwiftTests(in: """
        final class Checks: XCTest.XCTestCase {
            func testRead() throws {}
            func testHelper(_ value: Int) {}
            static func testFactory() {}
            func helper() {}
        }
        struct App { func testRead() {} }
        """)
        XCTAssertEqual(tests.map(\.name), ["Checks/testRead"])
        XCTAssertEqual(tests.first?.swiftTesting, false)
    }
}
