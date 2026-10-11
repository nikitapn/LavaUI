import Foundation

/// Writes small, valid PDFs for tests, so there is no binary fixture to keep.
///
/// One page per `Page`, each with its text in Helvetica (one of the fourteen
/// fonts every PDF reader must supply, so nothing is embedded) and an optional
/// black square, which is what a render test looks for.
enum TestPDF {
    struct Page {
        var width: Double = 612
        var height: Double = 792
        /// The page's own /Rotate, in degrees.
        var rotate: Int = 0
        /// Lines of text, each at (x, y) from the *bottom*-left, PDF style.
        var lines: [(x: Double, y: Double, size: Double, text: String)] = []
        /// A filled black square, (x, y) from the bottom-left.
        var square: (x: Double, y: Double, side: Double)?
    }

    static func write(_ pages: [Page], title: String? = nil, to url: URL) throws {
        try make(pages, title: title).write(to: url)
    }

    static func make(_ pages: [Page], title: String? = nil) -> Data {
        var objects: [String] = []
        // 1: catalog, 2: page tree, 3: font, 4: info; pages after.
        let firstPage = 5
        let kids = pages.indices.map { "\(firstPage + 2 * $0) 0 R" }.joined(separator: " ")
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append("<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>")
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        objects.append("<< /Title (\(title ?? "")) >>")
        for (index, page) in pages.enumerated() {
            var stream = ""
            if let square = page.square {
                stream += "0 0 0 rg \(square.x) \(square.y) \(square.side) \(square.side) re f\n"
            }
            for line in page.lines {
                let escaped = line.text
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "(", with: "\\(")
                    .replacingOccurrences(of: ")", with: "\\)")
                stream += "BT /F1 \(line.size) Tf \(line.x) \(line.y) Td (\(escaped)) Tj ET\n"
            }
            let content = firstPage + 2 * index + 1
            objects.append(
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(page.width) \(page.height)] "
                    + "/Rotate \(page.rotate) /Resources << /Font << /F1 3 0 R >> >> "
                    + "/Contents \(content) 0 R >>"
            )
            objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream")
        }

        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(index + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            out += String(format: "%010d 00000 n \n", offset)
        }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 4 0 R >>\n"
        out += "startxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }
}
