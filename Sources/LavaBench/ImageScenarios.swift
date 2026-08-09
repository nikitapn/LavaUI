import Foundation
import LavaUI

/// `ImageStore` behaviour under a grid of cover art.
///
/// Deliberately driven through the **synchronous** `load(path:into:)` rather
/// than `imageIfLoaded`. The async path decodes on a detached thread and
/// publishes through `MainQueue`, so without a run loop it would measure how
/// long a benchmark waits, and with one it would measure thread scheduling.
/// The cache policy — what is resident, what gets evicted, how often the same
/// poster is decoded twice — is identical either way, and that policy is what
/// regresses.
enum ImageScenarios {
    private static let posterCount = 96
    private static let posterSize = 192

    /// Bytes one decoded poster occupies (`ImageStore` charges width×height×4).
    private static var posterBytes: Int { posterSize * posterSize * 4 }

    static func all() -> [Scenario] {
        var scenarios: [Scenario] = []

        scenarios.append(
            Scenario(
                "image.poster-decode-cold",
                detail: "\(posterCount) covers at \(posterSize)px, empty cache",
                // One repetition, deliberately. `ImageStore.clearCache()` drops
                // LavaUI's entries but the engine's `TextureManager` keeps its
                // own ref-counted copy, so repetitions 2..n measure an engine
                // cache hit — 0.05 ms against the first run's 56 ms. Taking the
                // minimum of those would report a genuinely cold decode as free.
                iterations: 1,
                body: { harness, rec in
                    guard let paths = try? Fixtures.posters(
                        count: posterCount, size: posterSize, in: harness.scratch
                    ) else {
                        rec.require(false, "could not write poster fixtures")
                        return
                    }
                    ImageStore.clearCache()
                    ImageStore.budgetBytes = 256 * 1024 * 1024
                    rec.stage("decode") {
                        for path in paths {
                            _ = ImageStore.load(path: path, into: harness.editor)
                        }
                    }
                    rec.counter("resident", ImageStore.count)
                    rec.counter("residentMB", ImageStore.residentByteCount / (1024 * 1024))
                }
            )
        )

        scenarios.append(
            Scenario(
                "image.poster-cache-hit",
                detail: "re-request the same covers — should decode nothing",
                iterations: 10,
                body: { harness, rec in
                    guard let paths = try? Fixtures.posters(
                        count: posterCount, size: posterSize, in: harness.scratch
                    ) else {
                        rec.require(false, "could not write poster fixtures")
                        return
                    }
                    ImageStore.clearCache()
                    ImageStore.budgetBytes = 256 * 1024 * 1024
                    for path in paths {          // untimed warm-up
                        _ = ImageStore.load(path: path, into: harness.editor)
                    }
                    PerfCounters.reset()
                    rec.stage("lookup") {
                        for path in paths {
                            _ = ImageStore.load(path: path, into: harness.editor)
                        }
                    }
                    // The gate. `decodes` must stay 0: a keying change (the
                    // `@maxPixelSize` suffix, say) turns every hit into a
                    // silent re-decode that only shows up as "scrolling feels
                    // heavy" months later.
                    rec.require(
                        PerfCounters.imageDecodes == 0,
                        "warm cache re-decoded \(PerfCounters.imageDecodes) covers"
                    )
                }
            )
        )

        // The thrash case the eviction policy exists to prevent: a working set
        // larger than the budget, scrolled down and back up. Counts, not
        // milliseconds, are the signal — "evict on scroll-out" would make
        // `decodes` roughly one per cell visited, while a byte budget with LRU
        // keeps it near the number of cells that genuinely did not fit.
        scenarios.append(
            Scenario(
                "image.poster-scroll-thrash",
                detail: "window of 24 over \(posterCount) covers, budget holds 32, down+up",
                iterations: 3,
                body: { harness, rec in
                    guard let paths = try? Fixtures.posters(
                        count: posterCount, size: posterSize, in: harness.scratch
                    ) else {
                        rec.require(false, "could not write poster fixtures")
                        return
                    }
                    ImageStore.clearCache()
                    ImageStore.budgetBytes = 32 * posterBytes
                    PerfCounters.reset()

                    let window = 24
                    let step = 6
                    var offsets = Array(stride(from: 0, through: posterCount - window, by: step))
                    offsets += offsets.reversed()

                    rec.stage("scroll") {
                        for start in offsets {
                            for i in start..<(start + window) {
                                _ = ImageStore.load(path: paths[i], into: harness.editor)
                            }
                            // What the run loop calls after each present. It is
                            // also what makes "not drawn this frame" mean
                            // anything — eviction skips entries touched this
                            // frame, so the frame boundary has to be real.
                            ImageStore.endFrame(into: harness.editor)
                        }
                    }
                    rec.counter("frames", offsets.count)
                    rec.counter("cellVisits", offsets.count * window)
                    rec.counter("resident", ImageStore.count)
                    // Not a fixed number — that would be asserting the current
                    // LRU order rather than the property. One decode per visit
                    // is the failure mode, and it is 4x away from anything the
                    // policy produces.
                    rec.require(
                        PerfCounters.imageDecodes < offsets.count * window / 2,
                        "cache thrashing: \(PerfCounters.imageDecodes) decodes "
                            + "for \(offsets.count * window) visits"
                    )
                    // Budget is a ceiling, not a suggestion.
                    rec.require(
                        ImageStore.residentByteCount <= ImageStore.budgetBytes,
                        "over budget: \(ImageStore.residentByteCount) > \(ImageStore.budgetBytes)"
                    )
                }
            )
        )

        return scenarios
    }
}
