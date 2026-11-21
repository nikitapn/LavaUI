import CFontconfig
import Foundation

public enum FontStyle: String, CaseIterable, Sendable {
    case regular = "Regular"
    case italic = "Italic"
    case bold = "Bold"
    case boldItalic = "Bold Italic"

    var isItalic: Bool { self == .italic || self == .boldItalic }
    var isBold: Bool { self == .bold || self == .boldItalic }
    var weight: Int32 { isBold ? FC_WEIGHT_BOLD : FC_WEIGHT_REGULAR }
}

public enum FontCategory: String, CaseIterable, Sendable {
    case sans = "Sans"
    case serif = "Serif"
    case monospace = "Monospace"
}

public struct FontFace: Hashable, Sendable {
    public let path: String
    /// FreeType's face index, including the named instance for a variable font.
    public let index: UInt32

    package init(path: String, index: UInt32) {
        self.path = path
        self.index = index
    }
}

public struct FontFamily: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let category: FontCategory
    public var isMonospaced: Bool { category == .monospace }
    public let weightCount: Int
    public let availableStyles: Set<FontStyle>
    private let faces: [FontStyle: FontFace]

    /// The nearest face, preferring matching slant before matching weight.
    public func face(for style: FontStyle) -> FontFace? { faces[style] }

    fileprivate init(name: String, records: [FontPattern]) {
        self.name = name
        category = FontPattern.category(name: name, records: records)
        weightCount = Set(records.map(\.weight)).count
        availableStyles = Set(FontStyle.allCases.filter { style in
            records.contains {
                $0.isItalic == style.isItalic && ($0.weight >= FC_WEIGHT_DEMIBOLD) == style.isBold
            }
        })
        faces = Dictionary(uniqueKeysWithValues: FontStyle.allCases.compactMap { style in
            records.min {
                let lhs = ($0.isItalic != style.isItalic ? 1 : 0, abs(Int($0.weight) - Int(style.weight)),
                           $0.slant, $0.face.path, $0.face.index)
                let rhs = ($1.isItalic != style.isItalic ? 1 : 0, abs(Int($1.weight) - Int(style.weight)),
                           $1.slant, $1.face.path, $1.face.index)
                return lhs < rhs
            }.map { (style, $0.face) }
        })
    }
}

/// An installed-font snapshot. Matching uses only names on installed faces,
/// including localized family names from fontconfig, without substitutions.
public struct FontCatalog: Sendable {
    public let families: [FontFamily]
    public let enumerationSeconds: Double
    private let names: [String: Int]

    public func family(named name: String) -> FontFamily? {
        names[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()].map { families[$0] }
    }

    public func resolveFace(family: String, style: FontStyle) -> FontFace? {
        self.family(named: family)?.face(for: style)
    }

    public func resolve(family: String, style: FontStyle) -> String? {
        resolveFace(family: family, style: style)?.path
    }

    /// Starts enumeration on a worker without waiting for it.
    public static func prewarm() { _ = cache }

    /// For callers which already need a face synchronously, such as editor
    /// startup. Later calls reuse the same catalog for the process lifetime.
    public static var installed: FontCatalog { cache.result() }

    public static func load(_ completion: @escaping @Sendable (FontCatalog) -> Void) {
        let cache = cache
        cache.queue.async { completion(cache.result()) }
    }

    private static let cache = CatalogCache()

