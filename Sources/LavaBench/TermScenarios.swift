import Foundation
import LavaTermCore

/// The terminal's ingest path — parse and apply PTY output — with no window.
///
/// A terminal under a program that writes as fast as it can (`yes`, a build
/// log, `cat` of a big file) is bounded by this, and the frames it presents
/// are whatever time is left over. Fed in the PTY reader's own 8 KiB chunks.
enum TermScenarios {
    static let chunk = 8192

    static func all() -> [Scenario] {
        [
            Scenario(
                "term.ingest-plain-8mb",
                detail: "TerminalScreen.feed — `yes`-style lines, 8 KiB chunks",
                iterations: 3,
                body: { _, rec in
                    let line = "The quick brown fox jumps over the lazy dog 0123456789\r\n"
                    feed(rec, chunks: chunks(of: line, megabytes: 8))
                }
            ),
            Scenario(
                "term.ingest-sgr-8mb",
                detail: "same, with colour escapes on every word (ls --color, compilers)",
                iterations: 3,
                body: { _, rec in
                    let line = "\u{1B}[1;32mok\u{1B}[0m \u{1B}[34msrc/main.swift\u{1B}[0m:"
                        + "\u{1B}[33m42\u{1B}[0m: \u{1B}[31merror:\u{1B}[0m something\r\n"
                    feed(rec, chunks: chunks(of: line, megabytes: 8))
                }
            ),
        ]
    }

    private static func chunks(of line: String, megabytes: Int) -> [Data] {
        let one = Data(line.utf8)
        var all = Data()
        all.reserveCapacity(megabytes << 20)
        while all.count < megabytes << 20 { all.append(one) }
        return stride(from: 0, to: all.count, by: chunk).map {
            all.subdata(in: $0..<min($0 + chunk, all.count))
        }
    }

    private static func feed(_ rec: Recorder, chunks: [Data]) {
        let screen = TerminalScreen(cols: 160, rows: 48)
        rec.stage("feed") {
            for c in chunks { screen.feed(c) }
        }
        rec.counter("bytes", chunks.reduce(0) { $0 + $1.count })
    }
}
