import Foundation

/// What a photograph says about itself: the dozen EXIF fields anybody reads.
///
/// A fixed list on purpose. EXIF has hundreds of tags and a maker-note swamp
/// under them, and a panel that showed all of it would be a hex dump with
/// labels. What a person wants from a photo is which camera and lens, how it
/// was exposed, when, and — sometimes — where.
///
/// Every field is optional and independent: a scanner writes a make and no
/// exposure, a phone writes everything, an edited file keeps some of it. One
/// missing field never hides another.
public struct PhotoInfo: Equatable, Sendable {
    public var make: String?
    public var model: String?
    public var lens: String?
    public var software: String?
    /// "YYYY:MM:DD HH:MM:SS", as EXIF stores it: when the shutter fired if
    /// the camera said, else when the file was last written by whatever wrote
    /// it.
    public var taken: String?
    /// Seconds.
    public var exposureTime: Double?
    public var fNumber: Double?
    public var iso: Int?
    /// Millimetres, the lens's real focal length.
    public var focalLength: Double?
    /// What that lens would be on a 35 mm frame, which is the number people
    /// compare. Many cameras leave it out.
    public var focalLength35: Int?
    /// EV, signed.
    public var exposureBias: Double?
    /// Whether the flash fired, when the camera said.
    public var flashFired: Bool?
    public var latitude: Double?
    public var longitude: Double?
    /// Metres; negative below sea level.
    public var altitude: Double?

    public init() {}

    /// True when the file said nothing worth a row.
    public var isEmpty: Bool { rows.isEmpty }

    /// The panel's rows, in the order they are read: what took it, how, when,
    /// where. Labels are fixed strings; values are already formatted.
    public var rows: [(label: String, value: String)] {
        var out: [(String, String)] = []
        if let camera = cameraName { out.append(("Camera", camera)) }
        if let lens = Self.clean(lens) { out.append(("Lens", lens)) }
        if let exposure = exposureTime.flatMap(Self.formatExposure) {
            out.append(("Exposure", exposure))
        }
        if let f = fNumber, f > 0 { out.append(("Aperture", "f/" + Self.trim(f, digits: 1))) }
        if let iso, iso > 0 { out.append(("ISO", String(iso))) }
        if let focal = focalDescription { out.append(("Focal length", focal)) }
        if let bias = exposureBias, abs(bias) >= 0.05 {
            out.append(("Exposure bias", (bias > 0 ? "+" : "−") + Self.trim(abs(bias), digits: 1) + " EV"))
        }
        if let fired = flashFired { out.append(("Flash", fired ? "Fired" : "Did not fire")) }
        if let taken = taken.flatMap(Self.formatDate) { out.append(("Taken", taken)) }
        if let place = location { out.append(("Location", place)) }
        if let altitude { out.append(("Altitude", Self.trim(altitude, digits: 0) + " m")) }
        if let software = Self.clean(software) { out.append(("Software", software)) }
        return out
    }

    /// "Canon EOS 5D Mark II", not "Canon Canon EOS 5D Mark II": most makers
    /// repeat their name in the model, some do not, and a few write it in
    /// capitals in one field and not the other.
    public var cameraName: String? {
        let make = Self.clean(make)
        let model = Self.clean(model)
        switch (make, model) {
        case (nil, nil): return nil
        case (let make?, nil): return make
        case (nil, let model?): return model
        case (let make?, let model?):
            let brand = make.split(separator: " ").first.map(String.init) ?? make
            if model.lowercased().hasPrefix(brand.lowercased()) { return model }
            // "NIKON CORPORATION" + "NIKON D750" is caught above; "SONY" +
            // "ILCE-7M3" is not repeated and wants the brand in front.
            return "\(Self.titled(brand)) \(model)"
        }
    }

    var focalDescription: String? {
        guard let focal = focalLength, focal > 0 else { return nil }
        var text = Self.trim(focal, digits: 1) + " mm"
        if let equivalent = focalLength35, equivalent > 0,
           abs(Double(equivalent) - focal) >= 0.5
        {
            text += " (\(equivalent) mm equivalent)"
        }
        return text
    }

