import Foundation

/// The parts of a screenshot tool that are arithmetic rather than drawing.
///
/// Kept away from the engine for the reason `LavaViewCore` is: a rectangle
/// normalised the wrong way round, a filename that overwrites yesterday's shot,
/// or a label whose caret walks by bytes instead of characters are all bugs
/// you can write a test for, and all bugs that are miserable to find by taking
/// screenshots and looking at them.

// MARK: - Geometry

public struct ShotPoint: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

public struct ShotRect: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var w: Float
    public var h: Float

    public init(x: Float, y: Float, w: Float, h: Float) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    /// The rectangle between two corners, whichever way the drag went.
    ///
    /// A drag up and to the left is the ordinary way to select something above
    /// where you started, and it produces negative width — which every later
    /// step (the dim, the clip, the crop) reads as "empty" and silently drops.
    public static func between(_ a: ShotPoint, _ b: ShotPoint) -> ShotRect {
        ShotRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            w: abs(b.x - a.x), h: abs(b.y - a.y)
        )
    }

    public var isEmpty: Bool { w <= 0 || h <= 0 }
    public var maxX: Float { x + w }
    public var maxY: Float { y + h }

    public func contains(_ p: ShotPoint) -> Bool {
        p.x >= x && p.x <= maxX && p.y >= y && p.y <= maxY
    }

    /// Clamped inside `bounds`, keeping whatever part of it overlaps.
    ///
    /// A drag that leaves the screen is normal — people flick past the edge —
    /// and what they meant is the part that was on it.
    public func clamped(to bounds: ShotRect) -> ShotRect {
        let x0 = max(x, bounds.x)
        let y0 = max(y, bounds.y)
        let x1 = min(maxX, bounds.maxX)
        let y1 = min(maxY, bounds.maxY)
        if x1 <= x0 || y1 <= y0 { return ShotRect(x: x0, y: y0, w: 0, h: 0) }
        return ShotRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    /// Moved by a delta and pushed back inside `bounds` without changing size,
    /// which is what dragging a selection about means.
    public func moved(dx: Float, dy: Float, within bounds: ShotRect) -> ShotRect {
        var out = self
        out.x = min(max(x + dx, bounds.x), max(bounds.x, bounds.maxX - w))
        out.y = min(max(y + dy, bounds.y), max(bounds.y, bounds.maxY - h))
        return out
    }

    /// Rounded outwards to whole pixels. The selection is drawn in layout
    /// units and cropped in device ones; rounding in rather than out would
    /// shave a row off an edge somebody lined up deliberately.
    public var rounded: ShotRect {
        let x0 = x.rounded(.down)
        let y0 = y.rounded(.down)
        return ShotRect(
            x: x0, y: y0,
            w: (maxX.rounded(.up) - x0), h: (maxY.rounded(.up) - y0)
        )
    }

    /// The same rectangle in another coordinate system — layout units to
    /// framebuffer pixels, which differ on a scaled output.
    public func scaled(by factor: Float) -> ShotRect {
        ShotRect(x: x * factor, y: y * factor, w: w * factor, h: h * factor)
    }
}

// MARK: - Annotations

/// What the pointer draws.
public enum ShotTool: String, CaseIterable, Hashable, Sendable {
    /// Move and resize the selection rather than drawing on it.
    case select
    case rectangle
    case ellipse
    case arrow
    case pen
    case highlight
    /// A short label typed where it was clicked. The only tool with a mode:
    /// while one is being typed the keyboard belongs to it, and the letters
    /// that pick tools have to type instead.
    case text
    /// Redacts: the region is blurred hard enough that what was under it is
    /// not recoverable by looking. The one tool people reach for under time
    /// pressure, which is why it is not buried.
    case blur

    /// What the button says. One glyph, because a screenshot overlay covering
    /// somebody's screen is not the place for a row of words.
    public var glyph: String {
        switch self {
        case .select: return "⬚"
        case .rectangle: return "▭"
        case .ellipse: return "○"
        case .arrow: return "↗"
        case .pen: return "✎"
        case .highlight: return "▮"
        case .text: return "T"
        case .blur: return "▨"
        }
    }

