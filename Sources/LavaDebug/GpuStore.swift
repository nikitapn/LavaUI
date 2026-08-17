#if canImport(LavaIDL)
import Foundation
import LavaClient
import LavaIDL
import LavaUI
import Observation

/// Which view of the report is showing.
enum DebugSection: String, CaseIterable, Sendable {
    case overview
    case windows
    case atlases
    case textures
    case allocations

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .windows: return "Windows"
        case .atlases: return "Atlases"
        case .textures: return "Textures"
        case .allocations: return "Allocations"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "Totals and categories"
        case .windows: return "What each surface costs"
        case .atlases: return "Glyphs and images, as pictures"
        case .textures: return "The shared cache"
        case .allocations: return "Every allocation, largest first"
        }
    }
}

/// The report, and the only thing here that talks to the compositor.
///
/// Polled rather than streamed. Allocation is bursty — a window opens and 130 MB
/// appears in one frame, then nothing changes for a minute — so there is no
/// useful "change" to subscribe to, and a snapshot a second is both cheaper and
/// easier to reason about than a stream that would mostly carry no news.
@Observable
final class GpuStore {
    /// The last report that arrived. Empty until the first one does.
    var report = GpuReport()
    var section: DebugSection = .overview

    /// False in a windowed build or if the compositor went away — the window
    /// then says so rather than showing a page of zeroes.
    var connected = false
    var status = ""
    var statusIsError = false

    /// Wall-clock of the last successful refresh, for the header.
    var lastRefresh: Date?

    /// Where the atlas PNGs were written, most recent call. Kept separately
    /// from the report's own `pngPath` because a later poll overwrites the
    /// report and the images stay on disk regardless.
    var atlasImages: [String] = []
    var dumping = false

    /// Auto-refresh, and the interval in seconds.
    var live = true
    var interval: Double = 1

    private var nextRefresh: Date = .distantPast

    init() {
        connected = DesktopDiagnostics.isAvailable
        if !connected {
            note("Not running under the Lava compositor — nothing to report.",
                 isError: true)
        }
    }

    /// Called once per frame from the view. Cheap when nothing is due, which is
    /// what lets a frame loop drive the polling without a timer of its own.
    func tick() {
        guard connected, live, Date() >= nextRefresh else { return }
        refresh()
    }

    func refresh() {
        nextRefresh = Date().addingTimeInterval(interval)
        guard connected else { return }
        do {
            report = try DesktopDiagnostics.gpuReport()
            lastRefresh = Date()
            if statusIsError { note("") }
        } catch {
            note("Could not read the GPU report: \(error)", isError: true)
        }
    }

    /// Writes the atlas pages and points the Atlases page at them.
    ///
    /// Into the runtime directory rather than /tmp: a page can be hundreds of
    /// megabytes, and `XDG_RUNTIME_DIR` is the per-session place that gets
    /// cleaned up when the session ends.
    func dumpAtlases() {
        guard connected, !dumping else { return }
        dumping = true
        defer { dumping = false }
        do {
            let paths = try DesktopDiagnostics.dumpAtlasImages(into: Self.dumpDirectory)
            atlasImages = paths
            note(paths.isEmpty ? "No atlas pages to write."
                               : "Wrote \(paths.count) page(s) to \(Self.dumpDirectory).")
            // The paths belong in the report the page reads from, so a redraw
            // shows the images without waiting for the next poll.
            for index in report.atlases.indices {
                report.atlases[index].pngPath =
                    Self.matchingPath(for: report.atlases[index], in: paths) ?? ""
            }
        } catch {
            note("Could not write the atlas pages: \(error)", isError: true)
        }
    }

    static let dumpDirectory: String = {
        let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"]
        return (runtime ?? "/tmp") + "/lava-atlases"
    }()

    /// Which file belongs to which page, by the names `dumpAtlasPages` writes.
    private static func matchingPath(for page: GpuAtlas,
                                    in paths: [String]) -> String? {
        let wanted = page.kind == 0
            ? "glyph-atlas-gen\(page.generation).png"
            : "image-atlas-page\(page.page).png"
        return paths.first { $0.hasSuffix(wanted) }
    }

    func note(_ text: String, isError: Bool = false) {
        status = text
        statusIsError = isError
    }
}

// MARK: - Formatting

/// Bytes as a human reads them.
///
/// One decimal above KiB, none below: the question is usually "is this
/// hundreds of megabytes", and 63.8 MiB answers it where 66,846,720 does not.
func humanBytes(_ bytes: UInt64) -> String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024, unit + 1 < units.count {
        value /= 1024
        unit += 1
    }
    return unit == 0
        ? "\(Int(value)) \(units[unit])"
        : String(format: "%.1f %@", value, units[unit])
}

func percent(_ part: UInt64, of whole: UInt64) -> Int {
    guard whole > 0 else { return 0 }
    return Int((part * 100) / whole)
}
#endif
