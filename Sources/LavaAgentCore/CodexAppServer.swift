import Foundation
import Glibc

/// Read-only queries over the Codex CLI's newline-delimited stdio protocol.
public struct CodexAppServer {
    public struct Session: Sendable {
        public let agent: AgentSession
        public let status: AgentStatus
        public let isCurrent: Bool
    }

    public let executable: URL
    public init(executable: URL) { self.executable = executable }

    public func sessions(in directories: [URL]) -> [Session]? {
        let roots = directories.map(Self.pathComponents)
        let environment = ProcessInfo.processInfo.environment
        let currentID = environment["CODEX_THREAD_ID"] ?? environment["CODEX_SESSION_ID"]
        return query { connection in
            var cursor: String?
            var seenCursors = Set<String>()
            var sessions: [String: Session] = [:]
            repeat {
                // The server's cwd filter is exact. Match locally so a session
                // started from a subdirectory still belongs to its worktree.
                var params: [String: Any] = [
                    "limit": 100, "sortKey": "updated_at", "modelProviders": [String](),
                    "sourceKinds": ["cli", "vscode", "exec", "appServer", "unknown"],
                ]
                if let cursor { params["cursor"] = cursor }
                let page: Page<Thread> = try connection.request("thread/list", params)
                for thread in page.data where sessions[thread.id] == nil {
                    let directory = URL(fileURLWithPath: thread.cwd, isDirectory: true)
                    let path = Self.pathComponents(directory)
                    guard roots.contains(where: { path.starts(with: $0) }) else { continue }
                    let file = thread.path.map { URL(fileURLWithPath: $0) }
                    let bytes = file.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
                    let title = [thread.name, thread.preview].compactMap { $0 }
                        .map(InlineChatPrompt.title).first { !$0.isEmpty } ?? "Untitled session"
                    let date = Date(timeIntervalSince1970: thread.updatedAt)
                    let isCurrent = thread.id == currentID
                    let status: AgentStatus
                    if thread.status?.type == "active" {
                        let flags = thread.status?.activeFlags ?? []
                        status = flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput")
                            ? .waiting : .working
                    } else if isCurrent || (Date().timeIntervalSince(date) < 600
                        && bytes != nil && file.map({ CodexSessions.turnOpen($0) }) == true) {
                        status = .working
                    } else {
                        status = thread.status?.type == "idle" ? .waiting : .stopped
                    }
                    let agent = AgentSession(agent: .codex, id: thread.id, title: title, date: date,
                                             directory: directory, bytes: bytes ?? 0, file: bytes == nil ? nil : file)
                    sessions[thread.id] = Session(agent: agent, status: status, isCurrent: isCurrent)
                }
                cursor = page.nextCursor
                if let cursor, !seenCursors.insert(cursor).inserted { throw RPCFailure.invalidResponse }
            } while cursor != nil
            return sessions.values.sorted {
                $0.agent.date == $1.agent.date ? $0.agent.id < $1.agent.id : $0.agent.date > $1.agent.date
            }
        }
    }

    public func transcript(threadID: String, limit: Int) -> (entries: [TranscriptEntry], truncated: Bool)? {
        query { connection in
            let page: Page<StoredItem> = try connection.request("thread/items/list", [
                "threadId": threadID, "sortDirection": "desc", "limit": limit,
            ])
            return (page.data.reversed().flatMap { $0.item.entries }, page.nextCursor != nil)
        }
    }

    private func query<Result>(_ read: (Connection) throws -> Result) -> Result? {
        // The proxy speaks stdio too. When a shared daemon is available it
        // knows which threads are active, including those owned by other UIs.
        // A daemon can accept the connection and never answer the handshake.
        // Give it a short head start before launching a standalone server.
        for (transport, handshakeTimeout) in [("proxy", 0.35), ("--stdio", 5.0)] {
            do {
                let connection = try Connection(executable: executable, arguments: ["app-server", transport])
                try connection.initialize(timeout: handshakeTimeout)
                return try read(connection)
            } catch {
                continue
            }
        }
        return nil
    }

    private static func pathComponents(_ url: URL) -> [String] {
        url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    }

    private struct Page<Item: Decodable>: Decodable {
        let data: [Item]
        let nextCursor: String?
    }

    private struct Thread: Decodable {
        struct Status: Decodable {
            let type: String
            let activeFlags: [String]?
        }
        let id: String
        let cwd: String
        let updatedAt: TimeInterval
        let name: String?
        let preview: String?
        let path: String?
        let status: Status?
    }

    private struct StoredItem: Decodable { let item: ThreadItem }