    init(patterns: [FontPattern], started: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let groups = Dictionary(grouping: patterns) { $0.names[0].lowercased() }
        let keys = groups.keys.sorted()
        families = keys.compactMap { key in
            guard let records = groups[key], let name = records.map({ $0.names[0] }).min()
            else { return nil }
            return FontFamily(name: name, records: records)
        }
        var names = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($0.element, $0.offset) })
        for (index, key) in keys.enumerated() {
            for alias in groups[key, default: []].flatMap(\.names) {
                let name = alias.lowercased()
                if names[name] == nil { names[name] = index }
            }
        }
        self.names = names
        enumerationSeconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
    }

    fileprivate static func enumerate() -> FontCatalog {
        let started = DispatchTime.now().uptimeNanoseconds
        guard let query = FcPatternCreate() else { return FontCatalog(patterns: [], started: started) }
        defer { FcPatternDestroy(query) }
        guard let fields = FcObjectSetCreate() else { return FontCatalog(patterns: [], started: started) }
        defer { FcObjectSetDestroy(fields) }
        for field in [FC_FAMILY, FC_FILE, FC_INDEX, FC_SPACING, FC_WEIGHT, FC_SLANT] {
            FcObjectSetAdd(fields, field)
        }
        guard let fonts = FcFontList(nil, query, fields) else {
            return FontCatalog(patterns: [], started: started)
        }
        defer { FcFontSetDestroy(fonts) }
        let patterns = (0..<Int(fonts.pointee.nfont)).compactMap { index in
            fonts.pointee.fonts[index].flatMap(FontPattern.init)
        }
        return FontCatalog(patterns: patterns, started: started)
    }
}

private final class CatalogCache: @unchecked Sendable {
    let queue = DispatchQueue(label: "LavaFontCore.catalog", qos: .userInitiated)
    private let ready = DispatchGroup()
    // Published once, before leaving the group.
    private var catalog: FontCatalog?

    init() {
        ready.enter()
        queue.async {
            self.catalog = FontCatalog.enumerate()
            self.ready.leave()
        }
    }

    func result() -> FontCatalog {
        ready.wait()
        return catalog!
    }
}

struct FontPattern {
    let names: [String]
    let face: FontFace
    let weight: Int32
    let slant: Int32
    let spacing: Int32?

    var isItalic: Bool { slant != FC_SLANT_ROMAN }

    init?(_ pattern: OpaquePointer) {
        func string(_ field: String, _ index: Int32 = 0) -> String? {
            var value: UnsafeMutablePointer<FcChar8>?
            guard FcPatternGetString(pattern, field, index, &value) == FcResultMatch,
                  let value else { return nil }
            return String(cString: value)
        }

        func integer(_ field: String) -> Int32? {
            var value: Int32 = 0
            return FcPatternGetInteger(pattern, field, 0, &value) == FcResultMatch ? value : nil
        }

        guard let path = string(FC_FILE), !path.isEmpty else { return nil }
        var names: [String] = []
        var index: Int32 = 0
        while let name = string(FC_FAMILY, index) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { names.append(trimmed) }
            index += 1
        }
        guard !names.isEmpty else { return nil }
        self.names = names
        face = FontFace(path: path, index: UInt32(bitPattern: integer(FC_INDEX) ?? 0))
        weight = integer(FC_WEIGHT) ?? FC_WEIGHT_REGULAR
        slant = integer(FC_SLANT) ?? FC_SLANT_ROMAN
        spacing = integer(FC_SPACING)
    }

    static func category(name: String, records: [Self]) -> FontCategory {
        let spacing = records.compactMap(\.spacing)
        let words = Set(name.lowercased().split { !$0.isLetter }.map(String.init))
        // Dual-width faces also fit a fixed grid. Some fonts, including
        // Noto Sans Mono, advertise fixed spacing only in their family name.
        if spacing.contains(where: { $0 == FC_MONO || $0 == FC_CHARCELL || $0 == FC_DUAL })
            || (spacing.isEmpty && (!words.isDisjoint(with: ["mono", "monospace"]))) {
            return .monospace
        }
        // Fontconfig has no reliable serif classification.
        // Honor an explicit Sans name, then recognize Serif and common serif
        // family names. Unrecognized proportional families go under Sans.
        let serifNames: Set = ["serif", "times", "garamond", "baskerville", "baskervville", "palatino",
                               "georgia", "cambria", "antiqua", "bookman", "schoolbook", "caslon",
                               "lora", "merriweather", "minion", "didot", "bodoni", "roman", "utopia"]
        return !words.contains("sans") && !words.isDisjoint(with: serifNames) ? .serif : .sans
    }
}