    /// "48.858370° N, 2.294481° E". Coordinates only: turning them into a
    /// place name is a network request, and an image viewer has no business
    /// telling a server where somebody's photographs were taken.
    public var location: String? {
        guard let latitude, let longitude,
              latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180,
              // 0,0 is a camera with a GPS that had no fix, not the Gulf of
              // Guinea.
              !(latitude == 0 && longitude == 0)
        else { return nil }
        let lat = String(format: "%.6f° %@", abs(latitude), latitude >= 0 ? "N" : "S")
        let lon = String(format: "%.6f° %@", abs(longitude), longitude >= 0 ? "E" : "W")
        return "\(lat), \(lon)"
    }

    // MARK: - Formatting

    /// "1/250 s" below a second, "2.5 s" above it — the way every camera's
    /// own screen shows it.
    static func formatExposure(_ seconds: Double) -> String? {
        guard seconds > 0, seconds.isFinite else { return nil }
        if seconds >= 1 { return trim(seconds, digits: 1) + " s" }
        let denominator = (1 / seconds).rounded()
        // 1/3 and 0.3 s are the same thing; a fraction that does not land on
        // a whole denominator is shown as the decimal instead.
        if abs(1 / denominator - seconds) / seconds > 0.05 {
            return trim(seconds, digits: 3) + " s"
        }
        return "1/\(Int(denominator)) s"
    }

    /// "2024:05:01 12:34:56" → "2024-05-01 12:34:56". Not localised: an EXIF
    /// date has no time zone, so a clock-time rendering would claim a
    /// precision the file does not have. A malformed one is shown as written.
    static func formatDate(_ raw: String) -> String? {
        guard let text = clean(raw) else { return nil }
        // Cameras with no clock set write zeros or spaces.
        if text.hasPrefix("0000") || text.allSatisfy({ $0 == " " || $0 == ":" }) { return nil }
        let parts = text.split(separator: " ", maxSplits: 1)
        guard let date = parts.first, date.count == 10 else { return text }
        let day = date.replacingOccurrences(of: ":", with: "-")
        return parts.count > 1 ? "\(day) \(parts[1])" : day
    }

    /// At most `digits` places, and none that are zero: "f/8", "f/2.8".
    static func trim(_ value: Double, digits: Int) -> String {
        var text = String(format: "%.\(digits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    /// Trimmed of the padding and NULs cameras leave in fixed-size fields;
    /// nil when nothing is left.
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "CANON" → "Canon", left alone when already mixed case.
    static func titled(_ word: String) -> String {
        guard word == word.uppercased(), word.count > 3 else { return word }
        return word.prefix(1) + word.dropFirst().lowercased()
    }
}

/// Reads `PhotoInfo` out of the head of an image file.
///
/// Pure and bounds-checked throughout: the bytes are a stranger's, every
/// offset in them is a claim, and a claim that points outside the buffer is
/// answered with "not there" rather than a crash. The same containers the
/// decoder's orientation reader (`canvas/src/render/exif.cpp`) understands —
/// JPEG's APP1, PNG's `eXIf`, and a bare TIFF, which is also what a camera raw
/// is — but on this side of the line: an orientation changes the pixels a
/// decoder must return, and a lens name does not.
public enum PhotoInfoReader {
    /// How much of a file is read. A JPEG's EXIF lives in its first segment
    /// or two; 256 KiB covers a large ICC profile in front of it as well.
    public static let headBytes = 256 * 1024

    /// Nil when the file cannot be read or carries nothing.
    public static func read(path: String) -> PhotoInfo? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headBytes), !data.isEmpty else {
            return nil
        }
        return read([UInt8](data))
    }

    public static func read(_ bytes: [UInt8]) -> PhotoInfo? {
        guard let base = tiffOffset(in: bytes),
              let tiff = TIFF(bytes: bytes, base: base)
        else { return nil }
        let info = tiff.photoInfo()
        return info.isEmpty ? nil : info
    }

    // MARK: - Containers