    public var title: String {
        switch self {
        case .select: return "Select"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .arrow: return "Arrow"
        case .pen: return "Freehand"
        case .highlight: return "Highlight"
        case .text: return "Label"
        case .blur: return "Blur out"
        }
    }
}

public struct ShotColor: Equatable, Sendable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(r: Float, g: Float, b: Float, a: Float = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Red first: it is what an annotation is for, and what everybody reaches
    /// for. The rest are the ones that stay legible on a screenshot of a
    /// screen, which rules out most of a colour wheel.
    public static let palette: [ShotColor] = [
        ShotColor(r: 0.93, g: 0.23, b: 0.23),
        ShotColor(r: 0.99, g: 0.75, b: 0.18),
        ShotColor(r: 0.30, g: 0.78, b: 0.42),
        ShotColor(r: 0.28, g: 0.56, b: 0.96),
        ShotColor(r: 0.10, g: 0.10, b: 0.12),
        ShotColor(r: 1.00, g: 1.00, b: 1.00),
    ]
}

/// One thing somebody drew.
public struct ShotStroke: Equatable, Sendable {
    public var tool: ShotTool
    public var color: ShotColor
    public var width: Float
    /// Two points for a shape, many for the pen, one for a label.
    public var points: [ShotPoint]
    /// What a label says. Empty for every other tool.
    public var text: String

    public init(
        tool: ShotTool, color: ShotColor, width: Float, points: [ShotPoint],
        text: String = ""
    ) {
        self.tool = tool
        self.color = color
        self.width = width
        self.points = points
        self.text = text
    }

    public var start: ShotPoint { points.first ?? ShotPoint(x: 0, y: 0) }
    public var end: ShotPoint { points.last ?? start }
    public var bounds: ShotRect { ShotRect.between(start, end) }

    /// Whether it is worth keeping. A click that did not move is not a
    /// rectangle of zero size, it is somebody changing their mind.
    public var isMeaningful: Bool {
        switch tool {
        case .pen: return points.count > 1
        case .select: return false
        case .text:
            // A label somebody started and thought better of leaves nothing
            // behind — including one that is only spaces, which is invisible
            // and would still take an undo to get rid of.
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            let b = bounds
            return b.w >= 2 || b.h >= 2
        }
    }
}

/// The strokes, and the ability to take them back.
///
/// Undo is the whole point of an annotation tool: every mark is made in one
/// gesture, freehand, over somebody else's pixels, and the first one is rarely
/// where it was wanted.
public struct ShotDocument: Sendable {
    public private(set) var strokes: [ShotStroke] = []
    private var undone: [ShotStroke] = []

    public init() {}

    public var isEmpty: Bool { strokes.isEmpty }
    public var canUndo: Bool { !strokes.isEmpty }
    public var canRedo: Bool { !undone.isEmpty }

    public mutating func add(_ stroke: ShotStroke) {
        guard stroke.isMeaningful else { return }
        strokes.append(stroke)
        // A new mark ends the old future, the way it does in every editor.
        undone.removeAll()
    }

    public mutating func undo() {
        guard let last = strokes.popLast() else { return }
        undone.append(last)
    }

    public mutating func redo() {
        guard let next = undone.popLast() else { return }
        strokes.append(next)
    }
}

// MARK: - The toolbar

/// A button on the strip along the bottom.
///
/// Glyphs are from the blocks the interface font actually covers — geometric
/// shapes and arrows. The obvious characters for undo / copy / save
/// (U+293A ⤺, U+29C9 ⧉, U+2913 ⤓) are in neither OpenSans nor any fallback
/// here, and a toolbar of tofu boxes is worse than an approximate icon.
public enum ShotAction: Equatable, Hashable, Sendable {
    case tool(ShotTool)
    case color(Int)
    case thinner
    case thicker
    case undo
    case redo
    case copy
    case save
    case cancel

