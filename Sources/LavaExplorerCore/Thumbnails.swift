import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// The freedesktop thumbnail cache: where a picture's thumbnail lives, whether
/// the one there is still good, and how to write one.
///
/// Shared with every other file manager on the machine — Nautilus, Dolphin,
/// Thunar and GIMP all read and write `~/.cache/thumbnails` by the same rules
/// — so a folder of photos one of them already browsed opens with its
/// thumbnails here at once, and the work done here is not wasted on them. The
/// rules are the "Thumbnail Managing Standard":
///
/// - one file per picture and size, named by the MD5 of the picture's URI;
/// - a PNG whose `tEXt` chunks say which URI it is of (`Thumb::URI`) and the
///   picture's modification time when it was made (`Thumb::MTime`) — a
///   thumbnail whose time disagrees with the file's is stale;
/// - written privately (0600 in 0700 folders), and atomically.
///
/// Matching GLib byte for byte matters more than the spec's wording: the URI
/// is escaped the way `g_filename_to_uri` escapes it, because a different
/// escape is a different MD5 and a cache nobody else can find. And the time
/// is read either way it is written — GNOME writes microseconds now
/// (`1769514874.472564`), older tools whole seconds.
public enum ThumbnailCache {
    /// The sizes the standard names. Each is a longest edge in pixels.
    public enum Size: String, CaseIterable, Sendable {
        case normal
        case large

        public var pixels: UInt32 {
            switch self {
            case .normal: 128
            case .large: 256
            }
        }
    }

