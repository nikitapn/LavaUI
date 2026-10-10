import Foundation
import Testing

@testable import LavaExplorerCore

@Suite struct ThumbnailCacheTests {
    @Test func md5MatchesTheReferenceVectors() {
        #expect(MD5.hex(of: []) == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(MD5.hex(of: Array("abc".utf8)) == "900150983cd24fb0d6963f7d28e17f72")
        #expect(MD5.hex(of: Array(String(repeating: "a", count: 1000).utf8))
                == "cabe45dcc9ae5b66ba86600cca6b8ba8", "more than one block")
        // The standard's own example.
        #expect(MD5.hex(of: Array("file:///home/jens/photos/me.png".utf8))
                == "c6ee772d9e49320e97ec29a7eb5b1697")
    }

    @Test func aURIIsEscapedTheWayGLibEscapesIt() {
        // GLib.filename_to_uri, run on this machine, for both paths.
        #expect(ThumbnailCache.uri(forPath: "/tmp/a b/ä!$&()*+,=@~#?%[].png")
                == "file:///tmp/a%20b/%C3%A4!$&()*+,=@~%23%3F%25%5B%5D.png")
        let printable = String((33..<127).map { Character(UnicodeScalar($0)) }.filter { $0 != "/" })
        #expect(ThumbnailCache.uri(forPath: "/" + printable)
                == "file:///!%22%23$%25&'()*+,-.0123456789:%3B%3C=%3E%3F@ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                + "%5B%5C%5D%5E_%60abcdefghijklmnopqrstuvwxyz%7B%7C%7D~")
    }

    @Test func theCacheLayoutIsTheStandards() {
        #expect(ThumbnailCache.path(for: "/home/jens/photos/me.png", size: .normal, root: "/c")
                == "/c/normal/c6ee772d9e49320e97ec29a7eb5b1697.png")
        #expect(ThumbnailCache.path(for: "/home/jens/photos/me.png", size: .large, root: "/c")
                == "/c/large/c6ee772d9e49320e97ec29a7eb5b1697.png")
        #expect(ThumbnailCache.failurePath(for: "/home/jens/photos/me.png", root: "/c")
                == "/c/fail/lava-explorer/c6ee772d9e49320e97ec29a7eb5b1697.png")
    }

    @Test func textChunksGoInAndComeBackOut() {
        #expect(CRC32.of(Array("IEND".utf8)) == 0xAE42_6082)
        let png = minimalPNG()
        let tagged = PNGText.insert(["Thumb::URI": "file:///x.png", "Thumb::MTime": "12.000003"], into: png)
        #expect(PNGText.read(tagged) == ["Thumb::URI": "file:///x.png", "Thumb::MTime": "12.000003"])
        #expect(PNGText.read(png).isEmpty)
        #expect(PNGText.size(of: png)! == (1, 1))
        #expect(PNGText.size(of: tagged)! == (1, 1), "text chunks go after IHDR, so the size stays put")
        #expect(PNGText.size(of: Array("not a png at all, really".utf8)) == nil)
        #expect(PNGText.read(Array("not a png".utf8)).isEmpty)
        // A chunk claiming more bytes than there are stops the walk.
        var truncated = tagged
        truncated.removeLast(20)
        _ = PNGText.read(truncated)
    }

    @Test func aRecordedTimeMatchesEitherWayItIsWritten() {
        let stamp = ThumbnailCache.Stamp(seconds: 1_769_514_874, microseconds: 472_564)
        #expect(stamp.text == "1769514874.472564")
        #expect(stamp.matches("1769514874.472564"), "GNOME's form")
        #expect(stamp.matches("1769514874"), "the standard's form: seconds only")
        #expect(!stamp.matches("1769514874.000000"))
        #expect(!stamp.matches("1769514875"))
        #expect(!stamp.matches("garbage"))
        #expect(ThumbnailCache.Stamp(seconds: 5, microseconds: 7).text == "5.000007")
    }

    @Test func aWrittenThumbnailIsValidUntilTheFileChanges() throws {
        let root = NSTemporaryDirectory() + "lava-thumbs-" + UUID().uuidString.prefix(8)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let picture = root + "/pics/a b.png"
        try FileManager.default.createDirectory(atPath: root + "/pics", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: picture, contents: Data(minimalPNG()))
        let stamp = try #require(ThumbnailCache.Stamp(ofFileAt: picture))

        let thumbnail = ThumbnailCache.path(for: picture, size: .normal, root: root + "/cache")
        try ThumbnailCache.write(png: minimalPNG(), to: thumbnail, of: picture, stamp: stamp)
        #expect(ThumbnailCache.isValid(thumbnail: thumbnail, of: picture, stamp: stamp))
        let mode = try FileManager.default.attributesOfItem(atPath: thumbnail)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        let later = ThumbnailCache.Stamp(seconds: stamp.seconds + 1, microseconds: 0)
        #expect(!ThumbnailCache.isValid(thumbnail: thumbnail, of: picture, stamp: later))
        #expect(!ThumbnailCache.isValid(thumbnail: thumbnail, of: root + "/other.png", stamp: stamp))
        #expect(!ThumbnailCache.isValid(thumbnail: root + "/missing.png", of: picture, stamp: stamp))
    }

    @Test func onlyPicturesOutsideTheCacheAreThumbnailed() {
        #expect(ThumbnailCache.wants(FileEntry(path: "/a/IMG.JPG", isDirectory: false, size: 10), root: "/c"))
        #expect(!ThumbnailCache.wants(FileEntry(path: "/a/notes.txt", isDirectory: false, size: 10), root: "/c"))
        #expect(!ThumbnailCache.wants(FileEntry(path: "/a/pics.png", isDirectory: true), root: "/c"))
        #expect(!ThumbnailCache.wants(FileEntry(path: "/c/normal/x.png", isDirectory: false, size: 10), root: "/c"))
        #expect(!ThumbnailCache.wants(
            FileEntry(path: "/a/huge.png", isDirectory: false, size: ThumbnailCache.maxFileBytes + 1), root: "/c"
        ))
        // SVG is drawn from the file, never thumbnailed.
        let svg = FileEntry(path: "/a/logo.SVG", isDirectory: false, size: 10)
        #expect(!ThumbnailCache.wants(svg, root: "/c"))
        #expect(ThumbnailCache.drawsItself(svg))
        #expect(!ThumbnailCache.drawsItself(FileEntry(path: "/a/x.png", isDirectory: false, size: 10)))
    }

    /// Signature, IHDR (1×1 RGBA) and IEND — enough to carry chunks; no
    /// image data, since nothing here decodes it.
    private func minimalPNG() -> [UInt8] {
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typed = Array(type.utf8) + body
            let n = UInt32(body.count)
            let crc = CRC32.of(typed)
            return [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
                + typed
                + [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
        }
        return [137, 80, 78, 71, 13, 10, 26, 10]
            + chunk("IHDR", [0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0])
            + chunk("IEND", [])
    }
}
