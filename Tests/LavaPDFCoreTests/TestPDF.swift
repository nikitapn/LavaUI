import Foundation

/// Writes small, valid PDFs for tests, so there is no binary fixture to keep.
///
/// One page per `Page`, each with its text in Helvetica (one of the fourteen
/// fonts every PDF reader must supply, so nothing is embedded), an optional
/// black square, which is what a render test looks for, and link
/// annotations. An outline and named destinations go on the document.
///
/// Coordinates are PDF's own: points from the page's *bottom*-left, before
/// any /Rotate. The tests convert, because the conversion is what they test.
enum TestPDF {
    enum Target {
        /// `/XYZ left top` on a page, from 0.
        case page(Int, top: Double)
        case uri(String)
        case named(String)
    }

    struct Page {
        var width: Double = 612
        var height: Double = 792
        /// The page's own /Rotate, in degrees.
        var rotate: Int = 0
        /// Lines of text, each at (x, y) from the bottom-left.
        var lines: [(x: Double, y: Double, size: Double, text: String)] = []
        /// A filled black square, (x, y) from the bottom-left.
        var square: (x: Double, y: Double, side: Double)?
        /// Link annotations: a rectangle from the bottom-left and where it goes.
        var links: [(x: Double, y: Double, width: Double, height: Double, target: Target)] = []
    }

    struct Entry {
        var title: String
        var depth: Int
        var target: Target
        /// /Count positive: the document asks for it to start open.
        var open = false
    }

    static func write(
        _ pages: [Page], title: String? = nil, outline: [Entry] = [],
        names: [String: (page: Int, top: Double)] = [:], to url: URL
    ) throws {
        try make(pages, title: title, outline: outline, names: names).write(to: url)
    }

    static func make(
        _ pages: [Page], title: String? = nil, outline: [Entry] = [],
        names: [String: (page: Int, top: Double)] = [:]
    ) -> Data {
        // 1: catalog, 2: page tree, 3: font, 4: info; then a page and its
        // contents per page; then the outline root and its entries.
        let firstPage = 5
        func pageRef(_ index: Int) -> String { "\(firstPage + 2 * index) 0 R" }
        func dest(_ page: Int, _ top: Double) -> String { "[\(pageRef(page)) /XYZ 50 \(top) 0]" }
        func action(_ target: Target) -> String {
            switch target {
            case .page(let page, let top): return "/Dest \(dest(page, top))"
            case .uri(let uri): return "/A << /S /URI /URI (\(uri)) >>"
            case .named(let name): return "/Dest (\(name))"
            }
        }

        let outlineRoot = firstPage + 2 * pages.count
        var objects: [String] = []
        let kids = pages.indices.map(pageRef).joined(separator: " ")
        var catalog = "<< /Type /Catalog /Pages 2 0 R"
        if !outline.isEmpty { catalog += " /Outlines \(outlineRoot) 0 R" }
        if !names.isEmpty {
            let pairs = names.keys.sorted().map { "(\($0)) \(dest(names[$0]!.page, names[$0]!.top))" }
            catalog += " /Names << /Dests << /Names [\(pairs.joined(separator: " "))] >> >>"
        }
        objects.append(catalog + " >>")
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
            let annots = page.links.map { link in
                "<< /Type /Annot /Subtype /Link /Border [0 0 0] "
                    + "/Rect [\(link.x) \(link.y) \(link.x + link.width) \(link.y + link.height)] "
                    + action(link.target) + " >>"
            }
            let content = firstPage + 2 * index + 1
            objects.append(
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(page.width) \(page.height)] "
                    + "/Rotate \(page.rotate) /Resources << /Font << /F1 3 0 R >> >> "
                    + (annots.isEmpty ? "" : "/Annots [\(annots.joined(separator: " "))] ")
                    + "/Contents \(content) 0 R >>"
            )
            objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream")
        }

        if !outline.isEmpty {
            // The tree from the depths: an entry's parent is the nearest
            // shallower one before it.
            let number = { (index: Int) in outlineRoot + 1 + index }
            var parent = [Int](repeating: -1, count: outline.count)
            var stack: [Int] = []
            for (index, entry) in outline.enumerated() {
                while let top = stack.last, outline[top].depth >= entry.depth { stack.removeLast() }
                parent[index] = stack.last ?? -1
                stack.append(index)
            }
            func children(_ of: Int) -> [Int] { outline.indices.filter { parent[$0] == of } }
            let roots = children(-1)
            objects.append(
                "<< /Type /Outlines /First \(number(roots.first!)) 0 R "
                    + "/Last \(number(roots.last!)) 0 R /Count \(roots.count) >>"
            )
            for (index, entry) in outline.enumerated() {
                let siblings = children(parent[index])
                let at = siblings.firstIndex(of: index)!
                let mine = children(index)
                var item = "<< /Title (\(entry.title)) /Parent "
                    + (parent[index] < 0 ? "\(outlineRoot)" : "\(number(parent[index]))") + " 0 R "
                if at > 0 { item += "/Prev \(number(siblings[at - 1])) 0 R " }
                if at + 1 < siblings.count { item += "/Next \(number(siblings[at + 1])) 0 R " }
                if !mine.isEmpty {
                    item += "/First \(number(mine.first!)) 0 R /Last \(number(mine.last!)) 0 R "
                    item += "/Count \(entry.open ? mine.count : -mine.count) "
                }
                objects.append(item + action(entry.target) + " >>")
            }
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
