import Foundation

/// Per-widget paint cost, opt-in via `LAVAUI_PROFILE=1`.
///
/// Exists because tracking down a slow widget otherwise means manually
/// wrapping suspects in `FrameScheduler.now()` calls, rebuilding, reading a
/// log, and removing the probes again — which is exactly what it took to
/// find that a 40,000-point chart, not the editor next to it, was the
/// remaining cost after a large-file editor fix. This makes that the first
/// thing you check, not the last.
///
/// Timed at *widget* granularity — one entry per leaf (a `Canvas`, an
/// `EditorView`, a `Button`, …), not per draw primitive. Timing every
/// `rect`/`text`/`circle` call individually would add far more overhead than
/// the primitives themselves cost, swamping the very signal this exists to
/// find; a widget's *whole* paint is the right unit; a `Canvas` doing
/// something expensive internally still shows up as one number on one row.
public enum WidgetProfiler {
    public static let isEnabled: Bool =
        ProcessInfo.processInfo.environment["LAVAUI_PROFILE"] == "1"

    nonisolated(unsafe) private static var current: [String: Double] = [:]
    nonisolated(unsafe) private static var currentCounts: [String: Int] = [:]
    /// The last *fully built* frame — snapshotting mid-emit would show a
    /// partial, misleadingly-cheap frame if read while one was in flight.
    nonisolated(unsafe) private static var lastFrame: [String: Double] = [:]
    nonisolated(unsafe) private static var lastFrameCounts: [String: Int] = [:]

    static func beginFrame() {
        guard isEnabled else { return }
        current.removeAll(keepingCapacity: true)
        currentCounts.removeAll(keepingCapacity: true)
    }

    static func endFrame() {
        guard isEnabled else { return }
        lastFrame = current
        lastFrameCounts = currentCounts
    }

    static func record(_ label: String, seconds: Double) {
        current[label, default: 0] += seconds
        currentCounts[label, default: 0] += 1
    }

    /// One widget's paint, timed and attributed to `label` — an `agentId` if
    /// the view has one (the name an app already chose for this widget),
    /// else its structural label (the leaf kind: "Canvas", "EditorView", …).
    static func measure<T>(_ label: String, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let t0 = FrameScheduler.now()
        let result = body()
        record(label, seconds: FrameScheduler.now() - t0)
        return result
    }

    /// Most recently completed frame's per-widget cost, worst first.
    public static func snapshot() -> [(label: String, ms: Double, count: Int)] {
        lastFrame.map { label, seconds in
            (label: label, ms: seconds * 1000, count: lastFrameCounts[label] ?? 0)
        }.sorted { $0.ms > $1.ms }
    }
}
