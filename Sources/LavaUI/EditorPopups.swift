/// What a code editor shows floating over its text: a hover card about a
/// symbol, and a completion list at the caret.
///
/// Both are drawn by the editor itself, inside its own box, after its text.
/// Not overlays, deliberately: an overlay takes the next click outside it to
/// close itself, and a card that appeared because the pointer rested on a
/// word must not eat the click that comes next. Typing stays with the editor
/// too — the list is steered through `EditorView(onKey:)`, and the app
/// decides what is in it.

/// One line of a hover card, already wrapped by the app.
public struct EditorCardLine: Equatable, Sendable {
    public var text: String
    /// A signature or a code sample — drawn in the text colour rather than
    /// the dimmer one prose takes.
    public var isCode: Bool

    public init(_ text: String, isCode: Bool = false) {
        self.text = text
        self.isCode = isCode
    }
}

/// Information about the text at `anchor`, shown just below it (or above,
/// when there is no room).
public struct EditorHoverCard: Equatable, Sendable {
    /// Character offsets of what the card is about.
    public var anchor: Range<Int>
    public var lines: [EditorCardLine]

    public init(anchor: Range<Int>, lines: [EditorCardLine]) {
        self.anchor = anchor
        self.lines = lines
    }
}

/// One entry of a completion list.
public struct EditorCompletionItem: Equatable, Sendable {
    public var label: String
    /// Shown dimmed after the label: a type, a signature.
    public var detail: String?
    /// One or two characters in front of the label saying what it is.
    public var kind: String?

    public init(label: String, detail: String? = nil, kind: String? = nil) {
        self.label = label
        self.detail = detail
        self.kind = kind
    }
}

/// Completions offered at `anchor`, the character offset where the word
/// being completed starts.
public struct EditorCompletionList: Equatable, Sendable {
    public var anchor: Int
    public var items: [EditorCompletionItem]
    public var selected: Int

    public init(anchor: Int, items: [EditorCompletionItem], selected: Int = 0) {
        self.anchor = anchor
        self.items = items
        self.selected = selected
    }

    /// How many rows are shown at once; the window follows the selection.
    public static let visibleRows = 10

    /// The first item shown, so that `selected` is always in view.
    public var firstVisible: Int {
        let count = items.count
        guard count > Self.visibleRows else { return 0 }
        return max(0, min(selected - Self.visibleRows / 2, count - Self.visibleRows))
    }
}

/// Where the popups' anchors landed on screen, collected while the rows are
/// drawn — the only time the editor knows where a character is.
struct EditorPopupAnchors {
    let hoverOffset: Int?
    let completionOffset: Int?
    var hover: (x: Float, top: Float, bottom: Float)?
    var completion: (x: Float, top: Float, bottom: Float)?

    init(hover: Int?, completion: Int?) {
        hoverOffset = hover
        completionOffset = completion
    }

    mutating func note(
        row: Range<Int>, top: Float, bottom: Float, x: (Int) -> Float
    ) {
        if hover == nil, let offset = hoverOffset, row.contains(offset) || offset == row.upperBound {
            hover = (x(offset - row.lowerBound), top, bottom)
        }
        if completion == nil, let offset = completionOffset,
           row.contains(offset) || offset == row.upperBound
        {
            completion = (x(offset - row.lowerBound), top, bottom)
        }
    }
}

/// The list's rows as drawn, in the editor box's own coordinates, for a
/// click to find the one it landed on.
struct EditorCompletionHit {
    var x: Float, y: Float, w: Float
    var rowHeight: Float
    var first: Int
    var count: Int

    func item(atLocalX localX: Float, localY: Float) -> Int? {
        guard localX >= x, localX < x + w, localY >= y else { return nil }
        let row = Int((localY - y) / rowHeight)
        return row < count ? first + row : nil
    }
}

extension DrawList {
    /// Draws whatever popups the editor has, over its text and inside its box.
    func emitEditorPopups(
        _ leaf: LeafNode, anchors: EditorPopupAnchors, font: UIFont, style: CodeStyle,
        x: Float, y: Float, w: Float, h: Float
    ) {
        leaf.completionHit = nil
        // The list is what the user is steering; a card under it would only
        // be in the way.
        if let list = leaf.completion, !list.items.isEmpty, let anchor = anchors.completion {
            emitCompletionList(leaf, list, anchor: anchor, font: font, style: style, x: x, y: y, w: w, h: h)
        } else if let card = leaf.hoverCard, !card.lines.isEmpty, let anchor = anchors.hover {
            emitHoverCard(card, anchor: anchor, theme: leaf.theme, font: font, style: style,
                          x: x, y: y, w: w, h: h)
        }
    }

