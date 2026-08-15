import XCTest

@testable import TraceLoomCore

final class WorkspaceTests: XCTestCase {
    private func document(
        _ name: String, path: String, rules: String = "line | rate | x (\\d+) | 1 | 1 | -"
    ) -> WorkspaceDocument {
        WorkspaceDocument(name: name, path: path, rules: rules)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("traceloom-test-\(UUID().uuidString)")
            .appendingPathExtension(Workspace.fileExtension)
    }

    func testRoundTripsThroughAFile() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        var workspace = Workspace(
            documents: [
                document("app.log", path: "/var/log/app.log"),
                document("boot.log", path: "/var/log/boot.log", rules: "# nothing yet"),
            ],
            activeIndex: 1
        )
        workspace.documents[0].zoomStart = 1_000
        workspace.documents[0].zoomEnd = 2_500
        workspace.documents[1].position = WorkspaceDocument.Position(
            scrollX: 0, scrollY: 480, anchor: 12, focus: 40
        )

        try workspace.write(to: url)
        XCTAssertEqual(try Workspace.read(at: url), workspace)
    }

    /// The rules are the part that only exists in the workspace — a log can be
    /// reopened, the afternoon spent working out its regexes cannot.
    func testRulesAreStoredInFullAndLogsOnlyByPath() throws {
        let workspace = Workspace(
            documents: [document("app.log", path: "/var/log/app.log", rules: "step | phase | ^(\\d+) start | 1 | - | -")]
        )
        let json = try XCTUnwrap(String(data: workspace.encoded(), encoding: .utf8))

        XCTAssertTrue(json.contains("step | phase"))
        XCTAssertTrue(json.contains("/var/log/app.log"))
        // Unescaped, so a path in a saved workspace is readable and greppable.
        XCTAssertFalse(json.contains("\\/var"))
    }

    func testActiveIndexIsClampedRatherThanRejected() throws {
        let json = """
            {"version":1,"activeIndex":7,"documents":[\
            {"name":"a.log","path":"/tmp/a.log","rules":""}]}
            """
        let workspace = try Workspace.decode(Data(json.utf8))
        XCTAssertEqual(workspace.activeIndex, 0)
    }

    func testEmptyWorkspaceDecodesToNoDocuments() throws {
        let json = #"{"version":1,"activeIndex":0,"documents":[]}"#
        let workspace = try Workspace.decode(Data(json.utf8))
        XCTAssertTrue(workspace.documents.isEmpty)
        XCTAssertEqual(workspace.activeIndex, 0)
    }

    /// Zoom and editor position are optional so that a workspace written
    /// before they existed — and one for a log that was never opened — still
    /// loads.
    func testOptionalStateMayBeAbsent() throws {
        let json = """
            {"version":1,"activeIndex":0,"documents":[\
            {"name":"a.log","path":"/tmp/a.log","rules":"# rules"}]}
            """
        let workspace = try Workspace.decode(Data(json.utf8))
        let document = try XCTUnwrap(workspace.documents.first)
        XCTAssertNil(document.zoomStart)
        XCTAssertNil(document.position)
        XCTAssertEqual(document.rules, "# rules")
    }

    func testAFutureVersionIsRefusedByName() throws {
        let json = #"{"version":99,"activeIndex":0,"documents":[]}"#
        XCTAssertThrowsError(try Workspace.decode(Data(json.utf8), path: "/tmp/w.traceloom")) {
            XCTAssertEqual(
                $0 as? Workspace.LoadError,
                .unsupportedVersion(path: "/tmp/w.traceloom", version: 99, supported: 1)
            )
        }
    }

    func testGarbageIsAMalformedWorkspaceNotACrash() throws {
        XCTAssertThrowsError(try Workspace.decode(Data("not json".utf8), path: "/tmp/w")) {
            guard case .malformed = $0 as? Workspace.LoadError else {
                return XCTFail("expected .malformed, got \($0)")
            }
        }
    }

    func testAMissingFileIsReportedWithItsPath() throws {
        let url = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).traceloom")
        XCTAssertThrowsError(try Workspace.read(at: url)) {
            guard case let .unreadable(path, _) = $0 as? Workspace.LoadError else {
                return XCTFail("expected .unreadable, got \($0)")
            }
            XCTAssertEqual(path, url.path)
        }
    }
}
