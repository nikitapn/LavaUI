// Phase 0c — Font::measure across the C++ boundary (throwaway spike).
//
// Goal: construct canvas::Font from Swift, load a face, call both
// measure overloads (including availWidth + mode), confirm TextMetrics
// imports as a usable value type under -std=c++23.

#if canImport(CxxCanvas)
import CxxCanvas
import Foundation

enum Spike0c {
    static func assetsFontPath() -> String {
        if let env = ProcessInfo.processInfo.environment["CANVAS_ASSETS_ROOT"],
           !env.isEmpty
        {
            return "\(env)/assets/OpenSans-Regular.ttf"
        }
        // Sources/Phase0Spikes → repo root → canvas/.build.Debug/assets
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("canvas/.build.Debug/assets/OpenSans-Regular.ttf")
            .path
    }

    static func run() -> Bool {
        print("=== 0c: Font::measure interop ===")

        let path = assetsFontPath()
        print("  font path: \(path)")
        guard FileManager.default.fileExists(atPath: path) else {
            print("  FAIL: font file missing")
            return false
        }

        var font = canvas.Font()
        let loadResult = path.withCString { cPath in
            // load takes std::string — Swift bridges String via std.string
            // when using C++ interop; pass std.string explicitly for clarity.
            font.load(std.string(cPath), 16.0)
        }

        // VoidResult is std::expected<void, string>. has_value() is the
        // reliable check (value()/error() may not import cleanly).
        let loaded = loadResult.has_value()
        print("  load has_value: \(loaded)")
        guard loaded else {
            print("  FAIL: Font.load failed")
            return false
        }
        print("  isLoaded: \(font.isLoaded())")
        print("  lineHeight: \(font.lineHeight())")

        // Single-arg measure (YGMeasureModeUndefined path).
        let m0 = font.measure(std.string("Hello"))
        print("  measure(\"Hello\"): w=\(m0.width) h=\(m0.height) ascent=\(m0.ascent) descent=\(m0.descent)")

        // Three-arg measure — mode mirrors YGMeasureMode:
        //   Undefined=0, Exactly=1, AtMost=2
        let mUndef = font.measure(std.string("Hello World"), 0, 0)
        let mAtMost = font.measure(std.string("Hello World from measure"), 40, 2)
        let mExact = font.measure(std.string("Hello World from measure"), 40, 1)

        print("  measure Undefined: w=\(mUndef.width) h=\(mUndef.height)")
        print("  measure AtMost(40): w=\(mAtMost.width) h=\(mAtMost.height)")
        print("  measure Exactly(40): w=\(mExact.width) h=\(mExact.height)")

        var ok = true
        if m0.width <= 0 {
            print("  FAIL: single-arg measure width <= 0")
            ok = false
        }
        // Exactly: width is dictated by caller.
        if abs(mExact.width - 40) > 0.01 {
            print("  FAIL: Exactly mode should return width == availWidth (40), got \(mExact.width)")
            ok = false
        }
        // Wrapping: multi-line height > single-line height.
        if mAtMost.height <= mUndef.height {
            print("  FAIL: AtMost should wrap (height \(mAtMost.height) <= undef \(mUndef.height))")
            ok = false
        }
        // AtMost width may exceed availWidth when a single word is wider
        // than the line (documented CSS/Yoga behavior in font.hpp).
        if mAtMost.width > 40 {
            print("  note: AtMost width \(mAtMost.width) > 40 (unbreakable word overflow — expected)")
        }
        // TextMetrics is a Swift-visible value type (fields readable).
        let checksum = m0.width + m0.height + m0.ascent + m0.descent
        print("  TextMetrics checksum (value type OK): \(checksum)")

        print(ok ? "  PASS" : "  FAIL")
        return ok
    }
}

#else

enum Spike0c {
    static func run() -> Bool {
        print("=== 0c: SKIPPED (CxxCanvas not available) ===")
        return false
    }
}

#endif
