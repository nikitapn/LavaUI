#if canImport(CxxCanvas)
import CxxCanvas
import Foundation

/// A shaped glyph, plus which face has to draw it.
///
/// `canvas.PositionedGlyph` carries no face, because it predates fallback: one
/// run meant one face and the emitter stamped the run's id onto every glyph.
/// With substitution a single run can mix faces, and glyph ids are
/// face-relative — shipping the id alone would draw the wrong glyph. Field
/// names deliberately mirror `PositionedGlyph` so everything doing caret and
/// advance arithmetic reads unchanged.
public struct ShapedGlyph: Equatable, Sendable {
    public var glyphId: UInt32
    /// Byte offset into the shaped string (HarfBuzz cluster), rebased onto the
    /// parent string when this glyph came from a substituted run.
    public var cluster: UInt32
    public var x: Float
    public var y: Float
    public var advance: Float
    /// Engine face id, as registered by `registerWithEngine`.
    public var fontId: UInt32

    init(_ glyph: canvas.PositionedGlyph, fontId: UInt32) {
        self.glyphId = glyph.glyphId
        self.cluster = glyph.cluster
        self.x = glyph.x
        self.y = glyph.y
        self.advance = glyph.advance
        self.fontId = fontId
    }
}

/// Visible bitmap bounds of a shaped run, relative to its baseline pen.
/// Unlike advance/line metrics, these exclude the font's invisible bearings.
struct TextInkBounds: Sendable {
    var minX: Float
    var minY: Float
    var maxX: Float
    var maxY: Float

