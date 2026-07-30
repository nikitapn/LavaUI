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
        loadFirstExisting(
            pixelSize: pixelSize,
            relativeTo: assetsRoot,
            names: ["OpenSans-Regular.ttf", "LiberationSerif-Regular.ttf"]
        )
    }

    /// Symbol / icon face for media glyphs (▶ ⏸ etc.).
    ///
    /// Prefers **Noto Sans Symbols 2** (has Geometric Shapes + media controls).
    /// Plain "Noto Sans Symbols" does *not* include U+25B6 / U+23F8 — that is
    /// why the second file is required for play/pause.
    public static func loadSymbols(assetsRoot: String?, pixelSize: Float = 16) -> UIFont? {
        var paths: [String] = []
        if let root = assetsRoot {
            let r = root as NSString
            for name in [
                "NotoSansSymbols2-Regular.ttf",
                "NotoSansSymbols-Regular.ttf",
            ] {
                paths.append(r.appendingPathComponent("assets").appendingPathComponent(name))
                paths.append(r.appendingPathComponent(name))
            }
        }
        // System Noto (Arch/Fedora/Debian paths).
        paths += [
            "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf",
            "/usr/share/fonts/noto/NotoSansSymbols-Regular.ttf",
            "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf",
            "/usr/share/fonts/truetype/noto/NotoSansSymbols-Regular.ttf",
        ]
        for p in paths {
            if FileManager.default.fileExists(atPath: p),
               let font = UIFont(path: p, pixelSize: pixelSize)
            {
                return font
            }
        }
        return nil
    }

    private static func loadFirstExisting(
        pixelSize: Float,
        relativeTo assetsRoot: String,
        names: [String]
    ) -> UIFont? {
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

// MARK: - Discrete content scale (library-facing)

/// Discrete UI text scale — bitmap fonts re-raster at fixed pixel sizes so
/// Yoga measure and FreeType glyphs stay pixel-aligned (no GPU scale of
/// atlas coverage).
///
/// Intended as a reusable policy object for a future declarative-UI package:
/// apps bind shortcuts to `zoomIn` / `zoomOut`; layout hosts re-run after
/// `FontStore.apply`.
public struct ContentScale: Equatable, Sendable {
    /// Multipliers of the bootstrap base size (e.g. 16 → 12…32).
    public static let defaultMultipliers: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    public let multipliers: [Float]
    /// Index into `multipliers` (clamped).
    public private(set) var index: Int
    /// Face size at multiplier 1.0.
    public let basePixelSize: Float

    public init(
        basePixelSize: Float = 16,
        multipliers: [Float] = ContentScale.defaultMultipliers,
        index: Int? = nil
    ) {
        self.basePixelSize = max(1, basePixelSize)
        let m = multipliers.isEmpty ? ContentScale.defaultMultipliers : multipliers
        self.multipliers = m
        if let index {
            self.index = min(max(0, index), m.count - 1)
        } else {
            // Prefer exact 1.0 step when present.
            self.index = m.firstIndex(where: { abs($0 - 1) < 0.001 }) ?? (m.count / 2)
        }
    }

    public var multiplier: Float { multipliers[index] }

    /// Integer FT pixel size for the active step (min 1).
    public var pixelSize: Float {
        max(1, (basePixelSize * multiplier).rounded())
    }

    public var canZoomIn: Bool { index < multipliers.count - 1 }
    public var canZoomOut: Bool { index > 0 }

    @discardableResult
    public mutating func zoomIn() -> Bool {
        guard canZoomIn else { return false }
        index += 1
        return true
    }

    @discardableResult
    public mutating func zoomOut() -> Bool {
        guard canZoomOut else { return false }
        index -= 1
        return true
    }

    @discardableResult
    public mutating func reset() -> Bool {
        let one = multipliers.firstIndex(where: { abs($0 - 1) < 0.001 }) ?? 0
        guard index != one else { return false }
        index = one
        return true
    }
}

/// Default UI font when `Text` does not specify one.
///
/// **Swift owns font policy** (face + discrete pixel size). The same
/// `(path, pixelSize)` is registered with the engine so measure and draw
/// share one FreeType face. C++ never picks a default.
///
/// Scale changes re-load/register a face, clear layout caches, and require
/// the app to re-`setRoot` + Yoga (library: call `apply` then dirty layout).
public enum FontStore {
    /// Global default — UI thread only. Used by `Text` when `font == nil`.
    nonisolated(unsafe) public static var `default`: UIFont?

    /// Symbol face for media / geometric glyphs (▶ ⏸ …). Prefer this over
    /// `default` for icon labels; OpenSans does not cover those codepoints.
    nonisolated(unsafe) public static var symbols: UIFont?

    /// Active discrete scale (library state).
    nonisolated(unsafe) public static var scale = ContentScale()

    /// Assets root last used by `bootstrap` / `apply` (needed to reload sizes).
    nonisolated(unsafe) public static var assetsRoot: String?

    /// Faces already loaded for this process, keyed by rounded pixel size.
    nonisolated(unsafe) private static var faceCache: [Int: UIFont] = [:]
    nonisolated(unsafe) private static var symbolsCache: [Int: UIFont] = [:]

    /// Back-compat alias.
    nonisolated(unsafe) public static var ui: UIFont? {
        get { `default` }
        set { `default` = newValue }
    }

    /// Load default + symbols faces under `assetsRoot` and register with the engine.
    @discardableResult
    public static func bootstrap(
        assetsRoot: String,
        pixelSize: Float = 16,
        into editor: Editor? = nil
    ) -> UIFont? {
        self.assetsRoot = assetsRoot
        scale = ContentScale(basePixelSize: pixelSize)
        return apply(scale: scale, into: editor)
    }

    /// Install `scale`'s pixel size as `FontStore.default`, register with the
    /// engine, and drop measure/shape caches that referenced the old size.
    /// Also reloads `symbols` at the same pixel size.
    /// Returns the new default face, or nil on load failure (keeps previous).
    @discardableResult
    public static func apply(scale newScale: ContentScale, into editor: Editor?) -> UIFont? {
        scale = newScale
        let px = newScale.pixelSize
        let key = Int(px.rounded())

        let font: UIFont?
        if let cached = faceCache[key] {
            font = cached
        } else if let root = assetsRoot, let loaded = UIFont.loadUI(assetsRoot: root, pixelSize: px) {
            faceCache[key] = loaded
            font = loaded
        } else if let path = `default`?.path, let loaded = UIFont(path: path, pixelSize: px) {
            faceCache[key] = loaded
            font = loaded
        } else {
            font = nil
        }

        // Symbols face (Noto Sans Symbols 2 preferred) — independent of UI success.
        if let cached = symbolsCache[key] {
            symbols = cached
        } else if let loaded = UIFont.loadSymbols(assetsRoot: assetsRoot, pixelSize: px) {
            symbolsCache[key] = loaded
            symbols = loaded
        } else if let path = symbols?.path, let loaded = UIFont(path: path, pixelSize: px) {
            symbolsCache[key] = loaded
            symbols = loaded
        }

        if let editor, let symbols {
            symbols.registerWithEngine(editor)
        }

        guard let font else { return nil }

        if let editor {
            font.registerWithEngine(editor)
        }
        `default` = font
        // Old size's shape cache dies with the old UIFont when unreferenced;
        // shared measure cache keys include font identity — clear to free RAM.
        TextLayoutCache.shared.clear()
        return font
    }

    /// Step up one discrete size. `true` if the scale (and face) changed.
    @discardableResult
    public static func zoomIn(into editor: Editor?) -> Bool {
        var s = scale
        guard s.zoomIn() else { return false }
        return apply(scale: s, into: editor) != nil
    }

    /// Step down one discrete size. `true` if the scale (and face) changed.
    @discardableResult
    public static func zoomOut(into editor: Editor?) -> Bool {
        var s = scale
        guard s.zoomOut() else { return false }
        return apply(scale: s, into: editor) != nil
    }

    /// Return to multiplier 1.0. `true` if the scale (and face) changed.
    @discardableResult
    public static func resetScale(into editor: Editor?) -> Bool {
        var s = scale
        guard s.reset() else { return false }
        return apply(scale: s, into: editor) != nil
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