    /// A box of `cardW`×`cardH` under the anchor's row, or above it when the
    /// editor has no room below; kept 4px inside the editor either way.
    private func popupOrigin(
        anchor: (x: Float, top: Float, bottom: Float), cardW: Float, cardH: Float,
        x: Float, y: Float, w: Float, h: Float
    ) -> (x: Float, y: Float) {
        let margin: Float = 4
        let below = anchor.bottom + 2
        let above = anchor.top - 2 - cardH
        let top = below + cardH <= y + h - margin || above < y + margin ? below : above
        let left = max(x + margin, min(anchor.x - 8, x + w - cardW - margin))
        return (left, max(y + margin, top))
    }

    private func emitPopupPlate(_ theme: Theme, x: Float, y: Float, w: Float, h: Float) {
        roundedRect(x: x - 1, y: y - 1, w: w + 2, h: h + 2, color: theme.border, radius: 7)
        roundedRect(x: x, y: y, w: w, h: h, color: theme.panel, radius: 6)
    }

    private func emitHoverCard(
        _ card: EditorHoverCard, anchor: (x: Float, top: Float, bottom: Float),
        theme: Theme, font: UIFont, style: CodeStyle, x: Float, y: Float, w: Float, h: Float
    ) {
        let pad: Float = 10
        let lineH = font.lineHeight
        let widest = card.lines.map { font.shapedRun($0.text).width }.max() ?? 0
        let cardW = min(w - 8, widest + pad * 2)
        let cardH = min(h - 8, Float(card.lines.count) * lineH + pad * 2)
        let origin = popupOrigin(anchor: anchor, cardW: cardW, cardH: cardH, x: x, y: y, w: w, h: h)
        emitPopupPlate(theme, x: origin.x, y: origin.y, w: cardW, h: cardH)
        pushClip(x: origin.x + pad, y: origin.y + pad, w: cardW - pad * 2, h: cardH - pad * 2)
        var lineY = origin.y + pad
        for line in card.lines {
            if lineY >= origin.y + cardH - pad { break }
            text(line.text, x: origin.x + pad - 4, y: lineY, w: 10_000, h: lineH,
                 color: line.isCode ? style.text : theme.textSecondary, font: font)
            lineY += lineH
        }
        popClip()
    }

    private func emitCompletionList(
        _ leaf: LeafNode, _ list: EditorCompletionList, anchor: (x: Float, top: Float, bottom: Float),
        font: UIFont, style: CodeStyle, x: Float, y: Float, w: Float, h: Float
    ) {
        let theme = leaf.theme
        let pad: Float = 4
        let rowH = (font.lineHeight * 0.85).rounded()
        let first = list.firstVisible
        let shown = Array(list.items[first..<min(list.items.count, first + EditorCompletionList.visibleRows)])
        let kindW: Float = 26
        let gap: Float = 14
        let labelW = shown.map { font.shapedRun($0.label).width }.max() ?? 0
        let detailW = shown.map { font.shapedRun($0.detail ?? "").width }.max() ?? 0
        // Capped: a generic's detail can be a paragraph, and a list that wide
        // covers the code being completed. The detail is what gets cut.
        let listW = min(w - 8, 560, max(220, kindW + labelW + (detailW > 0 ? gap + detailW : 0) + pad * 4))
        let listH = Float(shown.count) * rowH + pad * 2
        let origin = popupOrigin(anchor: anchor, cardW: listW, cardH: listH, x: x, y: y, w: w, h: h)
        emitPopupPlate(theme, x: origin.x, y: origin.y, w: listW, h: listH)

        pushClip(x: origin.x, y: origin.y, w: listW, h: listH)
        let textY = (rowH - font.lineHeight) / 2
        for (row, item) in shown.enumerated() {
            let rowY = origin.y + pad + Float(row) * rowH
            if first + row == list.selected {
                roundedRect(x: origin.x + pad, y: rowY, w: listW - pad * 2, h: rowH,
                            color: theme.selectionFill, radius: 4)
            }
            if let kind = item.kind {
                text(kind, x: origin.x + pad * 2 - 4, y: rowY + textY, w: kindW, h: font.lineHeight,
                     color: theme.accent, font: font)
            }
            let labelX = origin.x + pad * 2 + kindW
            text(item.label, x: labelX - 4, y: rowY + textY, w: 10_000, h: font.lineHeight,
                 color: style.text, font: font)
            if let detail = item.detail, !detail.isEmpty {
                let detailX = max(labelX + font.shapedRun(item.label).width + gap,
                                  origin.x + listW - pad * 2 - font.shapedRun(detail).width)
                text(detail, x: detailX - 4, y: rowY + textY, w: 10_000, h: font.lineHeight,
                     color: theme.textSecondary, font: font)
            }
        }
        popClip()
        leaf.completionHit = EditorCompletionHit(
            x: origin.x - x, y: origin.y + pad - y, w: listW, rowHeight: rowH,
            first: first, count: shown.count
        )
    }
}
