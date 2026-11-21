import Foundation

public struct ServerExit: Sendable, Equatable {
    public let status: Int32
    public let signaled: Bool
}

public struct RestartPolicy: Sendable {
    public let maxRetries: Int
    public let initialDelay: TimeInterval
    public let maximumDelay: TimeInterval

    public init(maxRetries: Int, initialDelay: TimeInterval = 0.25, maximumDelay: TimeInterval = 4) {
        self.maxRetries = max(0, maxRetries)
        self.maximumDelay = maximumDelay.isFinite ? max(0, maximumDelay) : 4
        self.initialDelay = initialDelay.isFinite ? min(max(0, initialDelay), self.maximumDelay) : 0.25
    }

    public static let disabled = Self(maxRetries: 0)
}

public enum LSPClientError: Error, Sendable, Equatable {
    case emptyCommand
    case notReady
    case alreadyStarted
    case cancelled
    case timedOut
    case serverExited(ServerExit)
    case transport(String)
    case invalidResponse(String)
    case rpc(code: Int, message: String, data: JSON?)
    case unsupported
}

public enum LSPEvent: Sendable {
    case ready(ServerCapabilities)
    case diagnostics(PublishedDiagnostics)
    case notification(method: String, params: JSON?)
    case exited(ServerExit, willRestart: Bool)
    case failed(LSPClientError)
}

public struct LSPRequestID: Hashable, Sendable {
    fileprivate let value = UUID().uuidString
}

/// Calls enqueue work and return immediately. Events and completions arrive in order on
/// a private serial callback queue, separate from the process and protocol queues.
public final class LSPClient: @unchecked Sendable {
    public typealias Reply<Value> = @Sendable (Result<Value, LSPClientError>) -> Void

    private enum State { case idle, starting, ready, stopping, restarting, failing }
    private struct Document {
        var language: String
        var version: Int
        var text: String
    }

    private let config: LanguageServerConfig
    private let root: URL
    private let restart: RestartPolicy
    private let onEvent: @Sendable (LSPEvent) -> Void
    private let stateQueue = DispatchQueue(label: "LavaLSP.state")
    private let callbacks = DispatchQueue(label: "LavaLSP.callbacks")
    private var state = State.idle
    private var transport: ProcessTransport?
    private var lastTransport: ProcessTransport?
    private var generation = UUID()
    private var capabilities: ServerCapabilities?
    private var retries = 0
    private var retryDelay: TimeInterval = 0
    private var pending: [String: Reply<JSON>] = [:]
    private var documents: [String: Document] = [:]
    private var stopCallbacks: [@Sendable () -> Void] = []

    public init(config: LanguageServerConfig, root: URL, restart: RestartPolicy = .disabled,
                onEvent: @escaping @Sendable (LSPEvent) -> Void = { _ in }) {
        self.config = config
        self.root = URL(fileURLWithPath: root.path, isDirectory: true).standardizedFileURL
        self.restart = restart
        self.onEvent = onEvent
    }

    deinit {
        transport?.kill()
        transport?.closeInput()
    }

    /// The first successful handshake and each successful restart emit a ready event.
    public func start() {
        stateQueue.async {
            guard self.state == .idle else {
                self.emit(.failed(.alreadyStarted))
                return
            }
            self.retries = 0
            self.retryDelay = min(self.restart.initialDelay, self.restart.maximumDelay)
            self.launch()
        }
    }

    /// Completes after the child exits. The deadline covers both shutdown and exit.
    public func stop(timeout: TimeInterval = 3, completion: @escaping @Sendable () -> Void = {}) {
        stateQueue.async {
            self.stopCallbacks.append(completion)
            if self.state == .stopping { return }
            let wasReady = self.state == .ready
            self.state = .stopping
            self.documents.removeAll()
            guard self.transport != nil else {
                self.finishStop()
                return
            }

            let generation = self.generation
            self.stateQueue.asyncAfter(deadline: .now() + Self.timeout(timeout, fallback: 3)) { [weak self = self] in
                guard let self, self.generation == generation, self.state == .stopping else { return }
                self.transport?.kill()
            }
            if wasReady {
                self.sendRequest(LSPRequestID(), method: "shutdown", params: nil, timeout: nil) { [weak self = self] _ in
                    guard let self, self.generation == generation else { return }
                    self.sendNotification("exit", nil)
                }
            } else {
                self.transport?.kill()
            }
        }
    }

