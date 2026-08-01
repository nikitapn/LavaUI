import Foundation
import Testing
@testable import TraceLoomCore

/// End-to-end against a real Ollama, gated on OLLAMA_MODEL so a normal
/// `swift test` skips it. The scripted tests cover the turn loop's logic; this
/// covers the parts only a live model exercises — that Ollama's streaming NDJSON
/// decodes, that tool calls come back in the shape the loop expects, and that a
/// given model is actually willing to use the tools rather than answer in prose.
///
///     OLLAMA_MODEL=gemma4:e4b swift test --filter liveOllamaSuggestsARule
///
/// Measured: gemma4:e4b ~37s, qwen3.5 ~125s. Most of it is the think phase,
/// which is why `ChatDelta` reports reasoning separately.
@Test func liveOllamaSuggestsARule() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let model = env["OLLAMA_MODEL"], !model.isEmpty else { return }
    let host = env["OLLAMA_HOST"] ?? "http://localhost:11434"

    let client = OllamaClient(
        baseURL: URL(string: host)!, model: model, timeoutSeconds: 300, numCtx: 8192
    )
    let lines = [
        "19:16:15.280 NetworkMetrics inboundKbps:8400 outboundKbps:3200",
        "19:16:16.140 ClusterScaler replicas=3",
        "19:16:17.010 NetworkMetrics inboundKbps:7900 outboundKbps:3500",
        "19:16:20.492 ConfigService CONFIG_RELOAD completed",
    ]

    let start = Date()
    await RuleAssistant(backend: client).suggestRule(
        example: lines[0], sampleLines: lines, existingRules: ""
    ) { event in
        let t = String(format: "%6.1fs", Date().timeIntervalSince(start))
        switch event {
        case .token(let s):
            FileHandle.standardError.write(Data(s.utf8))
        case .thinking(let s):
            FileHandle.standardError.write(Data(s.utf8))
        case .toolCall(let s):
            print("\n[\(t)] TOOL CALL  \(s)")
        case .toolResult(let s):
            print("[\(t)] TOOL RESULT\n\(s)\n")
        case .accepted(let check):
            print("[\(t)] ACCEPTED: \(check.ruleText)")
            print("        matched \(check.matchedCount)/\(check.outcomes.count) lines")
        case .gaveUp(let why):
            print("[\(t)] GAVE UP: \(why)")
        case .failed(let why):
            print("[\(t)] FAILED: \(why)")
        }
    }
    print("[total \(String(format: "%.1f", Date().timeIntervalSince(start)))s]")
}
