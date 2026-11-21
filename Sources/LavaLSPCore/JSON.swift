import Foundation

public enum JSON: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let int = try? value.decode(Int.self) { self = .integer(int) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([JSON].self) { self = .array(array) }
        else { self = try .object(value.decode([String: JSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let bool): try value.encode(bool)
        case .integer(let int): try value.encode(int)
        case .number(let number): try value.encode(number)
        case .string(let string): try value.encode(string)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }

    public subscript(_ key: String) -> JSON? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public var string: String? {
        guard case .string(let string) = self else { return nil }
        return string
    }

    public var integer: Int? {
        guard case .integer(let int) = self else { return nil }
        return int
    }

    public var array: [JSON]? {
        guard case .array(let array) = self else { return nil }
        return array
    }

    public init<T: Encodable>(encoding value: T) throws {
        self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}