    /// Returns the latest 64 KiB of stderr from the current or most recent child.
    public func stderrLog(_ completion: @escaping @Sendable (String) -> Void) {
        stateQueue.async {
            let log = (self.transport ?? self.lastTransport)?.stderrLog ?? ""
            self.callbacks.async { completion(log) }
        }
    }

    /// The completion receives cancellation immediately, without waiting for the server's reply.
    public func cancel(_ id: LSPRequestID) {
        stateQueue.async {
            guard let complete = self.pending.removeValue(forKey: id.value) else { return }
            self.sendNotification("$/cancelRequest", .object(["id": .string(id.value)]))
            complete(.failure(.cancelled))
        }
    }

    @discardableResult
    public func request<Value: Decodable & Sendable>(
        _ method: String, params: JSON? = nil, as type: Value.Type,
        timeout: TimeInterval = 30, completion: @escaping Reply<Value>
    ) -> LSPRequestID {
        enqueueRequest(timeout: timeout, completion: completion, prepare: { _ in
            (method, params, { try $0.decode(type) })
        })
    }

    public func notify(_ method: String, params: JSON? = nil) {
        stateQueue.async {
            guard self.state == .ready else { return }
            self.sendNotification(method, params)
        }
    }

    // Preparation and decoding both use the capabilities of the child that owns this request.
    typealias Prepared<Value> = (method: String, params: JSON?, decode: @Sendable (JSON) throws -> Value)

    @discardableResult
    func enqueueRequest<Value: Sendable>(
        timeout: TimeInterval, completion: @escaping Reply<Value>,
        prepare: @escaping @Sendable (ServerCapabilities) throws -> Prepared<Value>
    ) -> LSPRequestID {
        let id = LSPRequestID()
        stateQueue.async {
            let deliver: Reply<Value> = { [callbacks = self.callbacks] result in
                callbacks.async { completion(result) }
            }
            guard self.state == .ready, let capabilities = self.capabilities else {
                deliver(.failure(.notReady))
                return
            }
            do {
                let request = try prepare(capabilities)
                self.sendRequest(id, method: request.method, params: request.params,
                                 timeout: Self.timeout(timeout, fallback: 30)) { result in
                    deliver(result.flatMap { raw in
                        do { return .success(try request.decode(raw)) }
                        catch { return .failure(.invalidResponse(String(describing: error))) }
                    })
                }
            } catch let error as LSPClientError {
                deliver(.failure(error))
            } catch {
                deliver(.failure(.transport(String(describing: error))))
            }
        }
        return id
    }

    private func launch() {
        state = .starting
        generation = UUID()
        let generation = generation
        do {
            transport = try ProcessTransport(command: config.command, root: root, receive: { [weak self] message in
                self?.stateQueue.async { [weak self] in
                    guard let self, self.generation == generation, self.transport != nil else { return }
                    self.receive(message)
                }
            }, fail: { [weak self] reason in
                self?.reportTransport(reason, generation: generation)
            }, exited: { [weak self] exit in
                self?.stateQueue.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.didExit(exit)
                }
            })
        } catch {
            emit(.failed(error as? LSPClientError ?? .transport(String(describing: error))))
            scheduleRestart()
            return
        }

