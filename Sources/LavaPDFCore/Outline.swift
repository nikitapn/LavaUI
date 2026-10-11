import Foundation

/// Where an outline entry or a link goes.
public enum PDFTarget: Equatable, Sendable {
    /// A place in this document: a page, and a point on it in points from
    /// its top-left when the target says. A destination on a turned page
    /// carries no point — see `resolve` in the bridge.
    case page(Int, x: Double?, y: Double?)
    /// Somewhere else entirely: a web page, a mail address.
    case uri(String)
}

/// One link on a page: where to click, in the page's points from its top-left.
public struct PageLink: Equatable, Sendable {
    public var box: Box
    public var target: PDFTarget

    public init(box: Box, target: PDFTarget) {
        self.box = box
        self.target = target
    }
}

extension Array where Element == PageLink {
    /// The link under a point, or nil. The last one wins where two overlap,
    /// because annotations are drawn in order and the last is on top.
    public func link(atX x: Double, y: Double) -> PageLink? {
        last { $0.box.contains(x: x, y: y) }
    }
}

/// The document's table of contents, as a sidebar shows it.
///
/// Flat, in reading order, each entry with its depth — which is both how the
/// bridge hands it over and how a list draws it. What is a tree about it is
/// answered from the depths: an entry's children are the entries after it
/// that are deeper, up to the first that is not.
public struct Outline: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var title: String
        public var depth: Int
        public var target: PDFTarget?
        /// Whether the document asks for this entry to start expanded.
        public var startsOpen: Bool

        public init(title: String, depth: Int, target: PDFTarget?, startsOpen: Bool = false) {
            self.title = title
            self.depth = depth
            self.target = target
            self.startsOpen = startsOpen
        }
    }

    public let items: [Item]

    public init(items: [Item]) { self.items = items }

    public var isEmpty: Bool { items.isEmpty }

    /// Whether entry `index` has children to show or hide.
    public func hasChildren(_ index: Int) -> Bool {
        index + 1 < items.count && items[index + 1].depth > items[index].depth
    }

    /// The entries a reader starts with expanded: the ones the document asks
    /// for, and — when it asks for none and the outline is short — the top
    /// level, so a ten-chapter book does not open as ten closed triangles.
    public var initiallyExpanded: Set<Int> {
        let asked = Set(items.indices.filter { items[$0].startsOpen && hasChildren($0) })
        if !asked.isEmpty || items.count > 40 { return asked }
        return Set(items.indices.filter { items[$0].depth == 0 && hasChildren($0) })
    }

    /// The rows on show when `expanded` are open: every top-level entry, and
    /// beneath an open one its children, recursively.
    public func visible(expanded: Set<Int>) -> [Int] {
        var rows: [Int] = []
        var hiddenBelow: Int?
        for (index, item) in items.enumerated() {
            if let depth = hiddenBelow {
                if item.depth > depth { continue }
                hiddenBelow = nil
            }
            rows.append(index)
            if hasChildren(index), !expanded.contains(index) { hiddenBelow = item.depth }
        }
        return rows
    }

    /// The entries that contain `index`, outermost first: what has to be
    /// open for it to be on show.
    public func ancestors(of index: Int) -> [Int] {
        guard items.indices.contains(index) else { return [] }
        var result: [Int] = []
        var depth = items[index].depth
        var cursor = index - 1
        while cursor >= 0, depth > 0 {
            if items[cursor].depth < depth {
                result.append(cursor)
                depth = items[cursor].depth
            }
            cursor -= 1
        }
        return result.reversed()
    }

    /// The section a reader is in at `page`, `y` points down it: the last
    /// entry, in reading order, whose target is at or before that place.
    ///
    /// Outlines are almost always in page order, but not required to be, so
    /// this takes the furthest-along target that has not been passed rather
    /// than the last item before the first one that has.
    public func current(page: Int, y: Double) -> Int? {
        var best: (index: Int, page: Int, y: Double)?
        for (index, item) in items.enumerated() {
            guard case .page(let targetPage, _, let targetY)? = item.target else { continue }
            let top = targetY ?? 0
            guard targetPage < page || (targetPage == page && top <= y + 1) else { continue }
            if let known = best, (known.page, known.y) > (targetPage, top) { continue }
            best = (index, targetPage, top)
        }
        return best?.index
    }
}