    public var glyph: String {
        switch self {
        case .tool(let tool): return tool.glyph
        case .color: return "■"
        case .thinner: return "─"
        case .thicker: return "━"
        case .undo: return "↺"
        case .redo: return "↻"
        case .copy: return "▤"
        case .save: return "↓"
        case .cancel: return "⨯"
        }
    }

    public var title: String {
        switch self {
        case .tool(let tool): return tool.title
        case .color: return "Colour"
        case .thinner: return "Thinner"
        case .thicker: return "Thicker"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .copy: return "Copy to clipboard"
        case .save: return "Save a file"
        case .cancel: return "Cancel"
        }
    }
}

// MARK: - Where a shot goes

public enum ShotOutput {
    /// Stroke widths offered, thinnest first. Discrete rather than a slider:
    /// the difference between 2 and 3 pixels does not matter and a slider on a
    /// floating toolbar is a thing to miss and drag by mistake.
    public static let widths: [Float] = [2, 4, 7, 12]

    /// `~/Pictures/Screenshots/Screenshot 2026-09-08 21-14-33.png`.
    ///
    /// Named by the second it was taken, because two shots in one session are
    /// the normal case and a name that collides silently overwrites the one
    /// somebody just took. Under `Screenshots/` rather than loose in
    /// `Pictures/`, for the same reason every other desktop does it.
    public static func defaultURL(now: Date = Date(), home: URL? = nil) -> URL {
        let base = home ?? URL(fileURLWithPath: NSHomeDirectory())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return base
            .appendingPathComponent("Pictures")
            .appendingPathComponent("Screenshots")
            .appendingPathComponent("Screenshot \(formatter.string(from: now)).png")
    }
}

// MARK: - Typing a label

/// A string being typed, and where the caret is in it.
///
/// Its own type rather than a `TextField`, because there is no field: a label
/// on a screenshot is text sitting on a picture, with no box, no scrolling and
/// nowhere to tab to. What it needs is what somebody typing two words actually
/// uses — the letters, backspace, the arrow keys — and none of what a text
/// editor needs.
///
/// The caret is an index into `characters`, not into UTF-8: an accented letter
/// is one thing to delete, however many bytes it takes to store, and getting
/// that wrong is how a backspace leaves a half-written character behind.
public struct ShotTextEdit: Equatable, Sendable {
    public private(set) var characters: [Character] = []
    /// Between 0 and `characters.count`; `count` means the end.
    public private(set) var caret: Int = 0

    public init(_ text: String = "") {
        characters = Array(text)
        caret = characters.count
    }

    public var text: String { String(characters) }
    public var isEmpty: Bool { characters.isEmpty }

    /// The text before the caret, which is what a renderer measures to find
    /// out where to draw it.
    public var beforeCaret: String { String(characters.prefix(caret)) }

    public mutating func insert(_ character: Character) {
        // A newline is the commit gesture, not a character: this is a label,
        // and a two-line label is a paragraph nobody asked for. Tabs are the
        // same kind of nothing.
        guard !character.isNewline, character != "\t" else { return }
        characters.insert(character, at: caret)
        caret += 1
    }

    public mutating func insert(_ string: String) {
        for character in string { insert(character) }
    }

    @discardableResult
    public mutating func backspace() -> Bool {
        guard caret > 0 else { return false }
        characters.remove(at: caret - 1)
        caret -= 1
        return true
    }

    @discardableResult
    public mutating func deleteForward() -> Bool {
        guard caret < characters.count else { return false }
        characters.remove(at: caret)
        return true
    }

    public mutating func moveLeft() { caret = max(0, caret - 1) }
    public mutating func moveRight() { caret = min(characters.count, caret + 1) }
    public mutating func moveToStart() { caret = 0 }
    public mutating func moveToEnd() { caret = characters.count }
}