        let params: JSON = .object([
            "processId": .integer(Int(ProcessInfo.processInfo.processIdentifier)),
            "rootUri": .string(root.absoluteString),
            "clientInfo": .object(["name": .string("LavaEditor")]),
            "capabilities": ServerCapabilities.client,
            "initializationOptions": config.initializationOptions ?? .null,
        ])
        sendRequest(LSPRequestID(), method: "initialize", params: params, timeout: 30) { [weak self] result in
            guard let self, self.state == .starting else { return }
            do {
                let response = try result.get()
                guard let fields = response["capabilities"] else {
                    throw LSPClientError.invalidResponse("initialize response missing capabilities")
                }
                let capabilities = try fields.decode(ServerCapabilities.self)
                self.capabilities = capabilities
                self.state = .ready
                self.sendNotification("initialized", .object([:]))
                for (uri, document) in self.documents {
                    self.openOnServer(uri, document)
                }
                self.emit(.ready(capabilities))
            } catch {
                self.failChild(error as? LSPClientError ?? .invalidResponse(String(describing: error)))
            }
        }
    }

    private func reportTransport(_ reason: String, generation: UUID) {
        stateQueue.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.failChild(.transport(reason))
        }
    }

    private func failChild(_ error: LSPClientError) {
        guard transport != nil, state == .starting || state == .ready else { return }
        state = .failing
        emit(.failed(error))
        failRequests(error)
        transport?.kill()
    }

    private func didExit(_ exit: ServerExit) {
        let stopping = state == .stopping
        transport?.closeInput()
        lastTransport = transport
        transport = nil
        capabilities = nil
        state = stopping ? .stopping : .idle
        failRequests(.serverExited(exit))
        let willRestart = !stopping && retries < restart.maxRetries
        emit(.exited(exit, willRestart: willRestart))
        if stopping { finishStop() }
        else { scheduleRestart() }
    }

    private func scheduleRestart() {
        guard retries < restart.maxRetries else {
            state = .idle
            return
        }
        retries += 1
        state = .restarting
        let generation = generation
        stateQueue.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self, self.generation == generation, self.state == .restarting else { return }
            self.launch()
        }
        retryDelay = min(restart.maximumDelay, retryDelay * 2)
    }

    private func finishStop() {
        state = .idle
        let completions = stopCallbacks
        stopCallbacks.removeAll()
        callbacks.async { for complete in completions { complete() } }
    }

    private func failRequests(_ error: LSPClientError) {
        let requests = pending
        pending.removeAll()
        for complete in requests.values { complete(.failure(error)) }
    }

    private static func timeout(_ value: TimeInterval, fallback: TimeInterval) -> TimeInterval {
        value.isFinite ? max(0, value) : fallback
    }

    private func sendRequest(_ id: LSPRequestID, method: String, params: JSON?, timeout: TimeInterval?,
                             completion: @escaping Reply<JSON>) {
        pending[id.value] = completion
        send(["id": .string(id.value), "method": .string(method), "params": params])
        if let timeout {
            stateQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let complete = self.pending.removeValue(forKey: id.value) else { return }
                self.sendNotification("$/cancelRequest", .object(["id": .string(id.value)]))
                complete(.failure(.timedOut))
            }
        }
    }

    private func sendNotification(_ method: String, _ params: JSON?) {
        send(["method": .string(method), "params": params])
    }

    private func send(_ fields: [String: JSON?]) {
        var message = fields.compactMapValues { $0 }
        message["jsonrpc"] = .string("2.0")
        let generation = generation
        transport?.send(.object(message)) { [weak self] reason in
            self?.reportTransport(reason, generation: generation)
        }
    }

    private func receive(_ message: JSON) {
        guard message["jsonrpc"] == .string("2.0") else {
            failChild(.invalidResponse("missing JSON-RPC 2.0 version"))
            return
        }
        if let method = message["method"]?.string {
            if let id = message["id"] {
                reply(to: method, id: id, params: message["params"])
            } else if method == "textDocument/publishDiagnostics", let params = message["params"] {
                do { emit(.diagnostics(try params.decode(PublishedDiagnostics.self))) }
                catch { emit(.failed(.invalidResponse(String(describing: error)))) }
            } else {
                emit(.notification(method: method, params: message["params"]))
            }
        } else if let id = message["id"]?.string, let complete = pending.removeValue(forKey: id) {
            if let result = message["result"] {
                complete(.success(result))
            } else if let error = message["error"], let code = error["code"]?.integer,
                      let reason = error["message"]?.string {
                complete(.failure(.rpc(code: code, message: reason, data: error["data"])))
            } else {
                complete(.failure(.invalidResponse("response missing result or valid error")))
            }
        }
    }

    private func reply(to method: String, id: JSON, params: JSON?) {
        switch method {
        case "workspace/configuration":
            let items = params?["items"]?.array ?? []
            let values = items.map { item in
                let settings = config.settings ?? .null
                guard let section = item["section"]?.string, !section.isEmpty else { return settings }
                return section.split(separator: ".").reduce(settings) { $0[String($1)] ?? .null }
            }
            send(["id": id, "result": .array(values)])
        case "client/registerCapability", "client/unregisterCapability", "window/workDoneProgress/create":
            send(["id": id, "result": .null])
        default:
            send(["id": id, "error": .object(["code": .integer(-32601), "message": .string("Method not found")])])
        }
    }

    private func emit(_ event: LSPEvent) {
        callbacks.async { [onEvent] in onEvent(event) }
    }
}

