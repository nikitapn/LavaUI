import Foundation
import Testing
@testable import LavaLSPCore

extension LavaLSPCoreTests {
    @Test func fakeServerRoundTripsAndRestarts() async throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let events = Inbox<LSPEvent>()
        let client = fakeClient("incremental", root: workspace, events: events,
                                restart: .init(maxRetries: 1, initialDelay: 0.05))
        defer { client.stop() }
        client.start()
        let capabilities = try await ready(events)
        #expect(capabilities.positionEncoding == .utf8)
        #expect(capabilities.syncKind == .incremental)
        #expect(capabilities.supportsSemanticTokensDelta)

        let answers = try await events.take("server request replies", matching: notification("fake/answers"))
        #expect(answers["10"] == .array([.integer(7), .null, .object(["editor": .object(["option": .integer(7)])])]))
        #expect(answers["register"] == .null)
        #expect(answers["unregister"] == .null)
        #expect(answers["11"] == .null)
        #expect(answers["unknown"]?["code"] == .integer(-32601))

        let uri = workspace.appendingPathComponent("test.swift").absoluteString
        client.didOpen(uri: uri, languageID: "swift", text: "😀x", version: 10)
        let notice = try await diagnostics(events, uri: uri)
        #expect(notice.version == 10)
        #expect(notice.diagnostics.first?.severity == .warning)
        #expect(notice.diagnostics.first?.code == .string("W1"))
        #expect(notice.diagnostics.first?.source == "fake")
        #expect(notice.diagnostics.first?.message == "fixture warning")

        client.didChange(uri: uri, text: "😀yz")
        client.didChange(uri: uri, text: "stale version", version: 10)
        client.didSave(uri: uri)
        let seen: [JSON] = try await response("document notifications") {
            client.request("fake/seen", as: [JSON].self, completion: $0)
        }
        #expect(seen.count == 3)
        #expect(seen[1]["params"]?["textDocument"]?["version"] == .integer(11))
        let change = seen[1]["params"]?["contentChanges"]?.array?.first
        #expect(change?["range"]?["start"]?["character"] == .integer(4))
        #expect(change?["range"]?["end"]?["character"] == .integer(5))
        #expect(change?["text"] == .string("yz"))
        #expect(seen[2]["params"]?["text"] == .string("😀yz"))

        let echoed: Echo = try await response("echo") {
            client.request("fake/echo", params: .object(["value": .string("héllo")]), as: Echo.self, completion: $0)
        }
        #expect(echoed.value == "héllo")

        let full: DecodedSemanticTokens? = try await response("full semantic tokens") {
            client.semanticTokens(uri: uri, completion: $0)
        }
        let previous = try #require(full?.snapshot)
        #expect(full?.tokens.first?.start == 4)
        let delta: DecodedSemanticTokens? = try await response("delta semantic tokens") {
            client.semanticTokens(uri: uri, previous: previous, completion: $0)
        }
        #expect(delta?.tokens.first?.start == 6)
        #expect(delta?.snapshot.resultId == "delta")

        let cancellation = Inbox<Result<JSON, LSPClientError>>()
        let id = client.request("fake/wait", as: JSON.self, completion: cancellation.append)
        client.cancel(id)
        let cancelled = try await cancellation.take("cancelled response") { $0 }
        #expect(cancelled == .failure(.cancelled))
        _ = try await events.take("cancel received by server", matching: notification("fake/cancelled"))

        let timed = Inbox<Result<JSON, LSPClientError>>()
        client.request("fake/wait", as: JSON.self, timeout: 0.1, completion: timed.append)
        let timedOut = try await timed.take("timed out response") { $0 }
        #expect(timedOut == .failure(.timedOut))
        _ = try await events.take("timeout cancellation received by server", matching: notification("fake/cancelled"))

        let stderr = Inbox<String>()
        client.stderrLog(stderr.append)
        let log = try await stderr.take("stderr tail") { $0 }
        #expect(log.utf8.count == 64 * 1024)
        #expect(log.hasSuffix("\nready\n"))

