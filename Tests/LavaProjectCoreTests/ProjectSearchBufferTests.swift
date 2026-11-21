import Foundation
import XCTest
@testable import LavaProjectCore

/// An unsaved buffer is searched in Swift and stands in for its file, so the
/// two have to agree: what ripgrep says about the file written to disk is
/// what the buffer search has to say about the same text.
final class ProjectSearchBufferTests: XCTestCase {
    private let sample = """
    let cat = "Cat"\r
    // 👩‍💻 cat café cat\r
    categories.cat()
    \tCAT
    no match here, but c.t
    cat
    """ + "\n"

    private struct Hit: Equatable {
        let number: Int
        let matches: [Range<Int>]
        let preview: String
    }

    private func hits(_ file: ProjectSearchFile?) -> [Hit] {
        (file?.lines ?? []).map { Hit(number: $0.number, matches: $0.matches, preview: $0.preview) }
    }

    func testAgreesWithRipgrepOnTheSameText() throws {
        let rg = try XCTUnwrapOrSkip(ProjectSearchEngine.findRipgrep())
        let root = try scratch()
        try sample.write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        let buffer = ProjectSearchBuffer(path: "a.swift", text: sample)

        let cases: [(String, Bool, Bool, Bool)] = [
            // query, case sensitive, whole word, regex
            ("cat", false, false, false),
            ("cat", true, false, false),
            ("cat", false, true, false),
            ("café cat", false, false, false),
            ("c.t", false, false, false),
            ("^\\s*cat", false, false, true),
            ("cat$", false, false, true),
            ("[A-Z]{3}", true, false, true),
            ("cat|CAT", true, true, true),
        ]
        for (query, caseSensitive, wholeWord, regex) in cases {
            var options = ProjectSearchOptions()
            options.query = query
            options.caseSensitive = caseSensitive
            options.wholeWord = wholeWord
            options.regularExpression = regex
            let disk = try ProjectSearchEngine.search(
                root: root, options: options, cancellation: .init(), limit: 100,
                executable: rg, paths: ["a.swift"]
            )
            let buffer = try ProjectSearchText.search(buffer, options: options, limit: 100)
            XCTAssertFalse(hits(disk.files.first).isEmpty, query)
            XCTAssertEqual(hits(buffer), hits(disk.files.first), "\(query) case:\(caseSensitive) word:\(wholeWord) regex:\(regex)")
        }
    }

    func testAResultFromABufferOpensTheSameSelection() throws {
        var options = ProjectSearchOptions()
        options.query = "café"
        let file = try XCTUnwrap(ProjectSearchText.search(
            ProjectSearchBuffer(path: "a.swift", text: sample), options: options))
        let line = try XCTUnwrap(file.lines.first)
        let range = try XCTUnwrap(line.selection(in: sample))
        let characters = Array(sample)
        XCTAssertEqual(String(characters[range]), "café")
    }

    func testGlobsAndGitDecideWhetherABufferIsAskedAtAll() throws {
        var options = ProjectSearchOptions()
        options.query = "cat"
        options.exclude = "Tests/"
        XCTAssertNil(try ProjectSearchText.search(.init(path: "Tests/a.swift", text: "cat"), options: options))
        XCTAssertNil(try ProjectSearchText.search(.init(path: ".git/config", text: "cat"), options: options))
        // Asked, and nothing found, is an empty file — which removes the
        // path from a result rather than leaving the disk's matches.
        let empty = try ProjectSearchText.search(.init(path: "a.swift", text: "dog"), options: options)
        XCTAssertEqual(empty?.lines.count, 0)
    }

    func testAPatternSwiftCannotCompileThrows() {
        var options = ProjectSearchOptions()
        options.query = "("
        options.regularExpression = true
        XCTAssertThrowsError(try ProjectSearchText.search(.init(path: "a", text: "("), options: options))
        options.regularExpression = false
        XCTAssertEqual(try ProjectSearchText.search(.init(path: "a", text: "f(x)"), options: options)?.count, 1)
    }

    func testStopsOnePastTheLimitSoTheMergeSaysCapped() throws {
        var options = ProjectSearchOptions()
        options.query = "a"
        let file = try XCTUnwrap(ProjectSearchText.search(
            .init(path: "a", text: String(repeating: "aaaa\n", count: 10)), options: options, limit: 5))
        XCTAssertEqual(file.count, 6)
        XCTAssertTrue(ProjectSearchResult().replacing(["a": file], limit: 5).capped)
    }

    func testReplacingSwapsDropsAndAddsByPath() throws {
        var options = ProjectSearchOptions()
        options.query = "x"
        func file(_ path: String, _ text: String) throws -> ProjectSearchFile {
            try XCTUnwrap(ProjectSearchText.search(.init(path: path, text: text), options: options))
        }
        let disk = ProjectSearchResult().replacing([
            "b": try file("b", "x\nx"), "c": try file("c", "x"),
        ])
        XCTAssertEqual(disk.files.map(\.path), ["b", "c"])
        XCTAssertEqual(disk.count, 3)

        let live = disk.replacing(["b": try file("b", "x"), "c": try file("c", "y"), "a": try file("a", "xx")])
        XCTAssertEqual(live.files.map(\.path), ["a", "b"])
        XCTAssertEqual(live.files.map(\.count), [2, 1])
        XCTAssertEqual(live.count, 3)
        XCTAssertFalse(live.capped)
    }

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-buffer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func XCTUnwrapOrSkip<T>(_ value: T?) throws -> T {
        guard let value else { throw XCTSkip("ripgrep is unavailable") }
        return value
    }
}
