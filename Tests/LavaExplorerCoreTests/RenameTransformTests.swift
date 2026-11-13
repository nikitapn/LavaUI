import Foundation
import Testing

@testable import LavaExplorerCore

@Suite struct RenameTransformTests {
    private func run(
        _ transform: RenameTransform, _ lines: [String],
        keep: Bool = true, directories: [Bool] = []
    ) throws -> [String] {
        try transform.apply(to: lines, keepExtensions: keep, isDirectory: directories)
    }

    @Test func caseChangesLeaveTheExtensionAlone() throws {
        #expect(try run(.lowercase, ["IMG_01.JPG", "Notes"]) == ["img_01.JPG", "notes"])
        #expect(try run(.uppercase, ["a.txt"]) == ["A.txt"])
        #expect(try run(.titlecase, ["the big IDEA.md"]) == ["The Big Idea.md"])
    }

    @Test func withoutKeepingExtensionsTheWholeNameChanges() throws {
        #expect(try run(.lowercase, ["IMG.JPG"], keep: false) == ["img.jpg"])
    }

    @Test func aFolderHasNoExtensionToKeep() throws {
        #expect(try run(.uppercase, ["v1.2"], directories: [true]) == ["V1.2"])
        #expect(try run(.uppercase, ["v1.2"], directories: [false]) == ["V1.2"])
        #expect(try run(.uppercase, ["v1.2.zip"]) == ["V1.2.zip"])
    }

    @Test func aDotfileIsAllStem() throws {
        #expect(try run(.uppercase, [".bashrc"]) == [".BASHRC"])
    }

    @Test func plainReplaceIsLiteral() throws {
        let transform = RenameTransform.replace(find: ".", with: "_", regex: false, ignoreCase: false)
        #expect(try run(transform, ["a.b.c.txt"]) == ["a_b_c.txt"])
    }

    @Test func plainReplaceCanIgnoreCase() throws {
        let transform = RenameTransform.replace(find: "img", with: "photo", regex: false, ignoreCase: true)
        #expect(try run(transform, ["IMG_1.jpg", "img_2.jpg"]) == ["photo_1.jpg", "photo_2.jpg"])
    }

    @Test func regexReplaceUsesGroups() throws {
        let transform = RenameTransform.replace(
            find: #"IMG_(\d+)"#, with: "rome-$1", regex: true, ignoreCase: false
        )
        #expect(try run(transform, ["IMG_0412.jpg", "other.jpg"]) == ["rome-0412.jpg", "other.jpg"])
    }

    @Test func aBrokenRegexSaysSo() {
        let transform = RenameTransform.replace(find: "(", with: "", regex: true, ignoreCase: false)
        #expect(throws: RenameTransform.Invalid(message: "That is not a regular expression")) {
            try run(transform, ["a"])
        }
    }

    @Test func anEmptyFindChangesNothing() throws {
        let transform = RenameTransform.replace(find: "", with: "x", regex: true, ignoreCase: false)
        #expect(try run(transform, ["a.txt"]) == ["a.txt"])
    }

    @Test func numberingCountsFromOneAndPads() throws {
        let lines = (1...10).map { "f\($0).png" }
        let numbered = try run(.number(template: "trip {n:3}"), lines)
        #expect(numbered.first == "trip 001.png")
        #expect(numbered.last == "trip 010.png")
        #expect(try run(.number(template: "{n}-{name}"), ["a.txt", "b"]) == ["1-a.txt", "2-b"])
    }

    @Test func aWidthNarrowerThanTheNumberIsNoLimit() throws {
        let lines = Array(repeating: "x", count: 12)
        #expect(try run(.number(template: "{n:1}"), lines).last == "12")
    }

    @Test func aBadTemplateSaysWhy() {
        #expect(throws: RenameTransform.Invalid.self) { try run(.number(template: "{n"), ["a"]) }
        #expect(throws: RenameTransform.Invalid(message: "\u{201C}{x}\u{201D} is not {name}, {n} or {n:3}")) {
            try run(.number(template: "{x}"), ["a"])
        }
    }

    @Test func anEmptyLineStaysEmpty() throws {
        #expect(try run(.number(template: "{n}"), ["a", "", "c"]) == ["1", "", "3"])
    }
}
