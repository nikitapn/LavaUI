import Dispatch
import Foundation
import LavaText
import XCTest

final class HighlightNameTests: XCTestCase {
    func testTheFirstNamesKeepTheIndicesRulesAlwaysUsed() {
        XCTAssertEqual(HighlightName.index(of: "keyword"), 0)
        XCTAssertEqual(HighlightName.index(of: "string"), 1)
        XCTAssertEqual(HighlightName.index(of: "comment"), 2)
        XCTAssertEqual(HighlightName.index(of: "number"), 3)
        XCTAssertEqual(HighlightName.index(of: "type"), 4)
        XCTAssertEqual(HighlightName.name(at: HighlightName.parameter), "variable.parameter")
        XCTAssertEqual(CodeLexer.comment, HighlightName.comment)
    }

    func testANameIsRegisteredOnceAndKeepsItsIndex() {
        let index = HighlightName.index(of: "test.registered.once")
        XCTAssertEqual(HighlightName.index(of: "test.registered.once"), index)
        XCTAssertEqual(HighlightName.name(at: index), "test.registered.once")
        XCTAssertNil(HighlightName.name(at: -1))
        XCTAssertNil(HighlightName.name(at: Int.max))
    }

    func testFallbacksRunFromSpecificToGeneral() {
        XCTAssertEqual(HighlightName.fallbacks(of: "function.method.call"), ["function.method.call", "function.method", "function"])
        XCTAssertEqual(HighlightName.fallbacks(of: "keyword"), ["keyword"])
    }

    func testInterningFromManyThreadsAgrees() {
        let names = (0..<64).map { "test.concurrent.\($0 % 8)" }
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var values: [Int: Int] = [:]
        }
        let collected = Results()
        DispatchQueue.concurrentPerform(iterations: names.count) { slot in
            let index = HighlightName.index(of: names[slot])
            collected.lock.lock()
            collected.values[slot] = index
            collected.lock.unlock()
        }
        let results = (0..<names.count).map { collected.values[$0]! }
        for (name, index) in zip(names, results) {
            XCTAssertEqual(HighlightName.name(at: index), name)
        }
        XCTAssertEqual(Set(results).count, 8)
    }
}
