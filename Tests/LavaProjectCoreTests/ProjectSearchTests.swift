import Foundation
import XCTest
@testable import LavaProjectCore

final class ProjectSearchTests: XCTestCase {
    func testArgumentsKeepPatternLiteralAndSeparateFromFlags() {
        var options = ProjectSearchOptions()
        options.query = "-x.*"
        XCTAssertEqual(Array(options.arguments.suffix(4)), ["-e", "-x.*", "--", "."])
        XCTAssertTrue(options.arguments.contains("--fixed-strings"))
        XCTAssertTrue(options.arguments.contains("--ignore-case"))
        XCTAssertTrue(options.arguments.contains("--no-require-git"))

        options.caseSensitive = true
        options.wholeWord = true
        options.regularExpression = true
        XCTAssertTrue(options.arguments.contains("--case-sensitive"))
        XCTAssertTrue(options.arguments.contains("--word-regexp"))
        XCTAssertFalse(options.arguments.contains("--fixed-strings"))
        XCTAssertFalse(options.arguments.contains("--ignore-case"))
    }

    func testCommaSeparatedGlobsAndNestedPaths() {
        var options = ProjectSearchOptions()
        options.include = " Sources/**/*.swift , *.md, "
        options.exclude = "Sources/Vendor/, private-?.md"
        let globs = ProjectSearchGlobs(options)
        XCTAssertTrue(globs.accepts("Sources/Root.swift"))
        XCTAssertTrue(globs.accepts("Sources/LavaUI/View.swift"))
        XCTAssertTrue(globs.accepts("docs/guide.md"))
        XCTAssertFalse(globs.accepts("Sources/Vendor/nested/Lib.swift"))
        XCTAssertFalse(globs.accepts("docs/private-a.md"))
        XCTAssertFalse(globs.accepts("Tests/Search.swift"))
    }

    func testJSONOffsetsUseCharactersAcrossEmojiAndCRLF() throws {
        var output = ProjectSearchOutput(options: ProjectSearchOptions(), limit: 10)
        try output.consume(record("./Sources/é.swift", number: 2, line: "é 👩‍💻 hit hit\r\n",
                                  spans: [15..<18, 19..<22], base64: true))
        let line = try XCTUnwrap(output.finish().files.first?.lines.first)
        XCTAssertEqual(output.finish().files.first?.path, "Sources/é.swift")
        XCTAssertEqual(line.matches, [4..<7, 8..<11])
        XCTAssertEqual(line.highlights, line.matches)
        XCTAssertEqual(line.preview, "é 👩‍💻 hit hit")
        let buffer = "😀\r\né 👩‍💻 hit hit\r\nlast"
        XCTAssertEqual(line.selection(in: buffer), 6..<9)
        XCTAssertEqual(line.selection(in: buffer, match: 1), 10..<13)
        XCTAssertNil(line.selection(in: "😀\r\nchanged"))
    }

    func testScalarMatchWidensAndZeroLengthMatchKeepsACaret() throws {
        var output = ProjectSearchOutput(options: ProjectSearchOptions(), limit: 10)
        try output.consume(record("a", number: 1, line: "x e\u{301}!", spans: [3..<5, 6..<6]))
        let line = try XCTUnwrap(output.finish().files.first?.lines.first)
        XCTAssertEqual(line.matches, [2..<3, 4..<4])
        XCTAssertEqual(line.selection(in: "x e\u{301}!", match: 1), 4..<4)
    }

    func testGroupingCapAndPreview() throws {
        var output = ProjectSearchOutput(options: ProjectSearchOptions(), limit: 4)
        let longPrefix = String(repeating: "x", count: 400)
        let longLine = longPrefix + " hit " + longPrefix
        try output.consume(record("z", number: 1, line: longLine, spans: [401..<404]))
        try output.consume(record("a", number: 6, line: "hit", spans: [0..<3]))
        try output.consume(record("z", number: 2, line: "hit hit", spans: [0..<3, 4..<7]))
        XCTAssertFalse(output.finish().capped, "exactly at the limit is still a complete result")
        let result = output.finish()
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result.files.map(\.path), ["a", "z"])
        XCTAssertEqual(result.files.map(\.count), [1, 3])
        XCTAssertEqual(result.files[1].lines.map(\.number), [1, 2])
        let preview = result.files[1].lines[0]
        XCTAssertTrue(preview.preview.hasPrefix("…"))
        XCTAssertTrue(preview.preview.hasSuffix("…"))
        XCTAssertEqual(preview.highlights, [17..<20])

        try output.consume(record("c", number: 1, line: "hit", spans: [0..<3]))
        XCTAssertTrue(output.finish().capped)
        XCTAssertEqual(output.finish().count, 4)

