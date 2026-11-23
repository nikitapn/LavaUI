import Foundation
import XCTest
@testable import LavaAgentCore

final class CodexAppServerTests: XCTestCase {
    func testDiscoversSessionsAcrossPagesAndReadsPaginatedHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        try #"""
        #!/bin/sh
        if [ "$2" = "proxy" ]; then
            # Keep the connection open without acknowledging initialize.
            while IFS= read -r line; do :; done
            exit
        fi
        [ "$2" = "--stdio" ] || exit 1
        while IFS= read -r line; do
            case "$line" in
                *'"method":"initialize"'*)
                    echo '{"id":1,"result":{}}'
                    ;;
                *'"method":"thread/list"'*'"cursor":"second"'*|*'"cursor":"second"'*'"method":"thread/list"'*)
                    echo '{"id":3,"result":{"data":[{"id":"main","cwd":"/work/repo","updatedAt":10,"preview":"A saved session"}]}}'
                    ;;
                *'"method":"thread/list"'*)
                    echo '{"method":"thread/status/changed","params":{}}'
                    echo '{"id":2,"result":{"nextCursor":"second","data":[{"id":"nested","cwd":"/work/repo/worktree/Sources","updatedAt":20,"name":"Nested session","status":{"type":"active","activeFlags":["waitingOnApproval"]}},{"id":"other","cwd":"/work/repo-other","updatedAt":30}]}}'
                    ;;
                *'"method":"thread/items/list"'*)
                    echo '{"id":2,"result":{"nextCursor":"older","data":[{"item":{"type":"agentMessage","text":"Reply"}},{"item":{"type":"userMessage","content":[{"type":"text","text":"Question"}]}}]}}'
                    ;;
            esac
        done
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let server = CodexAppServer(executable: executable)
        let start = ProcessInfo.processInfo.systemUptime
        let sessions = try XCTUnwrap(server.sessions(in: [URL(fileURLWithPath: "/work/repo")]))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2, "A stalled proxy delayed the stdio fallback")
        XCTAssertEqual(sessions.map(\.agent.id), ["nested", "main"])
        XCTAssertEqual(sessions.first?.status, .waiting)
        XCTAssertNil(sessions.first?.agent.file)

        let history = try XCTUnwrap(server.transcript(threadID: "nested", limit: 10))
        XCTAssertTrue(history.truncated)
        XCTAssertEqual(history.entries, [TranscriptEntry(.user, "Question"), TranscriptEntry(.assistant, "Reply")])
    }
}