extension LSPClient {
    /// Keeps the latest open snapshots for replay after an automatic restart.
    public func didOpen(uri: String, languageID: String, text: String, version: Int = 1) {
        stateQueue.async {
            guard self.state != .stopping, self.documents[uri] == nil else { return }
            let document = Document(language: languageID, version: version, text: text)
            self.documents[uri] = document
            if self.state == .ready { self.openOnServer(uri, document) }
        }
    }

    /// Omit the version to advance it by one. Identical text and stale versions are ignored.
    public func didChange(uri: String, text: String, version: Int? = nil) {
        stateQueue.async {
            guard var document = self.documents[uri], document.version < Int.max else { return }
            let nextVersion = version ?? document.version + 1
            guard nextVersion > document.version else { return }

            let content: JSON
            if self.state == .ready, let capabilities = self.capabilities, capabilities.syncKind == .incremental {
                guard let change = IncrementalChange.between(document.text, and: text,
                                                             encoding: capabilities.positionEncoding)
                else { return }
                // The fields are finite integers and strings, so encoding cannot fail.
                guard let encoded = try? JSON(encoding: change) else { return }
                content = encoded
            } else {
                guard !document.text.utf8.elementsEqual(text.utf8) else { return }
                content = .object(["text": .string(text)])
            }

            document.text = text
            document.version = nextVersion
            self.documents[uri] = document
            if self.state == .ready, self.capabilities?.syncKind != ServerCapabilities.SyncKind.none {
                self.sendNotification("textDocument/didChange", .object([
                    "textDocument": .object(["uri": .string(uri), "version": .integer(nextVersion)]),
                    "contentChanges": .array([content]),
                ]))
            }
        }
    }

    public func didSave(uri: String) {
        stateQueue.async {
            guard self.state == .ready, let document = self.documents[uri],
                  let includeText = self.capabilities?.saveIncludesText else { return }
            var params = ["textDocument": Self.documentID(uri)]
            if includeText { params["text"] = .string(document.text) }
            self.sendNotification("textDocument/didSave", .object(params))
        }
    }

    public func didClose(uri: String) {
        stateQueue.async {
            guard self.documents.removeValue(forKey: uri) != nil,
                  self.state == .ready, self.capabilities?.openClose == true else { return }
            self.sendNotification("textDocument/didClose", .object(["textDocument": Self.documentID(uri)]))
        }
    }

    private func openOnServer(_ uri: String, _ document: Document) {
        guard capabilities?.openClose == true else { return }
        sendNotification("textDocument/didOpen", .object([
            "textDocument": .object([
                "uri": .string(uri), "languageId": .string(document.language),
                "version": .integer(document.version), "text": .string(document.text),
            ]),
        ]))
    }

    static func documentID(_ uri: String) -> JSON {
        .object(["uri": .string(uri)])
    }
}
