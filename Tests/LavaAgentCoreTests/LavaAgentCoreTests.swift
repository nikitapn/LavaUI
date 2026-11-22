import Foundation
import XCTest
@testable import LavaAgentCore

final class ClaudeStreamTests: XCTestCase {
    private func event(_ json: String) -> AgentEvent { AgentEvent.claude(Data(json.utf8)) }

    /// Shapes as `claude` 2.1 printed them (see the session that wrote this).
    func testEventsFromTheCLI() {
        XCTAssertEqual(event(#"{"type":"system","subtype":"init","session_id":"s1","model":"claude-haiku-5-5","tools":[]}"#),
                       .started(session: "s1", model: "claude-haiku-5-5"))
        XCTAssertEqual(event(#"{"type":"system","subtype":"status","status":"x","session_id":"s1"}"#), .ignored)
        XCTAssertEqual(event(#"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#),
                       .textBlock)
        XCTAssertEqual(event(#"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}}"#),
                       .text("hi"))
        XCTAssertEqual(event(#"{"type":"stream_event","parent_tool_use_id":"t9","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"sub"}}}"#),
                       .ignored, "a subagent's text is not the reply")
        XCTAssertEqual(event(#"{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"x"},{"type":"tool_use","name":"Read","input":{"file_path":"/a/b.swift"}}]}}"#),
                       .tool(name: "Read", detail: "/a/b.swift"))
        XCTAssertEqual(event(#"{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"x"}]}}"#), .ignored)
        XCTAssertEqual(event(#"{"type":"result","subtype":"success","is_error":false,"result":"hi","total_cost_usd":0.01}"#),
                       .finished(isError: false, message: "hi", costUSD: 0.01))
        XCTAssertEqual(event("not json"), .ignored)
    }

    func testUserMessageIsOneLineOfJSON() throws {
        let data = ClaudeInput.userMessage("line one\nline \"two\"")
        XCTAssertEqual(data.last, UInt8(ascii: "\n"))
        XCTAssertEqual(data.filter { $0 == UInt8(ascii: "\n") }.count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
        XCTAssertEqual((object["message"] as? [String: Any])?["content"] as? String, "line one\nline \"two\"")
    }

    func testLineBufferKeepsPartialLines() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(buffer.append(Data("1}\n\n{\"b\":2}\n{\"c\"".utf8)).map { String(decoding: $0, as: UTF8.self) },
                       [#"{"a":1}"#, #"{"b":2}"#])
        XCTAssertEqual(buffer.append(Data(":3}\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, [#"{"c":3}"#])
    }
}

final class InlineChatPromptTests: XCTestCase {
    func testFindsTheLastReplaceBlock() {
        let reply = """
            First idea:
            ```replace
            old idea
            ```
            Better:
            ```swift replace
            let a = 1
              let b = 2

            ```
            And an example that is not a proposal:
            ```swift
            print(a)
            ```
            """
        XCTAssertEqual(InlineChatPrompt.proposedReplacement(in: reply), "let a = 1\n  let b = 2\n")
        XCTAssertNil(InlineChatPrompt.proposedReplacement(in: "```swift\nx\n```"))
        XCTAssertNil(InlineChatPrompt.proposedReplacement(in: "```replace\nunterminated"))
    }

    func testALongerFenceHoldsBackticks() {
        let reply = "````replace\nlet s = \"```\"\n````\n"
        XCTAssertEqual(InlineChatPrompt.proposedReplacement(in: reply), "let s = \"```\"")
        XCTAssertTrue(InlineChatPrompt.question("q", path: "a.md", lines: 1...1, language: "markdown", text: "```x```")
            .contains("````markdown"))
    }

    func testQuestionSaysWhere() {
        let text = InlineChatPrompt.question("Why?", path: "Sources/a.swift", lines: 3...5, language: "swift", text: "x")
        XCTAssertTrue(text.hasPrefix("Sources/a.swift, lines 3-5"))
        XCTAssertTrue(text.contains("\n\nWhy?\n\n"))
        XCTAssertTrue(text.hasSuffix(InlineChatPrompt.reminder))
    }
}

final class ClaudeSessionsTests: XCTestCase {
    func testFolderName() {
        XCTAssertEqual(ClaudeSessions.folderName(for: URL(fileURLWithPath: "/home/a/Hello-World")), "-home-a-Hello-World")
        XCTAssertEqual(ClaudeSessions.folderName(for: URL(fileURLWithPath: "/tmp/x.y_z")), "-tmp-x-y-z")
    }

    func testListsNewestFirstWithTheBestTitle() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("lava-agent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let project = URL(fileURLWithPath: "/work/repo")
        let folder = home.appendingPathComponent("projects/" + ClaudeSessions.folderName(for: project))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ id: String, _ lines: [String], age: TimeInterval) throws {
            let file = folder.appendingPathComponent(id + ".jsonl")
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
        }
        let a = UUID().uuidString.lowercased(), b = UUID().uuidString.lowercased(), c = UUID().uuidString.lowercased()
        try write(a, [#"{"type":"user","cwd":"/work/repo","message":{"content":"hi"}}"#,
                      #"{"type":"ai-title","aiTitle":"Generated"}"#,
                      #"{"type":"custom-title","customTitle":"Mine"}"#], age: 100)
        try write(b, [#"{"type":"user","cwd":"/work/repo-wt","message":{"content":"hi"}}"#,
                      #"{"type":"last-prompt","lastPrompt":"fix the\nbug"}"#], age: 10)
        try write(c, [#"{"type":"mode","mode":"x"}"#], age: 1)
        try "x".write(to: folder.appendingPathComponent("not-a-session.jsonl"), atomically: true, encoding: .utf8)

        let sessions = ClaudeSessions.list(in: [project], home: home)
        XCTAssertEqual(sessions.map(\.id), [b, a], "newest first; one with no conversation is left out")
        XCTAssertEqual(sessions.map(\.title), ["fix the bug", "Mine"])
        XCTAssertEqual(sessions[0].directory.path, "/work/repo-wt", "resumed where it ran")
    }

    func testTailStartingMidLineSkipsThatLine() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lava-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let text = String(repeating: #"{"type":"user","message":{"content":"padding"}}"# + "\n", count: 50)
            + #"{"type":"ai-title","aiTitle":"At the end"}"# + "\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let summary = ClaudeSessions.summarize(file, size: text.utf8.count, tailBytes: 120)
        XCTAssertEqual(summary?.title, "At the end")
    }
}

final class TextLinesTests: XCTestCase {
    let text = "zero\none\ntwo\nthree"

    func testSelectionToLines() {
        XCTAssertEqual(TextLines.lines(in: text, from: 0, to: 0), 0...0)
        XCTAssertEqual(TextLines.lines(in: text, from: 6, to: 6), 1...1, "a caret is its line")
        XCTAssertEqual(TextLines.lines(in: text, from: 12, to: 6), 1...2, "either direction")
        XCTAssertEqual(TextLines.lines(in: text, from: 5, to: 13), 1...2, "ending at a line start leaves that line out")
        XCTAssertEqual(TextLines.lines(in: text, from: 14, to: 19), 3...3)
        XCTAssertEqual(TextLines.lines(in: text, from: 19, to: 19), 3...3, "the caret at the very end")
        XCTAssertEqual(TextLines.lines(in: "a\n", from: 2, to: 2), 1...1)
    }

    func testRangesTextAndReplacing() {
        XCTAssertEqual(TextLines.characterRange(of: 1...2, in: text), 5..<12)
        XCTAssertEqual(TextLines.text(of: 1...2, in: text), "one\ntwo")
        XCTAssertEqual(TextLines.text(of: 3...3, in: text), "three")
        XCTAssertEqual(TextLines.text(of: 0...0, in: text), "zero")
        XCTAssertNil(TextLines.text(of: 4...4, in: text))
        XCTAssertEqual(TextLines.replacing(1...2, in: text, with: "ONE"), "zero\nONE\nthree")
        XCTAssertEqual(TextLines.text(of: 1...1, in: "a\r\nb\r\nc"), "b", "CRLF is one character")
        XCTAssertEqual(TextLines.text(of: 1...1, in: "a\n"), "")
    }
}

final class CodexTests: XCTestCase {
    private func events(_ json: String) -> [AgentEvent] { AgentEvent.codex(Data(json.utf8)) }

    /// Shapes as `codex exec --json` 0.171 printed them.
    func testEventsFromTheCLI() {
        XCTAssertEqual(events(#"{"type":"thread.started","thread_id":"t1"}"#), [.started(session: "t1", model: "")])
        XCTAssertEqual(events(#"{"type":"turn.started"}"#), [])
        XCTAssertEqual(events(#"{"type":"item.started","item":{"id":"item_0","type":"command_execution","command":"/usr/bin/zsh -lc \"rg -n foo a.swift\"","status":"in_progress"}}"#),
                       [.tool(name: "Ran", detail: "rg -n foo a.swift")])
        XCTAssertEqual(events(#"{"type":"item.completed","item":{"id":"item_0","type":"command_execution","command":"x"}}"#), [])
        XCTAssertEqual(events(#"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"func"}}"#),
                       [.textBlock, .text("func")])
        XCTAssertEqual(events(#"{"type":"turn.completed","usage":{}}"#), [.finished(isError: false, message: nil, costUSD: nil)])
        XCTAssertEqual(events(#"{"type":"turn.failed","error":{"message":"quota"}}"#), [.finished(isError: true, message: "quota", costUSD: nil)])
        XCTAssertEqual(events("nope"), [])
    }

    func testListsUserSessionsHereWithNames() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("lava-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let day = home.appendingPathComponent("sessions/2026/11/22")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        func rollout(_ id: String, cwd: String, source: String, age: TimeInterval) throws {
            let meta = #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","thread_source":"\#(source)","base_instructions":{"text":"\#(String(repeating: "x", count: 40_000))"}}}"#
            let file = day.appendingPathComponent("rollout-2026-11-22T00-00-00-\(id).jsonl")
            try (meta + "\n" + #"{"type":"event_msg","payload":{}}"# + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
        }
        try rollout("a", cwd: "/work/repo", source: "user", age: 50)
        try rollout("b", cwd: "/work/repo", source: "user", age: 5)
        try rollout("c", cwd: "/work/repo", source: "guardian_review", age: 1)
        try rollout("d", cwd: "/elsewhere", source: "user", age: 1)
        try """
            {"id":"a","thread_name":"Old name","updated_at":"1"}
            {"id":"a","thread_name":"Fonts","updated_at":"2"}
            """.write(to: home.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        try """
            {"session_id":"b","ts":1,"text":"first"}
            {"session_id":"b","ts":2,"text":"commit please"}
            """.write(to: home.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8)

        let sessions = CodexSessions.list(in: [URL(fileURLWithPath: "/work/repo")], home: home)
        XCTAssertEqual(sessions.map(\.id), ["b", "a"])
        XCTAssertEqual(sessions.map(\.title), ["commit please", "Fonts"])
        XCTAssertEqual(sessions.first?.agent, .codex)
    }
}

final class SessionTitleTests: XCTestCase {
    func testAPromptThisChatWroteIsShortened() {
        let prompt = InlineChatPrompt.question("Why the +?\nAnd the label?", path: "Sources/a.swift", lines: 3...5,
                                               language: "swift", text: "let a = 1\n```inner```")
        XCTAssertEqual(InlineChatPrompt.title(prompt), "Sources/a.swift:3-5 · Why the +? And the label?")
        XCTAssertEqual(InlineChatPrompt.title(InlineChatPrompt.instructions + "\n\n" + prompt),
                       "Sources/a.swift:3-5 · Why the +? And the label?", "Codex's first message leads with them")
        XCTAssertEqual(InlineChatPrompt.title("fix the\nbuild"), "fix the build")
    }

    func testCodexFirstPromptSkipsInjectedContext() {
        let head = [
            #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"x"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd</environment_context>"}]}}"#,
            ##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions"}]}}"##,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Read a.swift please"}]}}"#,
        ].joined(separator: "\n")
        XCTAssertEqual(CodexSessions.firstPrompt(in: Data(head.utf8)), "Read a.swift please")
    }
}

final class TranscriptTests: XCTestCase {
    private func claude(_ json: String) -> [TranscriptEntry] { TranscriptParser.claude(Data(json.utf8)) }
    private func codex(_ json: String) -> [TranscriptEntry] { TranscriptParser.codex(Data(json.utf8)) }

    /// Shapes as Claude Code 2.1 writes them.
    func testClaudeEntries() {
        XCTAssertEqual(claude(#"{"type":"user","message":{"content":"yeah sure"}}"#), [TranscriptEntry(.user, "yeah sure")])
        XCTAssertEqual(claude(#"{"type":"user","message":{"content":[{"type":"text","text":"fix it [Image #1]"},{"type":"image","source":{}}]}}"#),
                       [TranscriptEntry(.user, "fix it [Image #1]")])
        XCTAssertEqual(claude(#"{"type":"user","isMeta":true,"message":{"content":[{"type":"text","text":"[Image: source: /x.png]"}]}}"#), [])
        XCTAssertEqual(claude(#"{"type":"user","message":{"content":"<local-command-caveat>x</local-command-caveat>"}}"#), [])
        XCTAssertEqual(claude(#"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#), [])
        XCTAssertEqual(claude(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#), [])
        XCTAssertEqual(claude(#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":""}]}}"#), [])
        XCTAssertEqual(claude(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}"#), [TranscriptEntry(.assistant, "Done.")])
        XCTAssertEqual(claude(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"swift build\nswift test"}}]}}"#),
                       [TranscriptEntry(.tool, "Bash swift build swift test")])
        XCTAssertEqual(claude(#"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"sub"}]}}"#), [])
        let followUp = InlineChatPrompt.followUp("Also uppercase it")
        let line = try! JSONSerialization.data(withJSONObject: ["type": "user", "message": ["content": followUp]])
        XCTAssertEqual(TranscriptParser.claude(line), [TranscriptEntry(.user, "Also uppercase it")],
                       "the inline chat's reminder is the agent's business")
    }

    /// Shapes as Codex 0.171 writes them.
    func testCodexEntries() {
        XCTAssertEqual(codex(#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}"#), [])
        XCTAssertEqual(codex(#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"commit please"}]}}"#),
                       [TranscriptEntry(.user, "commit please")])
        XCTAssertEqual(codex(#"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"rules"}]}}"#), [])
        XCTAssertEqual(codex(#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Committed."}]}}"#),
                       [TranscriptEntry(.assistant, "Committed.")])
        XCTAssertEqual(codex(#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"text((await tools.exec_command({cmd:`rg -n Font canvas/src | head`})).output)"}}"#),
                       [TranscriptEntry(.tool, "exec rg -n Font canvas/src | head")])
        XCTAssertEqual(codex(#"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"ls\"]}"}}"#),
                       [TranscriptEntry(.tool, "shell bash -lc ls")])
        XCTAssertEqual(codex(#"{"type":"response_item","payload":{"type":"reasoning","summary":[]}}"#), [])
    }

    func testTailReadsOnlyWhatWasAppended() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lava-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let padding = String(repeating: #"{"type":"user","message":{"content":"old"}}"# + "\n", count: 40)
        try (padding + #"{"type":"user","message":{"content":"recent"}}"# + "\n").write(to: file, atomically: true, encoding: .utf8)
        var tail = TranscriptTail(file: file, agent: .claude, initialBytes: 100)
        XCTAssertEqual(tail.read().map(\.text), ["old", "recent"], "the first read starts near the end, on a whole line")
        XCTAssertTrue(tail.truncated)
        XCTAssertEqual(tail.read(), [])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"assistant","message":{"content":[{"type":"text","text":"new"}]}}"#.utf8))
        XCTAssertEqual(tail.read(), [], "half a line waits for the rest")
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        XCTAssertEqual(tail.read(), [TranscriptEntry(.assistant, "new")])
    }

    func testLiveClaudeSessions() {
        let json = #"[{"pid":"13244","cwd":"/work/repo","kind":"interactive","startedAt":"1","sessionId":"s1","name":"repo-6d","status":"busy"},{"pid":"9","cwd":"/work/repo-wt","kind":"background","sessionId":"s2","status":"idle"}]"#
        let live = ClaudeLiveSession.parse(Data(json.utf8))
        XCTAssertEqual(live.map(\.session), ["s1", "s2"])
        XCTAssertEqual(live.map(\.status), [.working, .waiting])
        XCTAssertEqual(live.first?.pid, 13244)
        let background = ClaudeLiveSession.parse(Data(#"[{"pid":"950224","id":"95abe5ab","cwd":"/r/.claude/worktrees/x","kind":"background","sessionId":"95abe5ab-56fa","name":"ready-reply echo test","status":"idle","state":"done"}]"#.utf8))
        XCTAssertEqual(background.first?.isBackground, true)
        XCTAssertEqual(background.first?.attachName, "95abe5ab")
    }

    func testCodexTurnState() {
        func lines(_ kinds: [String]) -> [Data] {
            kinds.map { Data(#"{"type":"event_msg","payload":{"type":"\#($0)"}}"#.utf8) }
        }
        XCTAssertFalse(CodexSessions.turnOpen(lines: []))
        XCTAssertTrue(CodexSessions.turnOpen(lines: lines(["task_started", "token_count"])))
        XCTAssertFalse(CodexSessions.turnOpen(lines: lines(["task_started", "task_complete"])))
        XCTAssertFalse(CodexSessions.turnOpen(lines: lines(["task_started", "turn_aborted"])))
        XCTAssertTrue(CodexSessions.turnOpen(lines: lines(["task_started", "task_complete", "task_started"])))
    }
}

final class InPlaceTests: XCTestCase {
    func testTailFromEndSeesOnlyWhatComesAfter() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lava-end-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try (#"{"type":"user","message":{"content":"before"}}"# + "\n").write(to: file, atomically: true, encoding: .utf8)
        var tail = TranscriptTail(file: file, agent: .claude, fromEnd: true)
        XCTAssertEqual(tail.read(), [])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"assistant","message":{"content":[{"type":"text","text":"after"}]}}"# + "\n").utf8))
        try handle.close()
        XCTAssertEqual(tail.read(), [TranscriptEntry(.assistant, "after")])
    }

    func testEntriesAsReplyEventsAndEdits() {
        XCTAssertEqual(TranscriptEntry(.user, "q").event, [])
        XCTAssertEqual(TranscriptEntry(.assistant, "hi").event, [.textBlock, .text("hi")])
        XCTAssertEqual(TranscriptEntry(.tool, "Read /a/b.swift").event, [.tool(name: "Read", detail: "/a/b.swift")])
        XCTAssertEqual(TranscriptEntry(.tool, "Edit /a/b c.swift").editedPaths, ["/a/b c.swift"])
        XCTAssertEqual(TranscriptEntry(.tool, "Read /a/b.swift").editedPaths, [])
        let patch = #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch\n*** Update File: Sources/a.swift\n@@\n-x\n+y\n*** Add File: b.swift\n+z\n*** End Patch"}}"#
        let entries = TranscriptParser.codex(Data(patch.utf8))
        XCTAssertEqual(entries.flatMap(\.editedPaths), ["Sources/a.swift", "b.swift"])
    }

    func testQuestionWithoutReminder() {
        let text = InlineChatPrompt.question("Why?", path: "a.swift", lines: 1...1, language: "swift", text: "x", reminder: false)
        XCTAssertTrue(text.hasSuffix("Why?"))
        XCTAssertFalse(text.contains(InlineChatPrompt.reminder))
    }
}
