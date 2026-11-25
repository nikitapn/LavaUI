import Foundation

/// What a highlighted span *is* — `keyword`, `string`, `function.method` —
/// as a small integer a span can carry.
///
/// A span's `styleIndex` is one of these. Producers name what they found and
/// themes colour names; neither has to agree with the other on positions in
/// a list. The names are tree-sitter's highlight-query capture names, dotted
/// from general to specific, so a query's `@function.method` needs no table
/// of its own, and a theme that only colours `function` still colours it
/// (`CodeStyle` falls back along the dots).
///
/// The index of a name is fixed for the life of the process: the registry is
/// append-only, and safe to intern from any thread — a parse worker running a
/// highlight query interns the names it meets.
public enum HighlightName {
    /// Registered first, in this order, so their indices are the ones the
    /// lexer and every rule list have always used — 0 keyword … 7 property.
    public static let keyword = 0
    public static let string = 1
    public static let comment = 2
    public static let number = 3
    public static let type = 4
    public static let function = 5
    public static let parameter = 6
    public static let property = 7

    private static let first = [
        "keyword", "string", "comment", "number", "type", "function", "variable.parameter", "property",
    ]

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var names: [String] = []
        var indices: [String: Int] = [:]

        init() {
            for name in HighlightName.first { intern(name) }
        }

        @discardableResult
        func intern(_ name: String) -> Int {
            if let index = indices[name] { return index }
            indices[name] = names.count
            names.append(name)
            return names.count - 1
        }
    }

    private static let registry = Registry()

    /// The index for `name`, registering it the first time it is asked for.
    public static func index(of name: String) -> Int {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        return registry.intern(name)
    }

    /// The name an index stands for; nil for one never handed out — a rule
    /// list's own index, in a palette that is positional.
    public static func name(at index: Int) -> String? {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        return registry.names.indices.contains(index) ? registry.names[index] : nil
    }

    /// How many names are registered so far.
    public static var count: Int {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        return registry.names.count
    }

    /// `name`, then each shorter prefix of it: `function.method.call`,
    /// `function.method`, `function`. The order a theme is searched in.
    public static func fallbacks(of name: String) -> [Substring] {
        var result: [Substring] = [name[...]]
        var current = name[...]
        while let dot = current.lastIndex(of: ".") {
            current = current[..<dot]
            result.append(current)
        }
        return result
    }
}
