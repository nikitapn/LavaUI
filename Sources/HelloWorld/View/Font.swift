#if canImport(CxxCanvas)
import CxxCanvas
import Foundation

/// Swift-facing typeface handle. Wraps `canvas::Font` (FreeType + HarfBuzz).
/// Identity for cache keys is `(path, pixelSize)` — not the C++ object.
public final class UIFont: @unchecked Sendable {
    public let path: String
    public let pixelSize: Float
    public let identity: String

    /// Move-only C++ font; only touched on the UI thread.
    private var raw: canvas.Font

    public private(set) var lineHeight: Float = 16
    public private(set) var ascent: Float = 12
    public private(set) var descent: Float = 4

    /// Id of this face in the engine's font registry. Stamped into every
    /// `GlyphInstance` so the renderer resolves face-relative glyph ids
    /// against the face they were actually shaped with.
    public internal(set) var engineId: UInt32 = 0

    /// Shaped runs keyed by line text. Shaping is the expensive part of text,
    /// so this is what keeps re-emission cheap.
    private var shapeCache: [String: [canvas.PositionedGlyph]] = [:]

    public init?(path: String, pixelSize: Float = 16) {
        self.path = path
        self.pixelSize = pixelSize
        self.identity = "\(path)@\(pixelSize)"
        var f = canvas.Font()
        let ok = f.load(std.string(path), pixelSize).has_value()
        guard ok, f.isLoaded() else { return nil }
        self.raw = f
        // Probe metrics via empty measure.
        let m = self.raw.measure(std.string(""))
        self.lineHeight = m.height > 0 ? m.height : pixelSize * 1.2
        self.ascent = m.ascent
        self.descent = m.descent
    }

    /// Prefer OpenSans, fall back to LiberationSerif (matches Application assetPath).
    public static func loadUI(assetsRoot: String, pixelSize: Float = 16) -> UIFont? {
        let names = ["OpenSans-Regular.ttf", "LiberationSerif-Regular.ttf"]
        let root = assetsRoot as NSString
        for name in names {
            let candidates = [
                root.appendingPathComponent("assets").appendingPathComponent(name),
                root.appendingPathComponent(name),
            ]
            for p in candidates {
                if FileManager.default.fileExists(atPath: p),
                   let font = UIFont(path: p, pixelSize: pixelSize)
                {
                    return font
                }
            }
        }
        return nil
    }

    public func measure(_ text: String) -> (width: Float, height: Float) {
        let m = raw.measure(std.string(text))
        return (m.width, m.height)
    }

    /// `mode`: 0=Undefined, 1=Exactly, 2=AtMost (YGMeasureMode).
    public func measure(_ text: String, availWidth: Float, mode: Int) -> (width: Float, height: Float) {
        let m = raw.measure(std.string(text), availWidth, Int32(mode))
        return (m.width, m.height)
    }

    /// Shaped run for one line, cached per string. Positions are relative to
    /// the run origin (pen at the baseline); the caller offsets them.
    ///
    /// Swift is now the only place text gets shaped: the same run feeds Yoga
    /// measurement and the draw list, so drawn output cannot drift from what
    /// was laid out — and the renderer never calls HarfBuzz.
    public func shape(_ text: String) -> [canvas.PositionedGlyph] {
        if let hit = shapeCache[text] { return hit }
        let n = Int(raw.prepareShape(std.string(text)))
        var glyphs = [canvas.PositionedGlyph](
            repeating: canvas.PositionedGlyph(), count: max(n, 0)
        )
        if n > 0 {
            let written = glyphs.withUnsafeMutableBufferPointer {
                Int(raw.copyShapedGlyphs($0.baseAddress, Int32(n)))
            }
            if written < n { glyphs.removeLast(n - written) }
        }
        shapeCache[text] = glyphs
        return glyphs
    }

    /// Registers this face with the engine and records the returned id.
    /// Must happen before any glyph from this face reaches the draw list —
    /// otherwise the renderer resolves its ids against the wrong face.
    @discardableResult
    public func registerWithEngine(_ editor: Editor) -> Bool {
        guard let id = editor.registerFont(path: path, pixelSize: pixelSize) else {
            FileHandle.standardError.write(
                Data("UIFont: engine registerFont failed for \(path)\n".utf8)
            )
            return false
        }
        engineId = id
        return true
    }

    /// Drops cached shaped runs. Call if the cache grows unbounded; entries
    /// are keyed by string only, since a `UIFont` is one face at one size.
    public func clearShapeCache() { shapeCache.removeAll(keepingCapacity: true) }