    var width: Float { maxX - minX }
    var height: Float { maxY - minY }
}

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
    private var shapeCache: [String: [ShapedGlyph]] = [:]
    private var inkBoundsCache: [String: TextInkBounds] = [:]

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

    /// Prefer OpenSans, fall back to LiberationSerif.
    ///
    /// Looks under `assetsRoot/fonts/`, then legacy `assets/`, then the root
    /// itself — SPM packs defaults as `Resources/fonts` → bundle `fonts/`.
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
                paths.append(r.appendingPathComponent("fonts").appendingPathComponent(name))
                paths.append(r.appendingPathComponent("assets").appendingPathComponent("fonts").appendingPathComponent(name))
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

    /// A broad-coverage system face, for glyphs the packed ones lack.
    ///
    /// Deliberately the *last* tier and never the primary. Packed faces are
    /// what make text metrics identical on every machine — they feed Yoga, and
    /// layout that varies by host turns a rendering bug into one that
    /// reproduces on your box and not mine. This only ever adds glyphs that
    /// would otherwise be tofu, so a machine without any of these degrades to
    /// exactly the previous behaviour.
    ///
    /// Ordered by measured coverage of what this codebase actually draws:
    /// DejaVu has ~6000 glyphs including arrows, geometric shapes and ⚠;
    /// Liberation and Noto have progressively less.
    public static func loadSystemFallback(pixelSize: Float = 16) -> UIFont? {
        let roots = [
            "/usr/share/fonts",
            "/usr/local/share/fonts",
            "/usr/share/fonts/truetype",
        ]
        let names = [
            "DejaVuSans.ttf",
            "LiberationSans-Regular.ttf",
            "NotoSans-Regular.ttf",
            "FreeSans.ttf",
        ]
        // Exact paths first (cheap), then one bounded search per root for
        // distributions that nest differently.
        for root in roots {
            for name in names {
                for candidate in [
                    "\(root)/\(name)",
                    "\(root)/dejavu/\(name)",
                    "\(root)/liberation/\(name)",
                    "\(root)/noto/\(name)",
                    "\(root)/truetype/dejavu/\(name)",
                    "\(root)/truetype/liberation/\(name)",
                    "\(root)/TTF/\(name)",
                ] where FileManager.default.fileExists(atPath: candidate) {
                    if let font = UIFont(path: candidate, pixelSize: pixelSize) {
                        return font
                    }
                }
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
                root.appendingPathComponent("fonts").appendingPathComponent(name),
                root.appendingPathComponent("assets").appendingPathComponent("fonts").appendingPathComponent(name),
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

    /// Faces consulted, in order, for characters this one cannot draw.
    ///
    /// No single face is enough. The packed OpenSans is a Latin subset (883
    /// glyphs — no arrows, no geometric shapes, no ⚠), and even DejaVu at ~6000
    /// lacks U+23F8. Picking a "better" primary only moves the holes, so the
    /// fix has to be a chain. Set by `FontStore`; empty is fine and means the
    /// old behaviour.
    public internal(set) var fallbacks: [UIFont] = []

    /// Shaped run for one line, cached per string. Positions are relative to
    /// the run origin (pen at the baseline); the caller offsets them.
    ///
    /// Swift is now the only place text gets shaped: the same run feeds Yoga
    /// measurement and the draw list, so drawn output cannot drift from what
    /// was laid out — and the renderer never calls HarfBuzz.
    ///
    /// Characters this face lacks are re-shaped through `fallbacks` — see
    /// `shapeWithFallbacks`.
    public func shape(_ text: String) -> [ShapedGlyph] {
        if let hit = shapeCache[text] {
            PerfCounters.textShapeHits &+= 1
            return hit
        }
        PerfCounters.textShapes &+= 1
        let glyphs = shapeWithFallbacks(text)
        // Bounded, because this cache is keyed by line text and used to grow
        // without limit: every distinct line ever shaped stayed in it forever.
        // Scrolling a 166,636-line Android log put an entry per line here and
        // took the process past 9 GB. The live working set is the visible
        // window — tens of lines — so a cap in the low thousands never evicts
        // anything still on screen, and dropping the whole table beats
        // maintaining LRU metadata for an eviction that almost never fires.
        if shapeCache.count >= Self.shapeCacheLimit {
            shapeCache.removeAll(keepingCapacity: true)
        }
        shapeCache[text] = glyphs
        return glyphs
    }

    private static let shapeCacheLimit = 4096

    /// Raw shaping against this face alone. `glyphId == 0` is HarfBuzz's
    /// `.notdef` — the character is not in this face's cmap, and rendering it
    /// draws a tofu box.
    private func shapeDirect(_ text: String) -> [canvas.PositionedGlyph] {
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
        return glyphs
    }

    /// Shapes with this face, then re-shapes any `.notdef` stretch with the
    /// first fallback that can actually draw it.
    ///
    /// Substitution happens per *cluster range*, not per glyph: HarfBuzz's
    /// cluster is a byte offset into the source, so a failed run maps back to
    /// real substring boundaries. Re-shaping that substring separately is the
    /// same trade the word-wrapper already makes (`wrapLinesImpl` shapes each
    /// word alone) — no cross-run kerning, which does not exist across a
    /// script change anyway.
    ///
    /// The common case costs one extra scan of the glyph array and nothing
    /// else: text that shapes cleanly never touches the fallback path.
    private func shapeWithFallbacks(_ text: String) -> [ShapedGlyph] {
        let primary = shapeDirect(text)
        guard primary.contains(where: { $0.glyphId == 0 }) else {
            return primary.map { ShapedGlyph($0, fontId: engineId) }
        }

        let bytes = Array(text.utf8)
        var result: [ShapedGlyph] = []
        result.reserveCapacity(primary.count)

        // `Font::shape` reports `x` as pen position *plus* the GPOS offset, and
        // substitution changes every pen position after the first replaced
        // glyph. Only the offset survives a splice, so recover it here by
        // subtracting each glyph's own pen, and rebuild the pen at the end.
        // Skipping this draws the run on top of itself.
        var pens = [Float](repeating: 0, count: primary.count)
        var runningPen: Float = 0
        for k in primary.indices {
            pens[k] = runningPen
            runningPen += primary[k].advance
        }
        func kept(_ k: Int) -> ShapedGlyph {
            var glyph = ShapedGlyph(primary[k], fontId: engineId)
            glyph.x = primary[k].x - pens[k]
            return glyph
        }

        var index = 0
        while index < primary.count {
            guard primary[index].glyphId == 0 else {
                result.append(kept(index))
                index += 1
                continue
            }
            // Extend over the whole run of missing glyphs, so a word in an
            // unsupported script is handed to the fallback in one piece rather
            // than character by character.
            var end = index
            while end < primary.count, primary[end].glyphId == 0 { end += 1 }
            let lower = Int(primary[index].cluster)
            let upper = end < primary.count ? Int(primary[end].cluster) : bytes.count
            let piece = Self.substring(bytes, lower, upper)

            if let replacement = substitute(piece, base: lower), !replacement.isEmpty {
                result.append(contentsOf: replacement)
            } else {
                Self.reportMissingGlyphs(in: piece, face: self)
                // Keep the .notdef boxes: dropping them would silently shorten
                // the line and desync every caret offset after it.
                for k in index..<end { result.append(kept(k)) }
            }
            index = end
        }

        // Every `x` is now a bare GPOS offset; lay the runs out end to end.
        var penX: Float = 0
        for i in result.indices {
            result[i].x += penX
            penX += result[i].advance
        }
        return result
    }

    /// First fallback that draws `piece` in full.
    ///
    /// `base` is the piece's byte offset in the parent string. Clusters come
    /// back relative to `piece`, and every caret and hit-test in `ShapedRun`
    /// reads clusters as offsets into the *line* — so without rebasing, a
    /// single substituted glyph would send every click after it to the wrong
    /// character.
    private func substitute(_ piece: String, base: Int) -> [ShapedGlyph]? {
        guard !piece.isEmpty else { return nil }
        for face in fallbacks {
            let shaped = face.shapeDirect(piece)
            guard !shaped.isEmpty, !shaped.contains(where: { $0.glyphId == 0 }) else { continue }
            // GPOS offsets only, matching what the caller splices — the pen is
            // rebuilt across the whole line once every run is chosen.
            var pen: Float = 0
            return shaped.map { glyph in
                var out = ShapedGlyph(glyph, fontId: face.engineId)
                out.cluster = UInt32(base + Int(glyph.cluster))
                out.x = glyph.x - pen
                pen += glyph.advance
                return out
            }
        }
        return nil
    }

    private static func substring(_ bytes: [UInt8], _ lower: Int, _ upper: Int) -> String {
        let lo = max(0, min(lower, bytes.count))
        let hi = max(lo, min(upper, bytes.count))
        return String(decoding: bytes[lo..<hi], as: UTF8.self)
    }

    /// Loud in debug, because tofu is otherwise only ever found by eye. Two
    /// separate boxes shipped in this codebase before anyone noticed — an
    /// `Expand` chevron drawn on every open disclosure in every app, and a
    /// warning sign in an error banner.
    nonisolated(unsafe) private static var reportedMissing: Set<UInt32> = []

    private static func reportMissingGlyphs(in piece: String, face: UIFont) {
        guard missingGlyphWarnings else { return }
        for scalar in piece.unicodeScalars where reportedMissing.insert(scalar.value).inserted {
            let hex = String(format: "U+%04X", scalar.value)
            let name = (face.path as NSString).lastPathComponent
            let message = "LavaUI: no glyph for \(hex) '\(scalar)' in \(name) "
                + "or any fallback — it will draw as a tofu box\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }

    /// Set `LAVAUI_FONT_WARNINGS=0` to silence.
    nonisolated(unsafe) public static var missingGlyphWarnings =
        ProcessInfo.processInfo.environment["LAVAUI_FONT_WARNINGS"] != "0"

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
    public func clearShapeCache() {
        shapeCache.removeAll(keepingCapacity: true)
        inkBoundsCache.removeAll(keepingCapacity: true)
    }

    /// Bounds of the pixels a run actually draws, relative to the baseline.
    /// Used by compact icon buttons, where centering the typographic line box
    /// looks wrong because symbol fonts often have asymmetric blank space.
    func inkBounds(_ text: String) -> TextInkBounds? {
        if let cached = inkBoundsCache[text] { return cached }
        let run = shape(text)
        guard !run.isEmpty, run.allSatisfy({ $0.fontId == engineId }) else { return nil }

        var bounds: TextInkBounds?
        for glyph in run {
            let bitmap = raw.rasterize(glyph.glyphId)
            guard bitmap.width > 0, bitmap.height > 0 else { continue }
            let left = glyph.x + bitmap.bearingX
            let top = glyph.y - bitmap.bearingY
            let right = left + Float(bitmap.width)
            let bottom = top + Float(bitmap.height)
            if var current = bounds {
                current.minX = min(current.minX, left)
                current.minY = min(current.minY, top)
                current.maxX = max(current.maxX, right)
                current.maxY = max(current.maxY, bottom)
                bounds = current
            } else {
                bounds = TextInkBounds(minX: left, minY: top, maxX: right, maxY: bottom)
            }
        }
        if let bounds { inkBoundsCache[text] = bounds }
        return bounds
    }

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

    /// Adds an ellipsis while keeping the visible line within `availWidth`.
    /// Shaped widths are cached, so repeated layout of unchanged labels is
    /// cheap despite trimming by grapheme cluster.
    func ellipsized(_ text: String, availWidth: Float) -> String {
        let suffix = "…"
        guard shapedRun(text + suffix).width > availWidth else { return text + suffix }
        var candidate = text.trimmingCharacters(in: .whitespaces)
        while !candidate.isEmpty {
            candidate.removeLast()
            let result = candidate.trimmingCharacters(in: .whitespaces) + suffix
            if shapedRun(result).width <= availWidth { return result }
        }
        return suffix
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
    /// App-wide default face — UI thread only. `Environment.current.font`
    /// falls through to this wherever no `.font(_:)` override is in scope.
    nonisolated(unsafe) public static var `default`: UIFont?

    /// Symbol face for media / geometric glyphs (▶ ⏸ …). Prefer this over
    /// `default` for icon labels; OpenSans does not cover those codepoints.
    nonisolated(unsafe) public static var symbols: UIFont?

    /// Active discrete scale (library state).
    nonisolated(unsafe) public static var scale = ContentScale()

    /// Assets root last used by `bootstrap` / `apply` (needed to reload sizes).
    nonisolated(unsafe) public static var assetsRoot: String?

    /// Broad-coverage system face used as the last fallback tier, when the
    /// machine has one. Never the primary — see `loadSystemFallback`.
    nonisolated(unsafe) public static var system: UIFont?

    /// Bumped whenever the active face changes size, so the run loop knows the
    /// text measurements Yoga cached are stale.
    ///
    /// A counter rather than a callback because the fix has to work for *any*
    /// caller. Invalidating text metrics needs the `LayoutHost`, which only
    /// `LavaApp.run` has — so before this, the one key handler that knew to
    /// call `host.invalidateTextMetrics()` was the only place zoom worked
    /// correctly. A menu item, a button, or an agent script calling
    /// `zoomIn(into:)` changed the font and left the layout measured for the
    /// old one.
    nonisolated(unsafe) public private(set) static var metricsGeneration: UInt64 = 0

    /// Faces already loaded for this process, keyed by rounded pixel size.
    nonisolated(unsafe) private static var faceCache: [Int: UIFont] = [:]
    nonisolated(unsafe) private static var symbolsCache: [Int: UIFont] = [:]
    nonisolated(unsafe) private static var systemCache: [Int: UIFont] = [:]

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

        // Broad-coverage system face, if the machine has one.
        if let cached = systemCache[key] {
            system = cached
        } else if let loaded = UIFont.loadSystemFallback(pixelSize: px) {
            systemCache[key] = loaded
            system = loaded
        }
        if let editor, let system {
            system.registerWithEngine(editor)
        }

        guard let font else { return nil }

        if let editor {
            font.registerWithEngine(editor)
        }

        // Order matters: the symbol face is curated for the icons this
        // codebase draws, the system face is the broad net behind it. Both
        // must already be registered — a fallback glyph carries its own face
        // id into the draw list, and an unregistered face has id 0.
        font.fallbacks = [symbols, system].compactMap { $0 }
        `default` = font
        // Old size's shape cache dies with the old UIFont when unreferenced;
        // shared measure cache keys include font identity — clear to free RAM.
        TextLayoutCache.shared.clear()
        metricsGeneration &+= 1
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
