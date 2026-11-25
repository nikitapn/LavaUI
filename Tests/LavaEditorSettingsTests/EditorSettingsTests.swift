import Foundation
import XCTest
@testable import LavaEditorSettings

final class EditorSettingsTests: XCTestCase {
    private let user = URL(fileURLWithPath: "/config/LavaEditor/editor.json")
    private let folder = URL(fileURLWithPath: "/project/.lava/settings.json")

    func testLayersAndLeafProvenance() throws {
        let settings = try merged(
            user: #"{"editor": {"fontFamily": "Fira Code", "wordWrap": true}}"#,
            folder: """
            {
              "editor": {
                "wordWrap": false,
                "fontSize": 15.5
              }
            }
            """
        )
        XCTAssertEqual(settings.editor.fontFamily, "Fira Code")
        XCTAssertEqual(settings.editor.fontSize, 15.5)
        XCTAssertFalse(settings.editor.wordWrap)
        XCTAssertEqual(settings.editor.lineHeight, 1.5)
        XCTAssertTrue(settings.editor.lineNumbers)
        XCTAssertTrue(settings.editor.highlightChangedLines)
        XCTAssertTrue(settings.editor.insertSpaces)
        XCTAssertEqual(settings.editor.tabSize, 4)
        XCTAssertEqual(settings.origin(at: ["editor", "fontFamily"])?.layer, .user)
        XCTAssertEqual(settings.origin(at: ["editor", "wordWrap"]), .init(
            layer: .folder, location: .init(file: folder, line: 3, column: 5)
        ))
        XCTAssertEqual(settings.origin(at: ["editor", "lineHeight"]), .init(layer: .defaults, location: nil))
        XCTAssertNil(settings.origin(at: ["editor", "missing"]))
        XCTAssertTrue(settings.diagnostics.isEmpty)
    }

    func testLanguageIndentationMergesByFieldAndInheritsEditorDefaults() throws {
        let settings = try merged(
            user: #"{"editor":{"tabSize":8,"insertSpaces":false,"languages":{"swift":{"tabSize":4,"insertSpaces":true},"cpp":{"tabSize":2}}}}"#,
            folder: #"{"editor":{"tabSize":6,"languages":{"cpp":{"insertSpaces":true},"swift":{"tabSize":3}}}}"#
        )
        XCTAssertEqual(settings.editor.indentation(for: "swift"), .init(tabSize: 3, insertSpaces: true))
        XCTAssertEqual(settings.editor.indentation(for: "cpp"), .init(tabSize: 2, insertSpaces: true))
        XCTAssertEqual(settings.editor.indentation(for: "c"), .init(tabSize: 6, insertSpaces: false))
        XCTAssertEqual(settings.origin(at: ["editor", "languages", "cpp", "tabSize"])?.layer, .user)
        XCTAssertEqual(settings.origin(at: ["editor", "languages", "cpp", "insertSpaces"])?.layer, .folder)
        XCTAssertTrue(settings.diagnostics.isEmpty)
    }

    func testInvalidLanguageIndentationFallsBackToGeneralSettings() throws {
        let settings = try merged(
            user: #"{"editor":{"tabSize":2,"insertSpaces":false,"languages":{"cpp":{"tabSize":33,"insertSpaces":"yes"},"swift":false}}}"#,
            folder: "{}"
        )
        XCTAssertEqual(settings.editor.indentation(for: "cpp"), .init(tabSize: 2, insertSpaces: false))
        XCTAssertEqual(settings.editor.indentation(for: "swift"), .init(tabSize: 2, insertSpaces: false))
        XCTAssertEqual(settings.diagnostics.filter { $0.severity == .error }.count, 3)
    }

    func testObjectsMergeRecursivelyAndArraysReplace() throws {
        let settings = try merged(
            user: #"{"lsp":{"servers":{"clangd":{"settings":{"flags":["a","b"],"nested":{"first":1,"second":2}}}}}}"#,
            folder: #"{"lsp":{"servers":{"clangd":{"settings":{"flags":["c"],"nested":{"second":3}}}}}}"#
        )
        XCTAssertEqual(settings.servers["clangd"]?.settings, .object([
            "flags": .array([.string("c")]),
            "nested": .object(["first": .number("1"), "second": .number("3")]),
        ]))
        let settingsPath = ["lsp", "servers", "clangd", "settings"]
        XCTAssertEqual(settings.origin(at: settingsPath + ["flags", "0"])?.layer, .folder)
        XCTAssertNil(settings.origin(at: settingsPath + ["flags", "1"]))
        XCTAssertEqual(settings.origin(at: settingsPath + ["nested", "first"])?.layer, .user)
        XCTAssertEqual(settings.origin(at: settingsPath + ["nested", "second"])?.layer, .folder)
    }

