import CLavaPDF
import Foundation

/// Why a PDF did not open.
public enum PDFOpenError: Error, Equatable, Sendable {
    /// Nothing at that path.
    case notFound
    /// Encrypted, and the password given — or none — did not open it.
    case locked
    /// Not a PDF, or damaged past what poppler repairs.
    case unreadable
}

/// A page's size in points, as it is meant to be seen: the crop box, turned
/// by the page's own rotation.
public struct PageSize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Pixels a render produced: `height` rows of `width` pixels, `stride` bytes
/// apart, in memory order B, G, R, A and opaque — `PixelFormat.bgrx8` to an
/// image host, which is what makes it uploadable without a conversion here.
public struct RenderedPixels: Sendable {
    public var bytes: [UInt8]
    public var width: Int
    public var height: Int
    public var stride: Int
}

/// An open PDF.
///
/// Every call takes the document's lock on the far side — poppler cannot
/// render two pages of one document at once — so a second thread waits rather
/// than corrupts. Parallel renders want a second `PDFDocument` on the same
/// file, which costs one more parse.
public final class PDFDocument: @unchecked Sendable {
    private let handle: OpaquePointer

    /// The file this was opened from.
    public let path: String
    /// Measured once at open. A viewer lays out every page before it has
    /// rendered any, and a size is the one thing it needs of all of them.
    public let pageSizes: [PageSize]
    /// What the document calls itself, if it says.
    public let title: String?

    public var pageCount: Int { pageSizes.count }

    /// Opens `path`, trying `password` if it is encrypted.
    public init(path: String, password: String? = nil) throws(PDFOpenError) {
        guard FileManager.default.fileExists(atPath: path) else { throw .notFound }
        var status = LAVA_PDF_OPEN_OK
        guard let handle = lava_pdf_open(path, password, &status) else {
            throw status == LAVA_PDF_OPEN_LOCKED ? .locked : .unreadable
        }
        self.handle = handle
        self.path = path

        let count = Int(lava_pdf_page_count(handle))
        var sizes: [PageSize] = []
        sizes.reserveCapacity(count)
        for page in 0..<count {
            var width = 0.0, height = 0.0
            // A page poppler cannot measure is laid out as US Letter rather
            // than at zero, which would stack every page after it on top.
            if lava_pdf_page_size(handle, Int32(page), &width, &height) == 0
                || width <= 0 || height <= 0
            {
                width = 612
                height = 792
            }
            sizes.append(PageSize(width: width, height: height))
        }
        pageSizes = sizes

        if let raw = lava_pdf_title(handle) {
            let text = String(cString: raw)
            lava_pdf_free_string(raw)
            title = text.isEmpty ? nil : text
        } else {
            title = nil
        }
    }

    deinit { lava_pdf_close(handle) }

    /// Renders a `width` × `height` window of `page` at `scale` pixels per
    /// point, whose top-left is (`x`, `y`) in the page's pixels at that scale.
    /// A window that runs off the page is paper past the edge. Nil if the page
    /// does not exist or poppler fails.
    ///
    /// Blocks for as long as the page takes — milliseconds for text, much
    /// longer for a dense drawing — so never on the frame loop.
    public func render(
        page: Int, scale: Double, x: Int, y: Int, width: Int, height: Int
    ) -> RenderedPixels? {
        guard page >= 0, page < pageCount, width > 0, height > 0, scale > 0
        else { return nil }
        let stride = width * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        let ok = bytes.withUnsafeMutableBufferPointer { buffer in
            lava_pdf_render(
                handle, Int32(page), scale, Int32(x), Int32(y),
                Int32(width), Int32(height), buffer.baseAddress, stride
            )
        }
        guard ok != 0 else { return nil }
        return RenderedPixels(bytes: bytes, width: width, height: height, stride: stride)
    }

    /// The table of contents, read once and kept by the caller. Empty for a
    /// document that has none, which is most short ones.
    public func outline() -> Outline {
        var count = 0
        guard let raw = lava_pdf_outline(handle, &count) else { return Outline(items: []) }
        defer { lava_pdf_free_outline(raw, count) }
        return Outline(items: UnsafeBufferPointer(start: raw, count: count).map { item in
            Outline.Item(
                title: item.title.map { Self.tidy(String(cString: $0)) } ?? "",
                depth: Int(item.depth),
                target: Self.target(item.target),
                startsOpen: item.open != 0
            )
        })
    }

    /// The links on `page`, in the order the page lists them.
    public func links(page: Int) -> [PageLink] {
        guard page >= 0, page < pageCount else { return [] }
        var count = 0
        guard let raw = lava_pdf_page_links(handle, Int32(page), &count) else { return [] }
        defer { lava_pdf_free_links(raw, count) }
        return UnsafeBufferPointer(start: raw, count: count).compactMap { link in
            guard let target = Self.target(link.target) else { return nil }
            return PageLink(
                box: Box(x: Double(link.x), y: Double(link.y),
                         width: Double(link.width), height: Double(link.height)),
                target: target
            )
        }
    }

    private static func target(_ raw: LavaPDFTarget) -> PDFTarget? {
        if let uri = raw.uri { return .uri(String(cString: uri)) }
        guard raw.page >= 0 else { return nil }
        return .page(
            Int(raw.page),
            x: raw.x.isNaN ? nil : Double(raw.x),
            y: raw.y.isNaN ? nil : Double(raw.y)
        )
    }

    /// Outline titles come out of LaTeX and word processors with line breaks
    /// and runs of spaces in them, which a one-line row cannot show.
    private static func tidy(_ title: String) -> String {
        title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The text on `page`, a box per character. Empty for a page that has
    /// none — a scan, or a page of drawings.
    public func text(page: Int) -> PageText {
        guard page >= 0, page < pageCount else { return PageText(characters: []) }
        var count = 0
        guard let raw = lava_pdf_page_text(handle, Int32(page), &count) else {
            return PageText(characters: [])
        }
        defer { lava_pdf_free_text(raw) }
        let characters = UnsafeBufferPointer(start: raw, count: count).map { c in
            PageCharacter(
                unit: c.unit,
                box: Box(
                    x: Double(c.x), y: Double(c.y),
                    width: Double(c.width), height: Double(c.height)
                ),
                endsWord: c.flags & UInt8(LAVA_PDF_CHAR_WORD_END) != 0,
                spaceAfter: c.flags & UInt8(LAVA_PDF_CHAR_SPACE_AFTER) != 0
            )
        }
        return PageText(characters: characters)
    }
}