    private struct ThreadItem: Decodable {
        struct Content: Decodable { let text: String? }

        let type: String
        let content: [Content]?
        let text: String?
        let command: String?
        let name: String?

        var entries: [TranscriptEntry] {
            switch type {
            case "userMessage":
                return (content ?? []).compactMap { $0.text.flatMap(TranscriptParser.userText) }
                    .map { TranscriptEntry(.user, $0) }
            case "agentMessage":
                return text.flatMap { $0.isEmpty ? nil : TranscriptEntry(.assistant, $0) }.map { [$0] } ?? []
            case "commandExecution":
                return command.map { [TranscriptEntry(.tool, "Ran " + ClaudeSessions.oneLine(AgentEvent.shellBody($0)))] } ?? []
            case "fileChange":
                return [TranscriptEntry(.tool, "Edited files")]
            case "mcpToolCall", "dynamicToolCall":
                return [TranscriptEntry(.tool, name ?? "Tool call")]
            default:
                return []
            }
        }
    }

    private enum RPCFailure: Error { case disconnected, timedOut, invalidResponse }

    private final class Connection {
        private let process = Process()
        private let input: FileHandle
        private let output: FileHandle
        private var incoming = Data()
        private var nextID = 0
        private var deadline = DispatchTime.now()

        init(executable: URL, arguments: [String]) throws {
            let stdin = Pipe()
            let stdout = Pipe()
            input = stdin.fileHandleForWriting
            output = stdout.fileHandleForReading
            guard fcntl(input.fileDescriptor, F_SETFL, O_NONBLOCK) == 0 else { throw RPCFailure.disconnected }
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
        }

        func initialize(timeout: TimeInterval) throws {
            deadline = DispatchTime.now() + timeout
            let _: [String: Any] = try response("initialize", [
                "clientInfo": ["name": "lava_editor", "title": "LavaEditor", "version": "1"],
            ])
            try send(["method": "initialized"])
            deadline = DispatchTime.now() + 5
        }

        deinit {
            try? input.close()
            try? output.close()
            if process.isRunning { process.terminate() }
        }

        func request<Result: Decodable>(_ method: String, _ params: [String: Any]) throws -> Result {
            let result = try response(method, params)
            return try JSONDecoder().decode(Result.self, from: JSONSerialization.data(withJSONObject: result))
        }

        private func response(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            nextID += 1
            try send(["id": nextID, "method": method, "params": params])
            while true {
                let data = try readLine()
                guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      message["id"] as? Int == nextID, message["method"] == nil else { continue }
                guard let result = message["result"] as? [String: Any] else { throw RPCFailure.invalidResponse }
                return result
            }
        }

        private func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes)
            data.append(10)
            // If the CLI exits before reading the request, write must report
            // EPIPE without delivering SIGPIPE to the editor.
            var mask = sigset_t()
            var previous = sigset_t()
            sigemptyset(&mask)
            sigaddset(&mask, SIGPIPE)
            guard pthread_sigmask(SIG_BLOCK, &mask, &previous) == 0 else { throw RPCFailure.disconnected }
            defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }

            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    try wait(input, for: Int16(POLLOUT))
                    let count = Glibc.write(input.fileDescriptor, base.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR || errno == EAGAIN { continue }
                    if count < 0, errno == EPIPE, sigismember(&previous, SIGPIPE) == 0 {
                        var immediate = timespec()
                        _ = sigtimedwait(&mask, nil, &immediate)
                    }
                    guard count > 0 else { throw RPCFailure.disconnected }
                    offset += count
                }
            }
        }

        private func readLine() throws -> Data {
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                if let end = incoming.firstIndex(of: 10) {
                    let line = Data(incoming[..<end])
                    incoming.removeFirst(line.count + 1)
                    return line
                }
                try wait(output, for: Int16(POLLIN))
                let count = Glibc.read(output.fileDescriptor, &chunk, chunk.count)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count > 0 else { throw RPCFailure.disconnected }
                incoming.append(contentsOf: chunk.prefix(count))
            }
        }

        private func wait(_ handle: FileHandle, for events: Int16) throws {
            while true {
                let remaining = Int64(deadline.uptimeNanoseconds) - Int64(DispatchTime.now().uptimeNanoseconds)
                guard remaining > 0 else { throw RPCFailure.timedOut }
                var descriptor = pollfd(fd: handle.fileDescriptor, events: events, revents: 0)
                let result = Glibc.poll(&descriptor, 1, Int32((remaining + 999_999) / 1_000_000))
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw RPCFailure.timedOut }
                return
            }
        }
    }
}
