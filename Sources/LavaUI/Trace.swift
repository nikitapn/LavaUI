#if LAVA_TRACY && os(Linux)
import CTracy
import Glibc
#endif

/// Tracy zones, frames and plots, from Swift.
///
/// Compiled in only by `LAVA_TRACY=1 swift build` (or `=full`, which records
/// from launch rather than from the moment a profiler connects). Without it
/// every call here is its closure and nothing else — no C call, no string
/// conversion — so instrumenting a hot path costs a build that asked for it
/// and no other.
///
/// The process has one Tracy, in CTracy, shared with the canvas engine: in a
/// windowed app (`env -u LAVA_CLIENT`) one capture holds body, layout and
/// emit, the engine's recording and submit, and the GPU's passes. In client
/// mode the app and the compositor are two Tracy clients on two ports, and the
/// profiler shows one at a time.
///
/// Names are `StaticString`: a literal's bytes are passed straight through,
/// and Tracy identifies frames and plots by the *address* of their name,
/// which a literal keeps for the life of the process.
public enum Trace {
    /// Whether this build records anything at all.
    public static var isCompiled: Bool {
        #if LAVA_TRACY && os(Linux)
        lava_trace_compiled() != 0
        #else
        false
        #endif
    }

    /// Runs `body` inside a zone named `name`.
    @inline(__always) @discardableResult
    public static func zone<R>(
        _ name: StaticString,
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line,
        _ body: () throws -> R
    ) rethrows -> R {
        #if LAVA_TRACY && os(Linux)
        let zone = begin(name, file: file, function: function, line: line)
        defer { zone.end() }
        return try body()
        #else
        return try body()
        #endif
    }

    /// A zone open until `end()`, for a span that is not one closure. Zones on
    /// a thread must end in the reverse of the order they began.
    public struct Zone {
        #if LAVA_TRACY && os(Linux)
        fileprivate let handle: lava_trace_zone
        #endif

        @inline(__always)
        public func end() {
            #if LAVA_TRACY && os(Linux)
            lava_trace_zone_end(handle)
            #endif
        }

        /// Text shown with the zone — which window, which file.
        @inline(__always)
        public func text(_ text: @autoclosure () -> String) {
            #if LAVA_TRACY && os(Linux)
            var text = text()
            text.withUTF8 { lava_trace_zone_text(handle, $0.baseAddress, $0.count) }
            #endif
        }

        /// A number shown with the zone — nodes visited, commands emitted.
        @inline(__always)
        public func value(_ value: Int) {
            #if LAVA_TRACY && os(Linux)
            lava_trace_zone_value(handle, UInt64(truncatingIfNeeded: value))
            #endif
        }
    }

    @inline(__always)
    public static func begin(
        _ name: StaticString,
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) -> Zone {
        #if LAVA_TRACY && os(Linux)
        name.withUTF8Buffer { name in
            function.withUTF8Buffer { function in
                file.withUTF8Buffer { file in
                    Zone(handle: lava_trace_zone_begin(
                        name.baseAddress, name.count,
                        function.baseAddress, function.count,
                        file.baseAddress, file.count,
                        UInt32(truncatingIfNeeded: line), 0))
                }
            }
        }
        #else
        Zone()
        #endif
    }

    /// The end of a frame of the process's main frame set.
    @inline(__always)
    public static func frameMark() {
        #if LAVA_TRACY && os(Linux)
        lava_trace_frame_mark(nil)
        #endif
    }

    /// The end of a frame of the named set. `name` must stay at one address
    /// — see `FrameSet`.
    @inline(__always)
    public static func frameMark(_ set: FrameSet) {
        #if LAVA_TRACY && os(Linux)
        lava_trace_frame_mark(set.name)
        #endif
    }

    /// One sample of a plot.
    @inline(__always)
    public static func plot(_ name: StaticString, _ value: Double) {
        #if LAVA_TRACY && os(Linux)
        guard name.hasPointerRepresentation else { return }
        name.utf8Start.withMemoryRebound(to: CChar.self, capacity: name.utf8CodeUnitCount + 1) {
            lava_trace_plot($0, value)
        }
        #endif
    }

    /// A line in the capture's message list, at this moment.
    @inline(__always)
    public static func message(_ text: @autoclosure () -> String) {
        #if LAVA_TRACY && os(Linux)
        var text = text()
        text.withUTF8 { lava_trace_message($0.baseAddress, $0.count) }
        #endif
    }

    /// A frame set named at run time — one per window. Tracy keys a set by
    /// the address of its name, so the name is copied once and never freed:
    /// a few bytes per window ever opened.
    public final class FrameSet: @unchecked Sendable {
        #if LAVA_TRACY && os(Linux)
        fileprivate let name: UnsafeMutablePointer<CChar>
        #endif

        public init(_ name: String) {
            #if LAVA_TRACY && os(Linux)
            self.name = strdup(name)
            #endif
        }
    }
}
