import Foundation
import LavaUI
import TraceLoomCore

/// Drives `RuleAssistant` from the UI and holds what the view draws.
///
/// The assistant runs in a `Task` on the concurrency pool; every field here is
/// written from that thread and read from the main one, so all access goes
/// through the lock. Redraws are posted via `MainQueue`, which is the only way
/// a background thread may reach `@State` or `ViewInvalidation` — see the
/// comment on `MainQueue` for why writing state directly would race the loop.
///
/// Redraw requests are *coalesced*: a reasoning stream is thousands of deltas,
/// and marking the body dirty for each would rebuild the view — on a large log,
/// a very expensive view — per token. Instead a refresh is posted only when one
/// is not already pending, so the cost is at most one rebuild per frame no
/// matter how fast the model talks.
final class AssistantSession: @unchecked Sendable {
    struct Snapshot {
        var isRunning = false
        var status = ""
        /// Tool calls and verdicts, newest last.
        var activity: [String] = []
        /// Tail of the model's reasoning, for liveness.
        var thinkingTail = ""
        var thinkingCharacters = 0
        var elapsed: TimeInterval = 0
        var suggestion: String?
        var problem: String?
    }

    private let lock = NSLock()
    private var state = Snapshot()
    private var refreshPending = false
    private var startedAt = Date()

    let host: String
    let model: String

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        host = environment["TRACELOOM_OLLAMA_HOST"] ?? "http://localhost:11434"
        model = environment["TRACELOOM_OLLAMA_MODEL"] ?? "gemma4:e4b"
    }

    var snapshot: Snapshot {
        lock.withLock {
            var copy = state
            if copy.isRunning { copy.elapsed = Date().timeIntervalSince(startedAt) }
            return copy
        }
    }

    var isRunning: Bool { lock.withLock { state.isRunning } }

    /// Kicks off a run. Returns false if one is already going.
    @discardableResult
    func start(example: String, sampleLines: [String], existingRules: String) -> Bool {
        let trimmed = example.trimmingCharacters(in: .whitespacesAndNewlines)
        let began = lock.withLock { () -> Bool in
            guard !state.isRunning else { return false }
            state = Snapshot(isRunning: true, status: "asking \(model)…")
            startedAt = Date()
            return true
        }
        guard began else { return false }

        guard !trimmed.isEmpty else {
            finish(problem: "Paste a log line to build a rule from.")
            return true
        }
        guard let url = URL(string: host) else {
            finish(problem: "TRACELOOM_OLLAMA_HOST is not a valid URL: \(host)")
            return true
        }

        let backend = OllamaClient(
            baseURL: url, model: model, timeoutSeconds: 300, numCtx: 8192
        )
        Task.detached { [self] in
            await RuleAssistant(backend: backend).suggestRule(
                example: trimmed, sampleLines: sampleLines, existingRules: existingRules
            ) { event in
                self.handle(event)
            }
        }
        return true
    }

    private func handle(_ event: RuleAssistantEvent) {
        lock.withLock {
            switch event {
            case .thinking(let text):
                state.thinkingCharacters += text.count
                state.thinkingTail = Self.tail(of: state.thinkingTail + text)
                state.status = "thinking…"
            case .token(let text):
                state.thinkingTail = Self.tail(of: state.thinkingTail + text)
                state.status = "writing…"
            case .toolCall(let summary):
                // "›", not "→": OpenSans has no U+2192 and there is no
                // per-glyph fallback, so an arrow draws as a tofu box.
                state.activity.append("› \(summary)")
                state.status = "checking the rule against your log…"
                state.thinkingTail = ""
            case .toolResult(let text):
                state.activity.append(Self.firstLine(of: text))
                if let detail = Self.failureDetail(of: text) {
                    state.activity.append("   \(detail)")
                }
            case .accepted(let check):
                state.suggestion = check.ruleText
                state.status = "done — matched \(check.matchedCount) of "
                    + "\(check.outcomes.count) sample lines"
                state.isRunning = false
            case .gaveUp(let why):
                state.problem = why
                state.status = "gave up"
                state.isRunning = false
            case .failed(let why):
                state.problem = why
                state.status = "failed"
                state.isRunning = false
            }
        }
        scheduleRefresh()
    }

    private func finish(problem: String) {
        lock.withLock {
            state.problem = problem
            state.status = "failed"
            state.isRunning = false
        }
        scheduleRefresh()
    }

    /// At most one pending body rebuild, however many events arrive.
    private func scheduleRefresh() {
        let shouldPost = lock.withLock { () -> Bool in
            if refreshPending { return false }
            refreshPending = true
            return true
        }
        guard shouldPost else { return }
        MainQueue.async { [self] in
            lock.withLock { refreshPending = false }
            ViewInvalidation.markNeedsBody()
        }
    }

    func clearSuggestion() {
        lock.withLock {
            state.suggestion = nil
            state.status = ""
            state.activity = []
        }
        ViewInvalidation.markNeedsBody()
    }

    private static func tail(of text: String, limit: Int = 160) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.suffix(limit))
    }

    private static func firstLine(of text: String) -> String {
        String(text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
    }

    /// The one line of a rejection that says what actually went wrong, so the
    /// activity list is useful without reproducing the whole report.
    private static func failureDetail(of text: String) -> String? {
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("-> ") && line != "-> no match" {
                return String(line.dropFirst(3))
            }
        }
        return nil
    }
}