    static func tiffOffset(in b: [UInt8]) -> Int? {
        if b.count >= 4,
           (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00)
            || (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0x00 && b[3] == 0x2A)
        {
            return 0
        }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xD8 { return jpegExif(b) }
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if b.count >= 8, Array(b[0..<8]) == png { return pngExif(b) }
        return nil
    }

    /// The TIFF header inside the first `Exif\0\0` APP1 segment.
    static func jpegExif(_ b: [UInt8]) -> Int? {
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            // Fill bytes before a marker are legal.
            if marker == 0xFF { i += 1; continue }
            // Start of scan or end of image: the metadata is behind us.
            if marker == 0xDA || marker == 0xD9 { return nil }
            // Standalone markers carry no length.
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2 else { return nil }
            let body = i + 4
            if marker == 0xE1, body + 6 <= b.count,
               b[body] == 0x45, b[body + 1] == 0x78, b[body + 2] == 0x69,
               b[body + 3] == 0x66, b[body + 4] == 0, b[body + 5] == 0
            {
                return body + 6
            }
            i += 2 + length
        }
        return nil
    }

    /// The data of a PNG's `eXIf` chunk, wherever in the head it is.
    static func pngExif(_ b: [UInt8]) -> Int? {
        var i = 8
        while i + 8 <= b.count {
            let length = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 0, length <= b.count else { return nil }
            let type = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
            if type == "eXIf" { return i + 8 }
            if type == "IEND" { return nil }
            // Length, type, data, CRC.
            let next = i + 12 + length
            guard next > i else { return nil }
            i = next
        }
        return nil
    }
}

// MARK: - TIFF

/// A TIFF structure inside `bytes`, starting at `base`. Every read is checked.
struct TIFF {
    let bytes: [UInt8]
    let base: Int
    let bigEndian: Bool

    /// The most entries one directory is believed to have. Real ones have a
    /// few dozen; this stops a corrupt count of 65535 from being walked.
    static let maxEntries = 512

    init?(bytes: [UInt8], base: Int) {
        guard base >= 0, base + 8 <= bytes.count else { return nil }
        self.bytes = bytes
        self.base = base
        switch (bytes[base], bytes[base + 1]) {
        case (0x49, 0x49): bigEndian = false
        case (0x4D, 0x4D): bigEndian = true
        default: return nil
        }
        guard u16(2) == 42 else { return nil }
    }

    struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: Int
        /// Offset of the value, relative to `base`.
        let valueOffset: Int
    }

    func u16(_ offset: Int) -> UInt16? {
        let at = base + offset
        guard offset >= 0, at + 2 <= bytes.count else { return nil }
        return bigEndian
            ? UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
            : UInt16(bytes[at + 1]) << 8 | UInt16(bytes[at])
    }

    func u32(_ offset: Int) -> UInt32? {
        guard let a = u16(offset), let b = u16(offset + 2) else { return nil }
        return bigEndian ? UInt32(a) << 16 | UInt32(b) : UInt32(b) << 16 | UInt32(a)
    }

    static func typeSize(_ type: UInt16) -> Int? {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9: return 4
        case 5, 10: return 8
        default: return nil
        }
    }

    /// The entries of the directory at `offset`. Empty for anything that does
    /// not hold together.
    func directory(at offset: Int) -> [UInt16: Entry] {
        guard offset > 0, let count = u16(offset) else { return [:] }
        let n = min(Int(count), Self.maxEntries)
        var out: [UInt16: Entry] = [:]
        for k in 0..<n {
            let at = offset + 2 + k * 12
            guard let tag = u16(at), let type = u16(at + 2), let rawCount = u32(at + 4),
                  let size = Self.typeSize(type)
            else { continue }
            let count = Int(rawCount)
            // A count that could not fit in any file is a lie, not a value.
            guard count > 0, count <= bytes.count else { continue }
            let total = size * count
            let valueOffset: Int
            if total <= 4 {
                valueOffset = at + 8
            } else {
                guard let pointer = u32(at + 8) else { continue }
                valueOffset = Int(pointer)
            }
            guard base + valueOffset + total <= bytes.count else { continue }
            out[tag] = Entry(tag: tag, type: type, count: count, valueOffset: valueOffset)
        }
        return out
    }

    func string(_ e: Entry?) -> String? {
        guard let e, e.type == 2 || e.type == 7 else { return nil }
        let start = base + e.valueOffset
        var slice = Array(bytes[start..<(start + e.count)])
        if let nul = slice.firstIndex(of: 0) { slice = Array(slice[..<nul]) }
        // EXIF says ASCII; cameras write Latin-1 and sometimes UTF-8. UTF-8
        // first, because it decodes ASCII unchanged and fails loudly on
        // Latin-1 — which is then read as what it most likely is.
        if let text = String(bytes: slice, encoding: .utf8) { return text }
        return String(bytes: slice, encoding: .isoLatin1)
    }

    func unsigned(_ e: Entry?) -> Int? {
        guard let e else { return nil }
        switch e.type {
        case 1, 7: return Int(bytes[base + e.valueOffset])
        case 3: return u16(e.valueOffset).map(Int.init)
        case 4: return u32(e.valueOffset).map(Int.init)
        default: return nil
        }
    }

    /// The `index`th rational of an entry, signed for SRATIONAL. Nil for a
    /// zero denominator, which cameras write for "unknown".
    func rational(_ e: Entry?, index: Int = 0) -> Double? {
        guard let e, e.type == 5 || e.type == 10, index < e.count,
              let n = u32(e.valueOffset + index * 8), let d = u32(e.valueOffset + index * 8 + 4)
        else { return nil }
        if e.type == 10 {
            let sn = Int32(bitPattern: n), sd = Int32(bitPattern: d)
            return sd == 0 ? nil : Double(sn) / Double(sd)
        }
        return d == 0 ? nil : Double(n) / Double(d)
    }

    /// Degrees from GPS's degrees, minutes, seconds.
    func coordinate(_ e: Entry?, ref: String?, negative: String) -> Double? {
        guard let degrees = rational(e, index: 0) else { return nil }
        let minutes = rational(e, index: 1) ?? 0
        let seconds = rational(e, index: 2) ?? 0
        let value = degrees + minutes / 60 + seconds / 3600
        return ref?.uppercased().hasPrefix(negative) == true ? -value : value
    }

    func photoInfo() -> PhotoInfo {
        var info = PhotoInfo()
        guard let first = u32(4) else { return info }
        let ifd0 = directory(at: Int(first))
        info.make = string(ifd0[0x010F])
        info.model = string(ifd0[0x0110])
        info.software = string(ifd0[0x0131])
        let modified = string(ifd0[0x0132])

        // Pointers are only followed forwards from what they could not be:
        // the directory they sit in. A file whose Exif pointer names IFD0
        // again is a loop with one step, and is simply read once.
        if let exifAt = unsigned(ifd0[0x8769]), exifAt != Int(first) {
            let exif = directory(at: exifAt)
            info.exposureTime = rational(exif[0x829A])
            info.fNumber = rational(exif[0x829D])
            info.iso = unsigned(exif[0x8827])
            info.taken = string(exif[0x9003])
            info.exposureBias = rational(exif[0x9204])
            info.flashFired = unsigned(exif[0x9209]).map { $0 & 1 == 1 }
            info.focalLength = rational(exif[0x920A])
            info.focalLength35 = unsigned(exif[0xA405])
            info.lens = string(exif[0xA434])
        }
        if PhotoInfo.formatDate(info.taken ?? "") == nil { info.taken = modified }

        if let gpsAt = unsigned(ifd0[0x8825]), gpsAt != Int(first) {
            let gps = directory(at: gpsAt)
            info.latitude = coordinate(gps[0x0002], ref: string(gps[0x0001]), negative: "S")
            info.longitude = coordinate(gps[0x0004], ref: string(gps[0x0003]), negative: "W")
            if let altitude = rational(gps[0x0006]) {
                // AltitudeRef: 1 is below sea level.
                info.altitude = unsigned(gps[0x0005]) == 1 ? -altitude : altitude
            }
        }
        return info
    }
}
