import Foundation

/// Reading a log file off disk, with the failure modes spelled out.
///
/// Split out of the view because everything interesting here is an error path,
/// and those are worth testing without a window. The original
/// `try? String(contentsOf:encoding:)` collapsed all of them — missing file,
/// unreadable file, one stray non-UTF-8 byte — into the same silent no-op,
/// which from the outside is indistinguishable from a rejected file, a long
/// parse, or a stalled UI.
///
/// Size is deliberately *not* one of those failure modes below the limit.
/// Reading is ~1.5ms/MB and parsing is linear with no cliff (a 12 MB log
/// parses in ~3s, a 57 MB one in ~17s), so a large log is slow, not rejected.
public enum LogFile {
    /// A log that was read, plus anything the user should be told about how.
    public struct Load: Sendable {
        public var text: String
        /// Non-nil when the file loaded but not cleanly — currently only the
        /// lossy-decode path below.
        public var warning: String?

        public init(text: String, warning: String? = nil) {
            self.text = text
            self.warning = warning
        }
    }

    public enum LoadError: Error, CustomStringConvertible, Equatable {
        case unreadable(path: String, underlying: String)
        case tooLarge(path: String, bytes: Int, limit: Int)

        public var description: String {
            switch self {
            case let .unreadable(path, underlying):
                return "Could not read \(path): \(underlying)"
            case let .tooLarge(path, bytes, limit):
                return "\(path) is \(LogFile.mb(bytes)) MB, over the "
                    + "\(LogFile.mb(limit)) MB limit TraceLoom loads into memory"
            }
        }
    }

    /// Largest file pulled into memory as a single `String`. A resource bound,
    /// not a supported-format one: past it the honest answer is a clear error
    /// rather than an allocation the machine may not survive.
    public static let byteLimit = 256 * 1024 * 1024

    public static func read(at url: URL) throws -> Load {
        let path = url.path

        // Checked before reading: the point is to refuse the allocation, so
        // discovering the size by performing it would defeat it.
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        if let bytes = attributes?[.size] as? Int, bytes > byteLimit {
            throw LoadError.tooLarge(path: path, bytes: bytes, limit: byteLimit)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            // `localizedDescription`, not `"\(error)"`: the latter is an
            // NSError dump with a nested UserInfo that repeats the path three
            // times, which is unreadable in a one-line banner and hides the
            // one sentence that says what actually went wrong.
            throw LoadError.unreadable(path: path, underlying: error.localizedDescription)
        }

        if let text = String(data: data, encoding: .utf8) {
            return Load(text: normalizingNewlines(text))
        }

        // One stray byte — a Latin-1 accent, a truncated multibyte sequence, a
        // binary fragment spliced in by log rotation — must not cost the user
        // the entire file, which is exactly what the old `try?` did. Decoding
        // lossily keeps every valid sequence intact and substitutes U+FFFD for
        // the rest, so the log still opens; the warning is what keeps that
        // from being another silent surprise.
        let text = normalizingNewlines(String(decoding: data, as: UTF8.self))
        let warning: String
        if let offset = firstInvalidUTF8Offset(in: data) {
            warning = "\(path): not valid UTF-8 at byte \(offset) "
                + "(line \(lineNumber(of: offset, in: data))); "
                + "decoded with replacement characters"
        } else {
            warning = "\(path): not valid UTF-8; decoded with replacement characters"
        }
        return Load(text: text, warning: warning)
    }

    /// Rewrites CRLF and lone CR to LF.
    ///
    /// Not cosmetic — load-bearing. Swift treats `"\r\n"` as a *single*
    /// grapheme cluster which is not equal to `Character("\n")`, so
    /// `split(separator: "\n")` finds nothing in a CRLF file and reports the
    /// whole buffer as one line. A 23 MB Android log taken off a Windows box
    /// therefore became a single 23-million-character line: the editor tried
    /// to shape it as one run, and the process grew past 9 GB before it was
    /// killed. Parsing degenerated the same way, silently, into a timeline
    /// with one point.
    ///
    /// Normalising here rather than teaching every consumer about CRLF: the
    /// alternative is making caret arithmetic, wrapping, parsing and line
    /// indexing each handle a two-byte terminator, and any one of them
    /// forgetting reintroduces this.
    ///
    /// Fast path first — the scan is a byte compare and the overwhelming
    /// majority of logs have no CR at all, so they pay one pass and no copy.
    public static func normalizingNewlines(_ text: String) -> String {
        guard text.utf8.contains(0x0D) else { return text }
        var out = [UInt8]()
        out.reserveCapacity(text.utf8.count)
        var previousWasCR = false
        for byte in text.utf8 {
            if byte == 0x0D {
                out.append(0x0A)
                previousWasCR = true
                continue
            }
            // The LF of a CRLF pair was already emitted by the CR above.
            if byte == 0x0A, previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = false
            out.append(byte)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Byte offset of the first invalid UTF-8 sequence, or nil if the buffer
    /// is wholly valid. Reported instead of just "bad encoding" because on a
    /// million-line log the only actionable part is *where*.
    public static func firstInvalidUTF8Offset(in data: Data) -> Int? {
        data.withUnsafeBytes { raw -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < bytes.count {
                let b = bytes[i]
                if b < 0x80 { i += 1; continue }
                // Continuation-byte ranges are tightened on the first trailing
                // byte for the four sequences that would otherwise admit
                // overlongs (0xE0, 0xF0) or surrogates/out-of-range (0xED, 0xF4).
                let need: Int
                var lower: UInt8 = 0x80
                var upper: UInt8 = 0xBF
                switch b {
                case 0xC2...0xDF: need = 1
                case 0xE0: need = 2; lower = 0xA0
                case 0xE1...0xEC, 0xEE...0xEF: need = 2
                case 0xED: need = 2; upper = 0x9F
                case 0xF0: need = 3; lower = 0x90
                case 0xF1...0xF3: need = 3
                case 0xF4: need = 3; upper = 0x8F
                default: return i
                }
                guard i + need < bytes.count else { return i }
                if bytes[i + 1] < lower || bytes[i + 1] > upper { return i }
                if need >= 2 {
                    for k in 2...need where bytes[i + k] < 0x80 || bytes[i + k] > 0xBF {
                        return i
                    }
                }
                i += need + 1
            }
            return nil
        }
    }

    private static func lineNumber(of offset: Int, in data: Data) -> Int {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var line = 1
            for i in 0..<min(offset, bytes.count) where bytes[i] == 0x0A { line += 1 }
            return line
        }
    }

    private static func mb(_ bytes: Int) -> String {
        String(format: "%.1f", Double(bytes) / (1024 * 1024))
    }
}