        var withinLine = ProjectSearchOutput(options: ProjectSearchOptions(), limit: 1)
        try withinLine.consume(record("a", number: 1, line: "hit hit", spans: [0..<3, 4..<7]))
        XCTAssertTrue(withinLine.finish().capped)
        XCTAssertEqual(withinLine.finish().files.first?.lines.first?.matches, [0..<3])
    }

    func testRipgrepHonorsIgnoreFilesAndSearchOptions() throws {
        let rg = try XCTUnwrapOrSkip(ProjectSearchEngine.findRipgrep())
        let root = try scratch()
        try write("ignored.swift\n", ".gitignore", in: root)
        try write("hidden.swift\n", "Sources/.gitignore", in: root)
        try write("cat", "Sources/ignored.swift", in: root)
        try write("cat", "Sources/nested/hidden.swift", in: root)
        try write("Cat category cat CAT\r\n", "Sources/nested/a.swift", in: root)
        try write("cat", "Sources/vendor/b.swift", in: root)
        try write("cat", "Sources/c.md", in: root)
        try write("cat", "Tests/a.swift", in: root)
        try write("cat", ".git/internal.swift", in: root)

        var options = ProjectSearchOptions()
        options.query = "cat"
        options.wholeWord = true
        options.include = "**/*.swift"
        options.exclude = "Sources/vendor/, Tests/"
        func run(limit: Int = 10) throws -> ProjectSearchResult {
            try ProjectSearchEngine.search(root: root, options: options, cancellation: .init(),
                                           limit: limit, executable: rg)
        }
        let insensitive = try run()
        XCTAssertEqual(insensitive.files.map(\.path), ["Sources/nested/a.swift"])
        XCTAssertEqual(insensitive.count, 3)
        let capped = try run(limit: 2)
        XCTAssertEqual(capped.count, 2)
        XCTAssertTrue(capped.capped)

        options.caseSensitive = true
        XCTAssertEqual(try run().count, 1)
        options.query = "CAT$"
        options.regularExpression = true
        XCTAssertEqual(try run().files.first?.lines.first?.matches, [17..<20])
        options.query = "("
        XCTAssertThrowsError(try run()) { error in
            XCTAssertTrue(error.localizedDescription.contains("regex parse error"))
        }

        options.query = "cat"
        options.include = "missing/**"
        XCTAssertEqual(try run().count, 0)
    }

    func testCancellationBeforeLaunch() throws {
        let cancellation = ProjectSearchCancellation()
        cancellation.cancel()
        var options = ProjectSearchOptions()
        options.query = "query"
        XCTAssertThrowsError(try ProjectSearchEngine.search(
            root: scratch(), options: options, cancellation: cancellation, limit: 10,
            executable: URL(fileURLWithPath: "/no-such-executable")
        )) { XCTAssertTrue($0 is CancellationError) }
    }

    func testCancellationUnblocksAWorkerWaitingForOutput() throws {
        let root = try scratch()
        let stub = root.appendingPathComponent("rg")
        try write("#!/bin/sh\ntouch started\nexec /usr/bin/sleep 30\n", "rg", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)

        var input = ProjectSearchOptions()
        input.query = "query"
        let options = input
        let cancellation = ProjectSearchCancellation()
        defer { cancellation.cancel() }
        let finished = expectation(description: "Worker cancelled")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                _ = try ProjectSearchEngine.search(
                    root: root, options: options, cancellation: cancellation, limit: 10, executable: stub
                )
                XCTFail("Expected the running search to cancel")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
        }

        let marker = root.appendingPathComponent("started").path
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: marker), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker), "The subprocess reached its blocking call")
        cancellation.cancel()
        wait(for: [finished], timeout: 3)
    }

    private func scratch() throws -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("lava-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: path) }
        return path
    }

    private func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func record(
        _ path: String, number: Int, line: String, spans: [Range<Int>], base64: Bool = false
    ) throws -> Data {
        func bytes(_ text: String) -> [String: String] {
            base64 ? ["bytes": Data(text.utf8).base64EncodedString()] : ["text": text]
        }
        return try JSONSerialization.data(withJSONObject: [
            "type": "match",
            "data": [
                "path": bytes(path), "lines": bytes(line), "line_number": number,
                "submatches": spans.map { ["start": $0.lowerBound, "end": $0.upperBound] },
            ],
        ])
    }

    private func XCTUnwrapOrSkip<T>(_ value: T?) throws -> T {
        guard let value else { throw XCTSkip("ripgrep is unavailable") }
        return value
    }
}