    /// `$XDG_CACHE_HOME/thumbnails`, or `~/.cache/thumbnails`.
    public static var root: String {
        let env = ProcessInfo.processInfo.environment
        let cache = env["XDG_CACHE_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? NSHomeDirectory() + "/.cache"
        return cache + "/thumbnails"
    }

    /// `file://` and the path, escaped as GLib's `g_filename_to_uri` does:
    /// bytes outside the set it leaves alone become `%XX`, upper case.
    public static func uri(forPath path: String) -> String {
        var out = "file://"
        out.reserveCapacity(path.utf8.count + 16)
        for byte in path.utf8 {
            if keepsUnescaped(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out += "%"
                out += hexDigit(byte >> 4)
                out += hexDigit(byte & 0x0F)
            }
        }
        return out
    }

    /// Where the thumbnail of `path` at `size` is, or would be.
    public static func path(for path: String, size: Size, root: String = root) -> String {
        "\(root)/\(size.rawValue)/\(MD5.hex(of: Array(uri(forPath: path).utf8))).png"
    }

    /// Where a failure to thumbnail `path` is recorded, so a file that will
    /// not decode is not decoded again every time its folder is opened.
    /// Under the app's own name, as the standard asks: another program's
    /// decoder may well manage what ours could not.
    public static func failurePath(for path: String, root: String = root) -> String {
        "\(root)/fail/lava-explorer/\(MD5.hex(of: Array(uri(forPath: path).utf8))).png"
    }

    /// A file's modification time as the cache records it.
    public struct Stamp: Equatable, Sendable {
        public var seconds: Int
        public var microseconds: Int

        public init(seconds: Int, microseconds: Int) {
            self.seconds = seconds
            self.microseconds = microseconds
        }

        /// The file's, from `stat`; nil when it is not there.
        public init?(ofFileAt path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            seconds = Int(info.st_mtim.tv_sec)
            microseconds = Int(info.st_mtim.tv_nsec) / 1000
        }

        /// What goes in `Thumb::MTime`: seconds and six digits of fraction,
        /// as GNOME writes it. Whole-second readers parse the integer part.
        public var text: String {
            "\(seconds)." + String(format: "%06d", microseconds)
        }

        /// Whether a recorded time is this one. A whole-second record — what
        /// the standard specifies and older tools write — matches on seconds
        /// alone; one with a fraction must match it too.
        public func matches(_ recorded: String) -> Bool {
            let parts = recorded.split(separator: ".", maxSplits: 1)
            guard let first = parts.first, let whole = Int(first), whole == seconds else {
                return false
            }
            guard parts.count == 2 else { return true }
            let digits = parts[1].prefix(6).padding(toLength: 6, withPad: "0", startingAt: 0)
            return Int(digits) == microseconds
        }
    }

    /// Whether the thumbnail at `thumbnail` is of `path` as it is now.
    public static func isValid(thumbnail: String, of path: String, stamp: Stamp) -> Bool {
        guard let data = FileManager.default.contents(atPath: thumbnail) else { return false }
        let text = PNGText.read(Array(data))
        guard text["Thumb::URI"] == uri(forPath: path),
              let recorded = text["Thumb::MTime"]
        else { return false }
        return stamp.matches(recorded)
    }

    /// `png` with the chunks that make it a thumbnail of `path`, written to
    /// `destination` privately and atomically — a reader in another process
    /// sees the old file or the new one, never half of one.
    public static func write(
        png: [UInt8], to destination: String, of path: String, stamp: Stamp
    ) throws {
        let tagged = PNGText.insert(
            ["Thumb::URI": uri(forPath: path), "Thumb::MTime": stamp.text,
             "Software": "LavaExplorer"],
            into: png
        )
        let folder = (destination as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = folder + "/.lava-\(UUID().uuidString.prefix(8)).png"
        guard FileManager.default.createFile(
            atPath: temporary, contents: Data(tagged), attributes: [.posixPermissions: 0o600]
        ) else {
            throw FileAccessError(path: destination, message: "Could not write the thumbnail")
        }
        guard rename(temporary, destination) == 0 else {
            let message = String(cString: strerror(errno))
            unlink(temporary)
            throw FileAccessError(path: destination, message: message)
        }
    }

    /// Whether a file is worth asking for a thumbnail of: what the engine can
    /// decode (the same list LavaView opens), not in the cache itself — a
    /// thumbnail of a thumbnail is a loop that writes forever — and not so
    /// large that decoding it would hold a worker for seconds.
    public static func wants(_ entry: FileEntry, root: String = root) -> Bool {
        guard !entry.isDirectory,
              extensions.contains((entry.name as NSString).pathExtension.lowercased()),
              !entry.path.hasPrefix(root + "/")
        else { return false }
        return (entry.size ?? 0) <= maxFileBytes
    }

    /// What `Engine::decodeImage` reads — `LavaViewCore.ImageFormats`,
    /// restated because this module must not depend on a picture viewer —
    /// less SVG (`drawsItself`).
    public static let extensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "jfif",
        "gif", "bmp", "tga", "hdr", "pnm", "ppm", "pgm", "pbm",
        "cr2",
    ]

    /// A picture that needs no thumbnail: it is drawn from the file itself,
    /// at the size of the box.
    ///
    /// SVG, for two reasons that point the same way. A shape rasterised at 22
    /// pixels is sharper than a 128-pixel PNG of it scaled down, and costs
    /// less than reading one. And a client could not make the PNG anyway: the
    /// rasteriser is librsvg, which only the compositor's build links
    /// (`CANVAS_HAVE_RSVG`) — so the compositor is the one place it can be
    /// drawn, which is what asking for the file by path does.
    public static func drawsItself(_ entry: FileEntry) -> Bool {
        !entry.isDirectory && (entry.name as NSString).pathExtension.lowercased() == "svg"
            && (entry.size ?? 0) <= maxFileBytes
    }

    /// 200 MB. A panorama of that size takes a worker the better part of a
    /// minute and gigabytes of memory to decode for a 24-pixel icon.
    public static let maxFileBytes: Int64 = 200 * 1024 * 1024

    private static func keepsUnescaped(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            return true
        default:
            return "/!$&'()*+,-.:=@_~".utf8.contains(byte)
        }
    }

    private static func hexDigit(_ nibble: UInt8) -> String {
        String(UnicodeScalar(nibble < 10 ? 48 + nibble : 55 + nibble))
    }
}

