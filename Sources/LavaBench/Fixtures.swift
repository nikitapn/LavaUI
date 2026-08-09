import Foundation

/// Deterministic inputs, so a number from today is comparable with a number
/// from a month ago. Nothing here reads the user's disk or the network: a
/// baseline that depends on which log file happened to be lying around is
/// not a baseline.
enum Fixtures {
    /// Splitmix64. Inlined rather than using `SystemRandomNumberGenerator`
    /// because the fixtures must be byte-identical between runs and machines.
    struct Random {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func int(_ upperBound: Int) -> Int {
            upperBound <= 0 ? 0 : Int(next() % UInt64(upperBound))
        }

        mutating func pick<T>(_ options: [T]) -> T { options[int(options.count)] }
    }

    // MARK: - Logs

    /// Fixture strings are built once and reused: a 10 MB generate costs more
    /// than most of the scenarios that consume it, and paying it per
    /// repetition would drown the thing being measured.
    nonisolated(unsafe) private static var logCache: [Int: String] = [:]

    /// A log shaped like the ones TraceLoom is pointed at: a timestamp, a
    /// level, a subsystem, and a message of varying length. Pure ASCII with
    /// `\n` endings, which is the case `SoftWrap`'s fast path handles — a
    /// synthetic file of identical lines would benchmark the shape cache
    /// instead of the wrapper.
    static func log(lines: Int) -> String {
        if let hit = logCache[lines] { return hit }
        var rng = Random(seed: 0x10AD_ADEF_CE11)
        var out = ""
        // ~52 bytes a line; reserving up front keeps fixture build out of the
        // measured region even for the 10 MB case.
        out.reserveCapacity(lines * 56)
        let levels = ["INFO", "WARN", "ERROR", "DEBUG", "TRACE"]
        let subsystems = [
            "net.socket", "render.frame", "db.pool", "auth", "cache.lru",
            "index.build", "sync.worker", "vk.swapchain",
        ]
        let verbs = [
            "opened", "closed", "retried", "flushed", "evicted",
            "scheduled", "dropped", "rebuilt",
        ]
        for i in 0..<lines {
            let ms = i * 7
            let seconds = ms / 1000
            out += String(
                format: "%02d:%02d:%02d.%03d ",
                seconds / 3600, (seconds / 60) % 60, seconds % 60, ms % 1000
            )
            out += rng.pick(levels)
            out += " ["
            out += rng.pick(subsystems)
            out += "] "
            out += rng.pick(verbs)
            out += " id=\(rng.int(100_000)) took=\(rng.int(4000))us"
            if rng.int(8) == 0 {
                out += " detail=\(String(repeating: "x", count: 20 + rng.int(140)))"
            }
            out += "\n"
        }
        logCache[lines] = out
        return out
    }

    /// Line count for a byte budget, so scenario names can say "10mb" and
    /// mean it regardless of how the generator's average line length drifts.
    static func logOfApproximately(megabytes: Int) -> String {
        // One calibration pass, then scale. Generating and trimming a 10 MB
        // string twice would double fixture cost for no accuracy gain.
        let probe = log(lines: 2_000)
        let bytesPerLine = max(1, probe.utf8.count / 2_000)
        return log(lines: megabytes * 1_024 * 1_024 / bytesPerLine)
    }

    // MARK: - Poster art

    /// Uncompressed 24-bit TGA. Chosen over PNG because the point of the
    /// image scenarios is the *cache* — decode cost should be a small, stable
    /// constant, not zlib's opinion of the pixel data — and because writing
    /// one is 20 lines with no dependency. `stbi_load` reads it.
    static func writePoster(
        to url: URL, size: Int, hue: Int
    ) throws {
        var data = Data()
        var header = [UInt8](repeating: 0, count: 18)
        header[2] = 2                                  // uncompressed true-colour
        header[12] = UInt8(size & 0xFF)
        header[13] = UInt8((size >> 8) & 0xFF)
        header[14] = UInt8(size & 0xFF)
        header[15] = UInt8((size >> 8) & 0xFF)
        header[16] = 24                                // bits per pixel
        header[17] = 0x20                              // top-down row order
        data.append(contentsOf: header)

        var pixels = [UInt8]()
        pixels.reserveCapacity(size * size * 3)
        for y in 0..<size {
            for x in 0..<size {
                // BGR. A gradient per poster so no two decode to the same
                // pixels — an atlas that deduplicates would otherwise make
                // the cache look better than it is.
                pixels.append(UInt8((x * 255 / max(1, size - 1)) & 0xFF))
                pixels.append(UInt8((y * 255 / max(1, size - 1)) & 0xFF))
                pixels.append(UInt8((hue * 37) & 0xFF))
            }
        }
        data.append(contentsOf: pixels)
        try data.write(to: url)
    }

    /// `count` posters in `directory`, written once and reused across
    /// repetitions. Returns their paths in a stable order.
    static func posters(count: Int, size: Int, in directory: URL) throws -> [String] {
        let dir = directory.appendingPathComponent("posters-\(size)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        var paths: [String] = []
        for i in 0..<count {
            let url = dir.appendingPathComponent("poster-\(i).tga")
            if !FileManager.default.fileExists(atPath: url.path) {
                try writePoster(to: url, size: size, hue: i)
            }
            paths.append(url.path)
        }
        return paths
    }
}
