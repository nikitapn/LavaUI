import XCTest

@testable import LavaViewCore

/// Builds the bytes a camera would write, so the reader is tested against
/// headers rather than against itself: a TIFF block with IFD0, an Exif
/// directory and a GPS directory, in either byte order, and the JPEG or PNG
/// around it.
private struct ExifBuilder {
    enum Value {
        case ascii(String)
        case short(UInt16)
        case long(UInt32)
        case rationals([(UInt32, UInt32)])
        case srational(Int32, Int32)
        /// An offset to another directory, filled in when laid out.
        case pointer(Int)
    }

    var bigEndian = false
    var ifd0: [(UInt16, Value)] = []
    var exif: [(UInt16, Value)] = []
    var gps: [(UInt16, Value)] = []

    private func u16(_ v: UInt16) -> [UInt8] {
        bigEndian ? [UInt8(v >> 8), UInt8(v & 0xFF)] : [UInt8(v & 0xFF), UInt8(v >> 8)]
    }

    private func u32(_ v: UInt32) -> [UInt8] {
        let b = [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return bigEndian ? b : b.reversed()
    }

    /// Lays out the directories one after another, each followed by the
    /// values too big to sit in their entries.
    func tiff() -> [UInt8] {
        var directories = [ifd0]
        if !exif.isEmpty { directories.append(exif) }
        if !gps.isEmpty { directories.append(gps) }

        // Sizes first, so pointers to later directories are known.
        func valueBytes(_ value: Value, offsets: [Int]) -> (type: UInt16, count: UInt32, bytes: [UInt8]) {
            switch value {
            case .ascii(let s):
                let b = Array(s.utf8) + [0]
                return (2, UInt32(b.count), b)
            case .short(let v): return (3, 1, u16(v))
            case .long(let v): return (4, 1, u32(v))
            case .rationals(let list):
                return (5, UInt32(list.count), list.flatMap { u32($0.0) + u32($0.1) })
            case .srational(let n, let d):
                return (10, 1, u32(UInt32(bitPattern: n)) + u32(UInt32(bitPattern: d)))
            case .pointer(let which): return (4, 1, u32(UInt32(offsets[which])))
            }
        }
        func size(_ entries: [(UInt16, Value)]) -> Int {
            let extra = entries.reduce(0) { sum, entry in
                let b = valueBytes(entry.1, offsets: [0, 0, 0]).bytes.count
                return sum + (b > 4 ? b : 0)
            }
            return 2 + entries.count * 12 + 4 + extra
        }
        var offsets: [Int] = []
        var at = 8
        for d in directories {
            offsets.append(at)
            at += size(d)
        }

        var out: [UInt8] = bigEndian ? [0x4D, 0x4D] : [0x49, 0x49]
        out += u16(42) + u32(8)
        for (index, d) in directories.enumerated() {
            let start = offsets[index]
            var heap: [UInt8] = []
            let heapStart = start + 2 + d.count * 12 + 4
            var entries: [UInt8] = u16(UInt16(d.count))
            for (tag, value) in d {
                let v = valueBytes(value, offsets: offsets)
                entries += u16(tag) + u16(v.type) + u32(v.count)
                if v.bytes.count <= 4 {
                    entries += v.bytes + [UInt8](repeating: 0, count: 4 - v.bytes.count)
                } else {
                    entries += u32(UInt32(heapStart + heap.count))
                    heap += v.bytes
                }
            }
            out += entries + u32(0) + heap
        }
        return out
    }

    func jpeg() -> [UInt8] {
        let app0: [UInt8] = [0xFF, 0xE0, 0x00, 0x10] + Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0]
        let payload = Array("Exif".utf8) + [0, 0] + tiff()
        let length = payload.count + 2
        let app1: [UInt8] = [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
        return [0xFF, 0xD8] + app0 + app1 + [0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9]
    }

    func png() -> [UInt8] {
        func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
            let n = data.count
            return [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
                + Array(type.utf8) + data + [0, 0, 0, 0]  // CRC is not checked
        }
        return [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            + chunk("IHDR", [UInt8](repeating: 0, count: 13))
            + chunk("eXIf", tiff())
            + chunk("IEND", [])
    }

    /// A phone photograph: everything the panel shows.
    static func phone(bigEndian: Bool = false) -> ExifBuilder {
        var b = ExifBuilder()
        b.bigEndian = bigEndian
        b.ifd0 = [
            (0x010F, .ascii("Canon")),
            (0x0110, .ascii("Canon EOS 5D Mark II")),
            (0x0131, .ascii("Digital Photo Professional")),
            (0x0132, .ascii("2024:05:02 09:00:00")),
            (0x8769, .pointer(1)),
            (0x8825, .pointer(2)),
        ]
        b.exif = [
            (0x829A, .rationals([(1, 250)])),
            (0x829D, .rationals([(28, 10)])),
            (0x8827, .short(400)),
            (0x9003, .ascii("2024:05:01 12:34:56")),
            (0x9204, .srational(-2, 3)),
            (0x9209, .short(0x0019)),  // fired, auto
            (0x920A, .rationals([(50, 1)])),
            (0xA405, .short(75)),
            (0xA434, .ascii("EF50mm f/1.8 II")),
        ]
        b.gps = [
            (0x0001, .ascii("N")),
            (0x0002, .rationals([(48, 1), (51, 1), (3013, 100)])),
            (0x0003, .ascii("W")),
            (0x0004, .rationals([(2, 1), (17, 1), (4013, 100)])),
            (0x0005, .short(0)),  // AltitudeRef as a byte-sized short is fine
            (0x0006, .rationals([(35, 1)])),
        ]
        return b
    }
}

final class PhotoInfoReaderTests: XCTestCase {
    private func assertPhone(_ info: PhotoInfo?, file: StaticString = #filePath, line: UInt = #line) {
        guard let info else { return XCTFail("nothing read", file: file, line: line) }
        XCTAssertEqual(info.cameraName, "Canon EOS 5D Mark II", file: file, line: line)
        XCTAssertEqual(info.lens, "EF50mm f/1.8 II", file: file, line: line)
        XCTAssertEqual(info.exposureTime ?? 0, 1.0 / 250, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(info.fNumber ?? 0, 2.8, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(info.iso, 400, file: file, line: line)
        XCTAssertEqual(info.taken, "2024:05:01 12:34:56", file: file, line: line)
        XCTAssertEqual(info.exposureBias ?? 0, -2.0 / 3, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(info.flashFired, true, file: file, line: line)
        XCTAssertEqual(info.focalLength35, 75, file: file, line: line)
        XCTAssertEqual(info.latitude ?? 0, 48 + 51.0 / 60 + 30.13 / 3600, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(info.longitude ?? 0, -(2 + 17.0 / 60 + 40.13 / 3600), accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(info.altitude, 35, file: file, line: line)
    }

    func testAJpegInEitherByteOrder() {
        assertPhone(PhotoInfoReader.read(ExifBuilder.phone().jpeg()))
        assertPhone(PhotoInfoReader.read(ExifBuilder.phone(bigEndian: true).jpeg()))
    }

    func testAPngsExifChunk() {
        assertPhone(PhotoInfoReader.read(ExifBuilder.phone().png()))
    }

    func testABareTiffWhichIsWhatACameraRawIs() {
        assertPhone(PhotoInfoReader.read(ExifBuilder.phone(bigEndian: true).tiff()))
    }

    func testTheRowsReadTheWayACameraShowsThem() {
        let rows = PhotoInfoReader.read(ExifBuilder.phone().jpeg())?.rows ?? []
        let byLabel = Dictionary(rows.map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byLabel["Camera"], "Canon EOS 5D Mark II")
        XCTAssertEqual(byLabel["Exposure"], "1/250 s")
        XCTAssertEqual(byLabel["Aperture"], "f/2.8")
        XCTAssertEqual(byLabel["ISO"], "400")
        XCTAssertEqual(byLabel["Focal length"], "50 mm (75 mm equivalent)")
        XCTAssertEqual(byLabel["Exposure bias"], "−0.7 EV")
        XCTAssertEqual(byLabel["Flash"], "Fired")
        XCTAssertEqual(byLabel["Taken"], "2024-05-01 12:34:56")
        XCTAssertEqual(byLabel["Location"], "48.858369° N, 2.294481° W")
        XCTAssertEqual(byLabel["Altitude"], "35 m")
        XCTAssertEqual(rows.first?.label, "Camera", "what took it comes first")
    }

    func testNoExifIsNil() {
        XCTAssertNil(PhotoInfoReader.read([0xFF, 0xD8, 0xFF, 0xDA, 0, 2, 0xFF, 0xD9]))
        XCTAssertNil(PhotoInfoReader.read(Array("GIF89a".utf8)))
        XCTAssertNil(PhotoInfoReader.read([]))
    }

    /// The bytes are a stranger's. Every prefix of a real header — every place
    /// a file could have been cut off — must read as something or nothing,
    /// never as a crash.
    func testEveryTruncationIsSafe() {
        for bytes in [ExifBuilder.phone().jpeg(), ExifBuilder.phone(bigEndian: true).png()] {
            for n in 0...bytes.count {
                _ = PhotoInfoReader.read(Array(bytes.prefix(n)))
            }
        }
    }

    /// Offsets pointing anywhere at all, as a corrupt file's would.
    func testScrambledOffsetsAreSafe() {
        let clean = ExifBuilder.phone().tiff()
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            var bytes = clean
            for _ in 0..<4 {
                bytes[Int.random(in: 4..<bytes.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            _ = PhotoInfoReader.read(bytes)
        }
    }

    func testAnExifPointerBackToIfd0IsReadOnce() {
        var b = ExifBuilder()
        b.ifd0 = [(0x010F, .ascii("Canon")), (0x8769, .pointer(0))]
        XCTAssertEqual(PhotoInfoReader.read(b.tiff())?.make, "Canon")
    }
}

final class PhotoInfoFormattingTests: XCTestCase {
    func testCameraNameDoesNotRepeatTheMaker() {
        var info = PhotoInfo()
        info.make = "NIKON CORPORATION"
        info.model = "NIKON D750"
        XCTAssertEqual(info.cameraName, "NIKON D750")
        info.make = "SONY"
        info.model = "ILCE-7M3"
        XCTAssertEqual(info.cameraName, "Sony ILCE-7M3")
        info.make = "Apple\0\0  "
        info.model = "iPhone 13"
        XCTAssertEqual(info.cameraName, "Apple iPhone 13")
    }

    func testExposureTimes() {
        XCTAssertEqual(PhotoInfo.formatExposure(1.0 / 4000), "1/4000 s")
        XCTAssertEqual(PhotoInfo.formatExposure(0.5), "1/2 s")
        XCTAssertEqual(PhotoInfo.formatExposure(2.5), "2.5 s")
        XCTAssertEqual(PhotoInfo.formatExposure(30), "30 s")
        XCTAssertEqual(PhotoInfo.formatExposure(0.3), "0.3 s", "not a whole fraction")
        XCTAssertNil(PhotoInfo.formatExposure(0))
    }

    func testAnUnsetClockIsNoDate() {
        XCTAssertNil(PhotoInfo.formatDate("0000:00:00 00:00:00"))
        XCTAssertNil(PhotoInfo.formatDate("    :  :     :  :  "))
        XCTAssertEqual(PhotoInfo.formatDate("2020:01:02"), "2020-01-02")
        XCTAssertEqual(PhotoInfo.formatDate("whenever"), "whenever", "shown as written")
    }

    func testAGpsWithNoFixIsNoLocation() {
        var info = PhotoInfo()
        info.latitude = 0
        info.longitude = 0
        XCTAssertNil(info.location)
        info.latitude = 91
        info.longitude = 10
        XCTAssertNil(info.location)
    }

    func testFocalLengthWithoutAnEquivalent() {
        var info = PhotoInfo()
        info.focalLength = 35
        info.focalLength35 = 35
        XCTAssertEqual(info.focalDescription, "35 mm", "the same number twice says nothing")
        info.focalLength = 4.38
        info.focalLength35 = nil
        XCTAssertEqual(info.focalDescription, "4.4 mm")
    }
}