        let outstanding = Inbox<Result<JSON, LSPClientError>>()
        client.request("fake/wait", as: JSON.self, completion: outstanding.append)
        client.notify("fake/crash")
        let exit = try await events.take("crash") { event -> ServerExit? in
            if case .exited(let exit, willRestart: true) = event { return exit }
            return nil
        }
        #expect(exit.status == 23)
        #expect(!exit.signaled)
        let failed = try await outstanding.take("in-flight crash response") { $0 }
        #expect(failed == .failure(.serverExited(exit)))
        _ = try await ready(events)
        let replay = try await diagnostics(events, uri: uri)
        #expect(replay.version == 11)
        client.didClose(uri: uri)
        let reopened: [JSON] = try await response("replayed open and close") {
            client.request("fake/seen", as: [JSON].self, completion: $0)
        }
        #expect(reopened.map { $0["method"]?.string } == ["textDocument/didOpen", "textDocument/didClose"])
        #expect(reopened.first?["params"]?["textDocument"]?["text"] == .string("😀yz"))

        let last: Echo = try await response("reply before exit") {
            client.request("fake/replyThenCrash", as: Echo.self, completion: $0)
        }
        #expect(last.value == "last reply")
        let finalExit = try await events.take("retries exhausted") { event -> ServerExit? in
            if case .exited(let exit, willRestart: false) = event { return exit }
            return nil
        }
        #expect(finalExit == exit)
    }

    @Test func fakeServerReceivesFullChangesAndCleanExit() async throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let events = Inbox<LSPEvent>()
        let client = fakeClient("full", root: workspace, events: events)
        defer { client.stop() }
        client.start()
        let capabilities = try await ready(events)
        #expect(capabilities.positionEncoding == .utf16)
        #expect(capabilities.syncKind == .full)
        let uri = workspace.appendingPathComponent("test.swift").absoluteString
        client.didOpen(uri: uri, languageID: "swift", text: "😀x")
        client.didChange(uri: uri, text: "😀y")
        let seen: [JSON] = try await response("full change") {
            client.request("fake/seen", as: [JSON].self, completion: $0)
        }
        #expect(seen.last?["params"]?["contentChanges"] == .array([.object(["text": .string("😀y")])]))
        let exit = try await stop(client, events: events)
        #expect(exit == ServerExit(status: 0, signaled: false))
    }

    @Test func fakeServerIsKilledAfterShutdownDeadline() async throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let events = Inbox<LSPEvent>()
        let client = fakeClient("hang", root: workspace, events: events)
        defer { client.stop() }
        client.start()
        _ = try await ready(events)
        let exit = try await stop(client, events: events, timeout: 0.2)
        #expect(exit == ServerExit(status: 9, signaled: true))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/sourcekit-lsp"),
                   "/usr/bin/sourcekit-lsp is absent"))
    func sourceKitLSPIntegration() async throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let directory = workspace.appendingPathComponent("Sources/Example", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Example", targets: [.target(name: "Example")])
        """
        try manifest.write(to: workspace.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try await exerciseServer(command: ["/usr/bin/sourcekit-lsp"], language: "swift", root: workspace,
                                 file: directory.appendingPathComponent("Example.swift"), text: """
                                 func helper() -> Int { 42 }
                                 let answer = helper()
                                 let broken: Int = unknownName
                                 """, definition: LSPPosition(line: 1, character: 13))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/clangd"),
                   "/usr/bin/clangd is absent"))
    func clangdIntegration() async throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "-std=c++17\n".write(to: workspace.appendingPathComponent("compile_flags.txt"),
                                atomically: true, encoding: .utf8)
        try await exerciseServer(command: ["/usr/bin/clangd", "--background-index=false"], language: "cpp",
                                 root: workspace, file: workspace.appendingPathComponent("example.cpp"), text: """
                                 int helper() { return 42; }
                                 int answer = helper();
                                 int broken = unknownName;
                                 """, definition: LSPPosition(line: 1, character: 13))
    }

    private func exerciseServer(command: [String], language: String, root: URL, file: URL,
                                text: String, definition position: LSPPosition) async throws {
        try text.write(to: file, atomically: true, encoding: .utf8)
        let events = Inbox<LSPEvent>()
        let client = LSPClient(config: .init(name: language, command: command, languages: [language]),
                               root: root, onEvent: events.append)
        defer { client.stop() }
        client.start()
        let capabilities = try await ready(events)
        client.didOpen(uri: file.absoluteString, languageID: language, text: text)
        let report = try await diagnostics(events, uri: file.absoluteString, requiringError: true)
        let diagnostic = try #require(report.diagnostics.first { $0.severity == .error })
        #expect(diagnostic.range.start.line == 2)
        let locations: [LSPLocation] = try await response("definition") {
            client.definition(uri: file.absoluteString, at: position, completion: $0)
        }
        #expect(locations.contains { $0.uri == file.absoluteString && $0.range.start.line == 0 })
        let semantic: DecodedSemanticTokens? = try await response("semantic tokens") {
            client.semanticTokens(uri: file.absoluteString, completion: $0)
        }
        let tokens = try #require(semantic?.tokens)
        #expect(tokens.contains { $0.line == 0 })
        client.didClose(uri: file.absoluteString)
        let exit = try await stop(client, events: events)
        #expect(exit == ServerExit(status: 0, signaled: false))
        print("\(language): \(capabilities.positionEncoding.rawValue), diagnostic: \(diagnostic.message), definitions: \(locations.count), semantic tokens: \(tokens.count), exit: \(exit.status)")
    }

    private struct Echo: Decodable, Sendable { let value: String }

    private func fakeClient(_ mode: String, root: URL, events: Inbox<LSPEvent>,
                            restart: RestartPolicy = .disabled) -> LSPClient {
        LSPClient(config: .init(name: "Fake",
                                command: ["/usr/bin/env", "python3", "-I", "-c", FakeLanguageServer.script, mode],
                                languages: ["swift"], initializationOptions: .object(["test": .bool(true)]),
                                settings: .object(["editor": .object(["option": .integer(7)])])),
                  root: root, restart: restart, onEvent: events.append)
    }

    private func ready(_ events: Inbox<LSPEvent>) async throws -> ServerCapabilities {
        try await events.take("initialize", matching: { event in
            if case .ready(let capabilities) = event { return capabilities }
            if case .failed(let error) = event { throw error }
            if case .exited(let exit, willRestart: false) = event { throw LSPClientError.serverExited(exit) }
            return nil
        })
    }

    private func diagnostics(_ events: Inbox<LSPEvent>, uri: String,
                             requiringError: Bool = false) async throws -> PublishedDiagnostics {
        try await events.take("diagnostics", matching: { event -> PublishedDiagnostics? in
            if case .failed(let error) = event { throw error }
            guard case .diagnostics(let report) = event, report.uri == uri else { return nil }
            if requiringError && !report.diagnostics.contains(where: { $0.severity == .error }) { return nil }
            return report
        })
    }

    private func notification(_ name: String) -> (LSPEvent) -> JSON? {
        { event in
            if case .notification(let method, let params) = event, method == name { return params ?? .null }
            return nil
        }
    }

    private func stop(_ client: LSPClient, events: Inbox<LSPEvent>,
                      timeout: TimeInterval = 5) async throws -> ServerExit {
        let stopped = Inbox<Bool>()
        client.stop(timeout: timeout) { stopped.append(true) }
        _ = try await stopped.take("stop completion") { $0 }
        return try await events.take("exit") { event in
            if case .exited(let exit, willRestart: false) = event { return exit }
            return nil
        }
    }

    private func response<T: Sendable>(_ description: String,
                                       send: (@escaping LSPClient.Reply<T>) -> Void) async throws -> T {
        let inbox = Inbox<Result<T, LSPClientError>>()
        send(inbox.append)
        return try await inbox.take(description) { $0 }.get()
    }
}

private final class Inbox<Event: Sendable>: @unchecked Sendable {
    struct Deadline: Error { let operation: String }
    private let lock = NSLock()
    private var values: [Event] = []

    func append(_ value: Event) {
        lock.withLock { values.append(value) }
    }

    func take<T>(_ description: String, matching match: (Event) throws -> T?) async throws -> T {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(40)
        while clock.now < deadline {
            if let value = try lock.withLock({ () throws -> T? in
                for (index, event) in values.enumerated() {
                    if let value = try match(event) {
                        values.remove(at: index)
                        return value
                    }
                }
                return nil
            }) { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Deadline(operation: description)
    }
}