    /// Lines matching `measure(..., AtMost/Exactly)` wrap breaks.
    public func wrapLines(_ text: String, availWidth: Float) -> [String] {
        let n = Int(raw.prepareWrap(std.string(text), availWidth))
        var lines: [String] = []
        lines.reserveCapacity(max(n, 1))
        var buf = [CChar](repeating: 0, count: 1024)
        for i in 0..<n {
            if raw.wrapLineAt(Int32(i), &buf, Int32(buf.count)) {
                let len = buf.firstIndex(of: 0) ?? buf.endIndex
                let bytes = buf[..<len].map { UInt8(bitPattern: $0) }
                lines.append(String(decoding: bytes, as: UTF8.self))
            }
        }
        if lines.isEmpty { lines = [""] }
        return lines
    }
}

/// Default UI font when `Text` does not specify one.
///
/// **Swift owns font policy** (which face/size). After loading for measure/
/// Yoga, the same path is pushed to C++ via `Editor.loadFont` so draw-list
/// `TextRenderer` paints with matching metrics. C++ never picks a default.
public enum FontStore {
    /// Global default — UI thread only. Used by `Text` when `font == nil`.
    nonisolated(unsafe) public static var `default`: UIFont?

    /// Back-compat alias.
    nonisolated(unsafe) public static var ui: UIFont? {
        get { `default` }
        set { `default` = newValue }
    }

    /// Load default face under `assetsRoot` and install on the engine for draw.
    @discardableResult
    public static func bootstrap(
        assetsRoot: String,
        pixelSize: Float = 16,
        into editor: Editor? = nil
    ) -> UIFont? {
        if let existing = `default` {
            // Still push to engine if we re-open a window. registerFont is
            // idempotent per (path, size), so this returns the same id.
            if let editor {
                existing.registerWithEngine(editor)
            }
            return existing
        }
        guard let font = UIFont.loadUI(assetsRoot: assetsRoot, pixelSize: pixelSize) else {
            return nil
        }
        `default` = font
        if let editor {
            font.registerWithEngine(editor)
        }
        return font
    }
}

// MARK: - Shape / metrics cache

/// Keyed on (text, font, quantized width, mode). Yoga measure is chatty;
/// this is the main Phase 4 perf lever.
public final class TextLayoutCache: @unchecked Sendable {
    public static let shared = TextLayoutCache()

    public struct Key: Hashable {
        var text: String
        var fontId: String
        /// availWidth snapped to 0.5px (or -1 for undefined).
        var widthQ: Int
        var mode: Int
    }

    public struct Entry {
        public var width: Float
        public var height: Float
        public var lines: [String]
    }

    private var map: [Key: Entry] = [:]
    public private(set) var hits: Int = 0
    public private(set) var misses: Int = 0

    public func resetStats() {
        hits = 0
        misses = 0
    }

    public func clear() {
        map.removeAll(keepingCapacity: true)
        resetStats()
    }

    public var hitRate: Double {
        let t = hits + misses
        return t == 0 ? 1 : Double(hits) / Double(t)
    }

    public func layout(
        font: UIFont,
        text: String,
        availWidth: Float,
        mode: Int
    ) -> Entry {
        let wq: Int
        if mode == 0 {
            wq = -1
        } else {
            wq = Int((availWidth * 2).rounded())
        }
        let key = Key(text: text, fontId: font.identity, widthQ: wq, mode: mode)
        if let e = map[key] {
            hits += 1
            return e
        }
        misses += 1

        let metrics = font.measure(text, availWidth: availWidth, mode: mode)
        let lines: [String]
        if mode == 0 || text.isEmpty {
            lines = text.isEmpty ? [""] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            // measure(undefined) is single-line shaping; explicit \n still multiplies height via wrap.
            if mode == 0 && text.contains("\n") {
                // measure() single-arg ignores \n for width; use AtMost huge width for lines.
                let wrapped = font.wrapLines(text, availWidth: 1e6)
                let entry = Entry(
                    width: metrics.width,
                    height: font.lineHeight * Float(max(wrapped.count, 1)),
                    lines: wrapped
                )
                map[key] = entry
                return entry
            }
        } else {
            lines = font.wrapLines(text, availWidth: availWidth)
        }

        let entry = Entry(width: metrics.width, height: metrics.height, lines: lines)
        map[key] = entry
        return entry
    }
}

#endif
