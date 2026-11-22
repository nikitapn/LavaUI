import Foundation
import XCTest
@testable import LavaTermCore

final class OSCTitleTests: XCTestCase {
    private func titles(_ chunks: [Data]) -> [String] {
        let parser = AnsiParser()
        return chunks.flatMap { parser.feed($0) }.compactMap { output in
            if case .setTitle(let title) = output { return title }
            return nil
        }
    }

    /// Claude Code puts a braille spinner in its title; it used to arrive as
    /// three Latin-1 characters, one per byte.
    func testTitleIsUTF8() {
        XCTAssertEqual(titles([Data("\u{1b}]0;⠳ Claude Code\u{07}".utf8)]), ["⠳ Claude Code"])
        XCTAssertEqual(titles([Data("\u{1b}]2;café ✓\u{1b}\\".utf8)]), ["café ✓"])
    }

    func testTitleSplitAcrossReads() {
        let bytes = Array("\u{1b}]0;⠳ x\u{07}".utf8)
        // Cut inside the three bytes of the spinner.
        XCTAssertEqual(titles([Data(bytes[..<5]), Data(bytes[5...])]), ["⠳ x"])
    }
}
