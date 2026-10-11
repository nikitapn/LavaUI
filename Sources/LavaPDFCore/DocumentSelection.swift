/// A place in the document's text: a page, and a character on it.
///
/// `index` past the page's last character means the end of that page, which
/// is how "everything from here to the end" is said without reading the text
/// of every page in between to learn how long each one is.
public struct TextPosition: Comparable, Hashable, Sendable {
    public var page: Int
    public var index: Int

    public init(page: Int, index: Int) {
        self.page = page
        self.index = index
    }

    public static func < (a: TextPosition, b: TextPosition) -> Bool {
        (a.page, a.index) < (b.page, b.index)
    }

    /// The end of `page`, whatever its length.
    public static func end(of page: Int) -> TextPosition {
        TextPosition(page: page, index: .max)
    }
}

/// What a drag selected: from where it started to where it is now, across as
/// many pages as it crossed.
///
/// Kept as the two ends rather than a range per page, because the head moves
/// on every pointer event and every page between the two is wholly selected —
/// there is nothing to store about them. A page asks what of it is selected
/// with its own length, and only pages on screen or being copied ever ask.
public struct DocumentSelection: Equatable, Sendable {
    /// Where the drag started.
    public var anchor: TextPosition
    /// Where it is now. May be before the anchor: a drag goes either way.
    public var head: TextPosition

    public init(anchor: TextPosition, head: TextPosition) {
        self.anchor = anchor
        self.head = head
    }

    /// The whole document, in a form that needs no page's text to state.
    public static func all(pageCount: Int) -> DocumentSelection {
        DocumentSelection(
            anchor: TextPosition(page: 0, index: 0),
            head: .end(of: max(0, pageCount - 1))
        )
    }

    public var start: TextPosition { min(anchor, head) }
    public var end: TextPosition { max(anchor, head) }

    /// Every page with some of the selection on it.
    public var pages: ClosedRange<Int> { start.page...end.page }

    /// The characters selected on `page`, which has `count` of them. Nil when
    /// the page is outside the selection or has no text.
    public func range(onPage page: Int, count: Int) -> ClosedRange<Int>? {
        guard count > 0, pages.contains(page) else { return nil }
        let first = page == start.page ? min(start.index, count - 1) : 0
        let last = page == end.page ? min(end.index, count - 1) : count - 1
        return first <= last ? first...last : nil
    }
}

extension PageLayout {
    /// The page nearest a document y: the one containing it, or across a gap
    /// or past either end, the closest. For a drag that has left the pages —
    /// into a gap, or off the top of the first — which still means a page.
    public func nearestPage(toY y: Double) -> Int? {
        guard let first = frames.first, let last = frames.last else { return nil }
        if y < first.y { return 0 }
        if y >= last.maxY { return frames.count - 1 }
        // On a page, `pages` finds it. In a gap it finds nothing, and the
        // empty range starts at the page *after* the gap: then it is that page
        // or the one before, whichever edge is closer.
        let page = pages(intersecting: Box(x: 0, y: y, width: 1, height: 1)).lowerBound
        guard page < frames.count else { return frames.count - 1 }
        if y >= frames[page].y || page == 0 { return page }
        return y - frames[page - 1].maxY < frames[page].y - y ? page - 1 : page
    }
}
