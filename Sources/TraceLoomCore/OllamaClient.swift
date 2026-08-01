import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Minimal client for Ollama's /api/chat tool-calling endpoint, adapted from
// NScalcServer's. Foundation's URLSession only — no new package dependency.

// MARK: - Dynamic JSON

/// Arbitrary JSON. Needed in both directions: tool-call `arguments` have
/// whatever shape the tool schema declared, and outgoing tool definitions carry
/// a JSON-schema literal.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        case .bool(let value): return String(value)
        default: return nil
        }
    }
}

// MARK: - Wire types

public struct OllamaToolCallFunction: Codable, Sendable {
    public var name: String
    public var arguments: [String: JSONValue]

    public init(name: String, arguments: [String: JSONValue]) {
        self.name = name
        self.arguments = arguments
    }
}

public struct OllamaToolCall: Codable, Sendable {
    public var function: OllamaToolCallFunction

    public init(function: OllamaToolCallFunction) {
        self.function = function
    }
}

public struct OllamaMessage: Codable, Sendable {
    public var role: String
    public var content: String
    public var tool_calls: [OllamaToolCall]?
    public var tool_name: String?
    /// Reasoning models (every tool-capable model on this box has the
    /// capability) put their scratch work here rather than in `content`, which
    /// stays empty until they are done. Decoded so a caller can show progress
    /// instead of a blank pane for the entire think.
    public var thinking: String?

    public init(
        role: String,
        content: String,
        tool_calls: [OllamaToolCall]? = nil,
        tool_name: String? = nil,
        thinking: String? = nil
    ) {
        self.role = role
        self.content = content
        self.tool_calls = tool_calls
        self.tool_name = tool_name
        self.thinking = thinking
    }
}

public struct OllamaToolFunction: Codable, Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct OllamaTool: Codable, Sendable {
    public var type: String = "function"
    public var function: OllamaToolFunction

    public init(function: OllamaToolFunction) {
        self.function = function
    }
}

public struct OllamaOptions: Codable, Sendable {
    /// Runtime context window. Ollama defaults this far below a model's
    /// architectural max, and once system + history + tool schemas exceed it
    /// llama.cpp silently drops older context to keep generating.
    public var num_ctx: Int?
}

struct OllamaChatRequest: Codable, Sendable {
    var model: String
    var messages: [OllamaMessage]
    var tools: [OllamaTool]?
    var stream: Bool = false
    var options: OllamaOptions?
}

struct OllamaChatResponse: Codable, Sendable {
    var model: String
    var message: OllamaMessage
    var done: Bool
}

public enum OllamaClientError: Error, CustomStringConvertible, Sendable {
    case httpStatus(Int)
    case unreachable(String)

    public var description: String {
        switch self {
        case .httpStatus(let code):
            return "Ollama returned HTTP \(code)"
        case .unreachable(let reason):
            return "Could not reach Ollama: \(reason)"
        }
    }
}

// MARK: - Streaming

/// Bridges `URLSessionDataDelegate` byte callbacks to an
/// `AsyncThrowingStream` of decoded chunks.
///
/// This exists because `URLSession.bytes(for:)` — the obvious way to stream a
/// response — is not available in this Linux Foundation build. The delegate
/// route is, and Ollama's stream is newline-delimited JSON, so the only real
/// work is reassembling lines across arbitrary packet boundaries.
private final class OllamaStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var buffer = Data()
    private let newline = Data([0x0A])
    private let continuation: AsyncThrowingStream<OllamaChatResponse, Error>.Continuation

    init(continuation: AsyncThrowingStream<OllamaChatResponse, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            continuation.finish(throwing: OllamaClientError.httpStatus(http.statusCode))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while let range = buffer.range(of: newline) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard !lineData.isEmpty else { continue }
            do {
                continuation.yield(
                    try JSONDecoder().decode(OllamaChatResponse.self, from: lineData)
                )
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

// MARK: - Backend

/// An incremental piece of a reply.
///
/// Reasoning is kept distinct from the answer rather than concatenated: every
/// tool-capable model on this machine thinks before its first tool call, and
/// measured against a local qwen3.5 that is ~110 seconds during which `content`
/// stays completely empty. Showing nothing for that long is indistinguishable
/// from a hang, and showing reasoning as though it were the answer is worse.
public enum ChatDelta: Sendable {
    case content(String)
    case thinking(String)
}

/// What the assistant needs from a model, and nothing more.
///
/// A protocol rather than a concrete client so the turn loop can be tested
/// against scripted replies — including the ones that matter, where the model
/// proposes a rule that does not work and has to be told so.
public protocol ChatBackend: Sendable {
    func chat(
        messages: [OllamaMessage],
        tools: [OllamaTool],
        onDelta: @Sendable (ChatDelta) async -> Void
    ) async throws -> OllamaMessage
}

public struct OllamaClient: ChatBackend, Sendable {
    public let baseURL: URL
    public let model: String
    private let timeoutSeconds: TimeInterval
    private let numCtx: Int?

    public init(
        baseURL: URL, model: String,
        timeoutSeconds: TimeInterval = 120, numCtx: Int? = 8192
    ) {
        self.baseURL = baseURL
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.numCtx = numCtx
    }

    /// Streams `/api/chat`, invoking `onDelta` per chunk and returning the
    /// assembled message once the stream ends.
    public func chat(
        messages: [OllamaMessage],
        tools: [OllamaTool],
        onDelta: @Sendable (ChatDelta) async -> Void
    ) async throws -> OllamaMessage {
        let request = OllamaChatRequest(
            model: model,
            messages: messages,
            tools: tools.isEmpty ? nil : tools,
            stream: true,
            options: numCtx.map { OllamaOptions(num_ctx: $0) }
        )
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds

        let chunks = AsyncThrowingStream<OllamaChatResponse, Error> { continuation in
            let delegate = OllamaStreamDelegate(continuation: continuation)
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            session.dataTask(with: urlRequest).resume()
        }

        var content = ""
        var thinking = ""
        var toolCalls: [OllamaToolCall]?
        for try await chunk in chunks {
            if !chunk.message.content.isEmpty {
                content += chunk.message.content
                await onDelta(.content(chunk.message.content))
            }
            if let part = chunk.message.thinking, !part.isEmpty {
                thinking += part
                await onDelta(.thinking(part))
            }
            if let calls = chunk.message.tool_calls, !calls.isEmpty {
                toolCalls = calls
            }
        }

        return OllamaMessage(
            role: "assistant",
            content: content,
            tool_calls: toolCalls,
            thinking: thinking.isEmpty ? nil : thinking
        )
    }
}