    func testReportsSyntaxErrorAtItsPosition() throws {
        let source = "{\r\n  \"editor\": {\r\n    \"fontSize\": ]\r\n  }\r\n}"
        XCTAssertThrowsError(try parse(source, at: user)) { error in
            XCTAssertEqual(error as? SettingsDiagnostic, .init(
                severity: .error, location: .init(file: user, line: 3, column: 17),
                message: "Expected a JSON value"
            ))
        }
    }

    func testJSONWithLineCommentsAndTrailingCommas() throws {
        let document = try parse(
            #"""
            { // Menu toggles rewrite comments.
              "url": "https://example.test/\"quoted\"",
              "values": [true, null, -1.2e+5,],
            }
            """#, at: user
        )
        XCTAssertEqual(document.value, .object([
            "url": .string("https://example.test/\"quoted\""),
            "values": .array([.bool(true), .null, .number("-1.2e+5")]),
        ]))
    }

    func testRejectsMalformedJSON() {
        for text in [#"{"key":01}"#, #"{"key":1e}"#, #"{"key":"\u000X"}"#, #"{"key":1 "other":2}"#,
                     #"{"key":1,"key":2}"#, "{,}", #"{"key":[,]}"#, "true", "{} []"] {
            XCTAssertThrowsError(try parse(text, at: user), text)
        }
    }

    func testValidationFallsBackToDefaultsAndWarnsOnUnknownKeys() throws {
        let settings = try merged(
            user: #"{"editor":{"fontSize":20,"wordWrap":true}}"#,
            folder: """
            {
              "editor": {
                "fontSize": "large",
                "wordWrap": 1,
                "lineHeight": -1,
                "tabSize": 2.5,
                "insertSpaces": "yes",
                "lineColours": true
              }
            }
            """
        )
        XCTAssertEqual(settings.editor, .defaults)
        XCTAssertEqual(settings.origin(at: ["editor", "fontSize"])?.layer, .defaults)
        XCTAssertEqual(settings.configuredOrigin(at: ["editor", "fontSize"])?.layer, .folder)
        XCTAssertEqual(settings.diagnostics.filter { $0.severity == .error }.count, 5)
        XCTAssertEqual(settings.diagnostics.filter { $0.severity == .warning }, [
            .init(severity: .warning, location: .init(file: folder, line: 8, column: 5),
                  message: "Unknown setting editor.lineColours"),
        ])
    }

    func testMissingKeysAfterAnObjectReplacesAScalarHaveDefaultProvenance() throws {
        let settings = try merged(user: #"{"editor":null}"#, folder: #"{"editor":{"fontSize":20}}"#)
        XCTAssertEqual(settings.editor.fontSize, 20)
        XCTAssertEqual(settings.origin(at: ["editor", "lineNumbers"])?.layer, .defaults)
    }

    func testFolderMayConfigureOnlyTrustedServersAndAllowedFields() throws {
        let settings = try merged(
            user: """
            {"lsp":{"servers":{
              "sourcekit-lsp":{"command":["/user/sourcekit-lsp","--verbose"]},
              "custom":{"command":["custom"],"languages":["text"],"enabled":false}
            }}}
            """,
            folder: """
            {"lsp":{"servers":{
              "sourcekit-lsp":{"command":["/project/script"],"enabled":false,"initializationOptions":{"index":false}},
              "clangd":{"executable":"script","args":["run"],"rootMarkers":["other"],"languages":["test"]},
              "custom":{"enabled":true,"settings":{"lsp":{"diagnostics":true}}},
              "unknown":{"command":["script"],"enabled":true}
            }}}
            """
        )
        let swift = try XCTUnwrap(settings.servers["sourcekit-lsp"])
        XCTAssertFalse(swift.enabled)
        XCTAssertEqual(swift.command, ["/user/sourcekit-lsp", "--verbose"])
        XCTAssertEqual(swift.languages, ["swift"])
        XCTAssertEqual(swift.rootMarkers, ["Package.swift", ".git"])
        XCTAssertEqual(swift.initializationOptions, .object(["index": .bool(false)]))
        XCTAssertEqual(settings.servers["clangd"]?.command, ["clangd"])
        XCTAssertEqual(settings.servers["clangd"]?.languages, ["c", "cpp", "objective-c"])
        XCTAssertEqual(settings.servers["clangd"]?.rootMarkers, ["compile_commands.json", "compile_flags.txt", ".git"])
        XCTAssertEqual(settings.servers["custom"]?.enabled, true)
        XCTAssertEqual(settings.origin(at: ["lsp", "servers", "custom", "rootMarkers"])?.layer, .defaults)
        XCTAssertEqual(settings.servers["custom"]?.settings, .object(["lsp": .object(["diagnostics": .bool(true)])]))
        XCTAssertNil(settings.servers["unknown"])
        XCTAssertEqual(settings.origin(at: ["lsp", "servers", "sourcekit-lsp", "command"])?.layer, .user)
        XCTAssertEqual(settings.origin(at: ["lsp", "servers", "sourcekit-lsp", "enabled"])?.layer, .folder)
        XCTAssertNil(settings.origin(at: ["lsp", "servers", "clangd", "executable"]))
        XCTAssertEqual(settings.diagnostics.count, 7)
        XCTAssertTrue(settings.diagnostics.allSatisfy { $0.severity == .warning && $0.location.file == folder })
    }

    func testMalformedFolderLSPContainersCannotMaskUserCommands() throws {
        for source in [
            #"{"lsp": false}"#, #"{"lsp":{"servers":[]}}"#, #"{"lsp":{"servers":{"clangd":"./script"}}}"#,
        ] {
            let settings = try merged(user: #"{"lsp":{"servers":{"clangd":{"command":["/trusted/clangd"]}}}}"#,
                                      folder: source)
            XCTAssertEqual(settings.servers["clangd"]?.command, ["/trusted/clangd"])
            XCTAssertEqual(settings.diagnostics.first?.severity, .error)
            XCTAssertEqual(settings.diagnostics.first?.location.file, folder)
        }
    }

    func testMalformedUserLSPValuesFallBackToBuiltIns() throws {
        let settings = try merged(
            user: #"{"lsp":{"servers":{"sourcekit-lsp":false,"clangd":{"command":[true],"enabled":0}}}}"#,
            folder: #"{"lsp":{"servers":{"sourcekit-lsp":{"enabled":false}}}}"#
        )
        XCTAssertEqual(settings.servers["sourcekit-lsp"]?.command, ["sourcekit-lsp"])
        XCTAssertEqual(settings.servers["sourcekit-lsp"]?.enabled, false)
        XCTAssertEqual(settings.servers["clangd"]?.command, ["clangd"])
        XCTAssertEqual(settings.servers["clangd"]?.enabled, true)
        XCTAssertEqual(settings.origin(at: ["lsp", "servers", "clangd", "command"])?.layer, .defaults)
        XCTAssertEqual(settings.diagnostics.filter { $0.severity == .error }.count, 3)
    }

    func testLoaderKeepsLastGoodLayerIndependentlyAndHandlesRemoval() throws {
        try withTemporaryFiles { user, folder in
            try write(#"{"editor":{"fontSize":18}}"#, to: user)
            try write(#"{"editor":{"wordWrap":true}}"#, to: folder)
            var loader = EditorSettingsLoader()
            XCTAssertTrue(loader.load(user: user, folder: folder).1.isEmpty)

            try write("{", to: user)
            try write(#"{"editor":{"wordWrap":false, "tabSize":2}}"#, to: folder)
            var (settings, diagnostics) = loader.load(user: user, folder: folder)
            XCTAssertEqual(settings.editor.fontSize, 18)
            XCTAssertFalse(settings.editor.wordWrap)
            XCTAssertEqual(settings.editor.tabSize, 2)
            XCTAssertEqual(diagnostics.first?.location.file, user)

            try write(#"{"editor":{"fontSize":19}}"#, to: user)
            try write("{", to: folder)
            (settings, diagnostics) = loader.load(user: user, folder: folder)
            XCTAssertEqual(settings.editor.fontSize, 19)
            XCTAssertEqual(settings.editor.tabSize, 2)
            XCTAssertEqual(diagnostics.first?.location.file, folder)

            try FileManager.default.removeItem(at: folder)
            (settings, diagnostics) = loader.load(user: user, folder: folder)
            XCTAssertEqual(settings.editor.tabSize, 4)
            XCTAssertTrue(diagnostics.isEmpty)
        }
    }

    func testToggleWritesUserLayerAndPreservesUnknownKeysExactly() throws {
        try withTemporaryFiles { user, folder in
            try write("""
            { // preserved as JSON values
              "future": [9007199254740993, {"child": null}],
              "editor": {"zFuture": "keep", "lineNumbers": true, "wordWrap": false,}
            }
            """, to: user)
            let folderText = #"{"editor":{"wordWrap":true}}"#
            try write(folderText, to: folder)
            var loader = EditorSettingsLoader()
            let (before, _) = loader.load(user: user, folder: folder)
            let key = EditorToggle.wordWrap
            try UserSettingsFile.set(key, to: !key.value(in: before.editor), at: user)
            XCTAssertEqual(before.folderOverride(for: key)?.file, folder)
            XCTAssertEqual(try String(contentsOf: folder, encoding: .utf8), folderText)
            XCTAssertEqual(try String(contentsOf: user, encoding: .utf8), """
            {
              "editor": {
                "lineNumbers": true,
                "wordWrap": false,
                "zFuture": "keep"
              },
              "future": [
                9007199254740993,
                {
                  "child": null
                }
              ]
            }

            """)
            XCTAssertTrue(loader.load(user: user, folder: folder).0.editor.wordWrap)
            XCTAssertFalse(loader.load(user: user, folder: nil).0.editor.wordWrap)
        }
    }

    func testToggleLeavesAnInvalidUserFileAlone() throws {
        try withTemporaryFiles { user, _ in
            for source in ["{", #"{"editor":1,"future":true}"#] {
                try write(source, to: user)
                XCTAssertThrowsError(try UserSettingsFile.set(.lineNumbers, to: false, at: user))
                XCTAssertEqual(try String(contentsOf: user, encoding: .utf8), source)
            }
        }
    }

    func testMigrationReadsLegacyKeysOnlyUntilUserFileExists() throws {
        try withTemporaryFiles { user, folder in
            try UserSettingsFile.migrate(at: user) { _ in nil }
            XCTAssertFalse(FileManager.default.fileExists(atPath: user.path))
            try UserSettingsFile.migrate(at: user) { key in
                ["wraps": true, "lineNumbers": false, "highlightChangedLines": false][key]
            }
            let settings = EditorSettings(user: try SettingsDocument.read(at: user))
            XCTAssertTrue(settings.editor.wordWrap)
            XCTAssertFalse(settings.editor.lineNumbers)
            XCTAssertFalse(settings.editor.highlightChangedLines)
            try UserSettingsFile.migrate(at: user) { _ in
                XCTFail("A user file already exists")
                return nil
            }
            try UserSettingsFile.createIfMissing(at: folder)
            XCTAssertEqual(try String(contentsOf: folder, encoding: .utf8), "{}\n")
        }
    }

    func testFontWritePreservesUnknownKeysAndLeavesFolderOverridesInPlace() throws {
        try withTemporaryFiles { user, folder in
            try write(#"{"editor":{"wordWrap":true,"future":9007199254740993},"other":[false,null]}"#, to: user)
            let folderText = #"{"editor":{"fontSize":18}}"#
            try write(folderText, to: folder)

            try UserSettingsFile.setFont(family: "Acme \"Mono\"", size: 24, at: user)

            var loader = EditorSettingsLoader()
            let (userOnly, diagnostics) = loader.load(user: user, folder: nil)
            XCTAssertFalse(diagnostics.contains { $0.severity == .error })
            XCTAssertEqual(userOnly.editor.fontFamily, "Acme \"Mono\"")
            XCTAssertEqual(userOnly.editor.fontSize, 24)
            XCTAssertTrue(userOnly.editor.wordWrap)
            let document = try XCTUnwrap(SettingsDocument.read(at: user))
            XCTAssertEqual(document.value.object?["editor"]?.object?["future"], .number("9007199254740993"))
            XCTAssertEqual(document.value.object?["other"], .array([.bool(false), .null]))
            let (merged, _) = loader.load(user: user, folder: folder)
            XCTAssertEqual(merged.editor.fontFamily, userOnly.editor.fontFamily)
            XCTAssertEqual(merged.editor.fontSize, 18)
            XCTAssertEqual(merged.folderEditorOverride(for: "fontSize")?.file, folder)
            XCTAssertNil(merged.folderEditorOverride(for: "fontFamily"))
            XCTAssertEqual(try String(contentsOf: folder, encoding: .utf8), folderText)
        }
    }

    func testFontWriteLeavesAnInvalidUserFileAlone() throws {
        try withTemporaryFiles { user, _ in
            let source = #"{"editor":1,"future":true}"#
            try write(source, to: user)
            XCTAssertThrowsError(try UserSettingsFile.setFont(family: "Acme", size: 14, at: user))
            XCTAssertEqual(try String(contentsOf: user, encoding: .utf8), source)
        }
    }

    private func parse(_ source: String, at file: URL) throws -> SettingsDocument {
        try .parse(Data(source.utf8), at: file)
    }

    private func merged(user userText: String, folder folderText: String) throws -> EditorSettings {
        try .init(user: parse(userText, at: user), folder: parse(folderText, at: folder))
    }

    private func withTemporaryFiles(_ run: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try run(root.appendingPathComponent("editor.json"), root.appendingPathComponent("settings.json"))
    }

    private func write(_ text: String, to file: URL) throws {
        try Data(text.utf8).write(to: file, options: .atomic)
    }
}