/// `tEXt` chunks in a PNG: reading them, and adding some.
public enum PNGText {
    private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    /// Every `tEXt` chunk before the image data, keyword to text. Empty for
    /// anything that is not a PNG. Bounded by the file: a chunk length that
    /// runs past the end stops the walk rather than reading past it.
    public static func read(_ png: [UInt8]) -> [String: String] {
        guard png.count >= 8, Array(png[0..<8]) == signature else { return [:] }
        var found: [String: String] = [:]
        var offset = 8
        while offset + 8 <= png.count {
            let length = Int(bigEndian32(png, offset))
            let type = String(decoding: png[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let dataStart = offset + 8
            guard length >= 0, dataStart + length + 4 <= png.count else { break }
            if type == "IDAT" || type == "IEND" { break }
            if type == "tEXt" {
                let body = png[dataStart..<(dataStart + length)]
                if let zero = body.firstIndex(of: 0) {
                    let key = String(decoding: body[body.startIndex..<zero], as: UTF8.self)
                    // Latin-1 by the standard; URIs are ASCII once escaped, so
                    // UTF-8 decoding loses nothing that matters here.
                    let value = String(decoding: body[(zero + 1)...], as: UTF8.self)
                    found[key] = value
                }
            }
            offset = dataStart + length + 4
        }
        return found
    }

    /// The image's size in pixels, from `IHDR` — which the format puts first,
    /// so the first 24 bytes of the file are enough. Nil for anything else.
    public static func size(of png: [UInt8]) -> (width: Int, height: Int)? {
        guard png.count >= 24, Array(png[0..<8]) == signature,
              String(decoding: png[12..<16], as: UTF8.self) == "IHDR"
        else { return nil }
        return (Int(bigEndian32(png, 16)), Int(bigEndian32(png, 20)))
    }

    /// `png` with a `tEXt` chunk per entry, placed straight after `IHDR`.
    /// Returned unchanged if it is not a PNG.
    public static func insert(_ text: [String: String], into png: [UInt8]) -> [UInt8] {
        guard png.count >= 33, Array(png[0..<8]) == signature else { return png }
        // IHDR is always first and always 13 bytes: 8 + 4 + 4 + 13 + 4.
        let afterHeader = 33
        var chunks: [UInt8] = []
        for (key, value) in text.sorted(by: { $0.key < $1.key }) {
            let body = Array(key.utf8) + [0] + Array(value.utf8)
            let typed = Array("tEXt".utf8) + body
            chunks += bigEndianBytes(UInt32(body.count))
            chunks += typed
            chunks += bigEndianBytes(CRC32.of(typed))
        }
        return Array(png[0..<afterHeader]) + chunks + Array(png[afterHeader...])
    }

    private static func bigEndian32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16
            | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }

    private static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}

/// The CRC every PNG chunk ends with (ISO 3309, as zlib computes it).
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func of(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in bytes { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

/// MD5, for thumbnail names only — the standard's choice, not a security one.
/// Foundation on Linux has no CommonCrypto, and this is all of it.
enum MD5 {
    private static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]
    private static let constants: [UInt32] = (0..<64).map {
        UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4_294_967_296))
    }

    static func hex(of message: [UInt8]) -> String {
        digest(message).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ message: [UInt8]) -> [UInt8] {
        var bytes = message
        let bitLength = UInt64(message.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for i in 0..<8 { bytes.append(UInt8((bitLength >> (8 * UInt64(i))) & 0xFF)) }

        var a0: UInt32 = 0x6745_2301
        var b0: UInt32 = 0xEFCD_AB89
        var c0: UInt32 = 0x98BA_DCFE
        var d0: UInt32 = 0x1032_5476
        var words = [UInt32](repeating: 0, count: 16)
        for chunk in stride(from: 0, to: bytes.count, by: 64) {
            for i in 0..<16 {
                let at = chunk + i * 4
                words[i] = UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8
                    | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32
                let g: Int
                switch i {
                case 0..<16: f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ constants[i] &+ words[g]
                a = d
                d = c
                c = b
                b = b &+ (f << shifts[i] | f >> (32 - shifts[i]))
            }
            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
        }
        return [a0, b0, c0, d0].flatMap { word in
            (0..<4).map { UInt8((word >> (8 * UInt32($0))) & 0xFF) }
        }
    }
}
