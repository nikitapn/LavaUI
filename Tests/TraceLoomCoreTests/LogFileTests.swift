import Foundation
import Testing
@testable import TraceLoomCore

/// A file in a fresh temp directory, removed when the test returns.
private func withTempFile(
    named name: String, bytes: Data, _ body: (URL) throws -> Void
) rethrows {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tl-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: bytes)
    try body(url)
}

/// Two lines per repetition, in the shape TraceLoom's sample rules match.
private func syntheticLog(lines: Int) -> Data {
    var out = ""
    out.reserveCapacity(lines * 60)
    for i in 0..<lines {
        let ms = i % 1000, s = (i / 1000) % 60, m = (i / 60_000) % 60, h = (i / 3_600_000) % 24
        let ts = String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
        out += "\(ts) NetworkMetrics inboundKbps:\(1000 + i % 8000) outboundKbps:\(500 + i % 4000)\n"
    }
    return Data(out.utf8)
}

@Test func readsPlainUTF8Log() throws {
    try withTempFile(named: "ok.log", bytes: Data("10:00:00.000 a=1\n".utf8)) { url in
        let load = try LogFile.read(at: url)
        #expect(load.text == "10:00:00.000 a=1\n")
        #expect(load.warning == nil)
    }
}

/// The reported bug: `try? String(contentsOf:encoding:)` returned nil for the
/// whole file over one bad byte, and the caller returned without a word.
@Test func loadsDespiteOneInvalidUTF8ByteAndSaysSo() throws {
    var bytes = Data("10:00:00.000 first\n".utf8)
    bytes.append(contentsOf: [0x63, 0x61, 0x66, 0xE9, 0x0A])  // "caf\xE9\n", Latin-1
    bytes.append(contentsOf: Data("10:00:02.000 third\n".utf8))

    try withTempFile(named: "latin1.log", bytes: bytes) { url in
        let load = try LogFile.read(at: url)
        // Every valid line survives; only the offending byte is replaced.
        #expect(load.text.contains("10:00:00.000 first"))
        #expect(load.text.contains("10:00:02.000 third"))
        #expect(load.text.contains("\u{FFFD}"))

        let warning = try #require(load.warning)
        #expect(warning.contains(url.path))
        #expect(warning.contains("byte 22"))
        #expect(warning.contains("line 2"))
    }
}

@Test func reportsMissingFileWithPathAndUnderlyingError() {
    let url = URL(fileURLWithPath: "/nonexistent/definitely/not/here.log")
    #expect(throws: LogFile.LoadError.self) { try LogFile.read(at: url) }
    do {
        _ = try LogFile.read(at: url)
    } catch let error as LogFile.LoadError {
        #expect("\(error)".contains(url.path))
        // The underlying reason, not just "could not read".
        #expect("\(error)".lowercased().contains("doesn’t exist"))
    } catch {
        Issue.record("wrong error type: \(error)")
    }
}

@Test func reportsOversizeFileAsAResourceLimitRatherThanFailingSilently() throws {
    // Nothing here allocates 256 MB: the size check runs off file metadata,
    // which is the reason it can refuse the allocation at all.
    try withTempFile(named: "big.log", bytes: Data("x\n".utf8)) { url in
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(LogFile.byteLimit + 1))
        try handle.close()

        do {
            _ = try LogFile.read(at: url)
            Issue.record("expected a size error")
        } catch let error as LogFile.LoadError {
            #expect("\(error)".contains(url.path))
            #expect("\(error)".contains("256.0 MB limit"))
        }
    }
}

/// The observed threshold was ~10 MB. It is not a real boundary: a valid log
/// well past it loads whole, and parses, with no size-dependent failure.
@Test func loadsAndParsesWellPastTheObservedTenMegabyteThreshold() throws {
    let bytes = syntheticLog(lines: 220_000)
    #expect(bytes.count > 12 * 1024 * 1024)

    try withTempFile(named: "over-threshold.log", bytes: bytes) { url in
        let load = try LogFile.read(at: url)
        #expect(load.warning == nil)
        #expect(load.text.utf8.count == bytes.count)

        let rules = #"""
        line | Inbound | ^(\d\d:\d\d:\d\d\.\d+).*inboundKbps:(\d+) | 1 | 2 | traffic
        """#
        let parsed = TraceParser.parse(log: load.text, rulesSource: rules)
        #expect(parsed.diagnostics.isEmpty)
        #expect(parsed.series[0].points.count == 220_000)
    }
}

@Test func acceptsValidMultibyteUTF8WithoutWarning() throws {
    let text = "10:00:00.000 café ☃ 𝄞 done\n"
    try withTempFile(named: "utf8.log", bytes: Data(text.utf8)) { url in
        let load = try LogFile.read(at: url)
        #expect(load.text == text)
        #expect(load.warning == nil)
    }
}

@Test func findsFirstInvalidByteAndIgnoresValidSequences() {
    #expect(LogFile.firstInvalidUTF8Offset(in: Data("ok".utf8)) == nil)
    #expect(LogFile.firstInvalidUTF8Offset(in: Data("é☃𝄞".utf8)) == nil)
    // Bare continuation byte.
    #expect(LogFile.firstInvalidUTF8Offset(in: Data([0x41, 0x80])) == 1)
    // Truncated three-byte sequence at end of buffer.
    #expect(LogFile.firstInvalidUTF8Offset(in: Data([0x41, 0xE2, 0x98])) == 1)
    // Overlong encoding of '/' and a UTF-16 surrogate, both rejected.
    #expect(LogFile.firstInvalidUTF8Offset(in: Data([0xC0, 0xAF])) == 0)
    #expect(LogFile.firstInvalidUTF8Offset(in: Data([0xED, 0xA0, 0x80])) == 0)
}
