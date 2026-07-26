/// A block-specific configuration value — e.g. `DELAY`'s `timeout`,
/// `COMPARATOR`'s operator, `FUNCTION`'s expression text. Kept as a small
/// closed enum rather than `Any`/`AnyHashable` so property values stay
/// easy to inspect, compare, and (later) serialize.
public enum PropertyValue: Hashable, Sendable {
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)
}

extension PropertyValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .string(let v): return v
        case .bool(let v): return v ? "true" : "false"
        }
    }
}
