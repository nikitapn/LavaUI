import Foundation

public indirect enum JSONValue: Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    /// Keep the JSON token so rewriting a file cannot round numbers in unknown settings.
    case number(String)
    case bool(Bool)
    case null

    var object: [String: JSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }

    func formatted(depth: Int = 0) throws -> String {
        let indent = String(repeating: "  ", count: depth)
        let childIndent = indent + "  "
        switch self {
        case .object(let fields):
            guard !fields.isEmpty else { return "{}" }
            let lines = try fields.sorted { $0.key < $1.key }.map { key, value in
                try childIndent + JSONValue.string(key).formatted() + ": " + value.formatted(depth: depth + 1)
            }
            return "{\n" + lines.joined(separator: ",\n") + "\n" + indent + "}"
        case .array(let values):
            guard !values.isEmpty else { return "[]" }
            let lines = try values.map { try childIndent + $0.formatted(depth: depth + 1) }
            return "[\n" + lines.joined(separator: ",\n") + "\n" + indent + "]"
        case .string(let value):
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        case .number(let token): return token
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        }
    }
}

public struct SettingsLocation: Equatable, Sendable, CustomStringConvertible {
    public let file: URL
    public let line: Int
    public let column: Int

    public var description: String { "\(file.path):\(line):\(column)" }
}

public struct SettingsDocument: Sendable {
    public let value: JSONValue
    public let file: URL
    private let positions: [[String]: SettingsLocation]

    public func location(at path: [String]) -> SettingsLocation? { positions[path] }

    public static func parse(_ data: Data, at file: URL) throws -> Self {
        var parser = JSONParser(file: file, bytes: Array(data))
        let value = try parser.parse()
        return .init(value: value, file: file, positions: parser.positions)
    }

    static func read(at file: URL) throws -> Self? {
        do {
            return try parse(Data(contentsOf: file), at: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }
}

private struct JSONParser {
    let file: URL
    let bytes: [UInt8]
    var positions: [[String]: SettingsLocation] = [:]
    private var index = 0
    private var line = 1
    private var column = 1
    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }
    private var location: SettingsLocation { .init(file: file, line: line, column: column) }

    init(file: URL, bytes: [UInt8]) {
        self.file = file
        self.bytes = bytes
    }

    mutating func parse() throws -> JSONValue {
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { index = 3 }
        skipTrivia()
        guard current == 0x7b else { throw error("Expected a JSON object") }
        let result = try value(at: [])
        skipTrivia()
        guard current == nil else { throw error("Unexpected text after the settings object") }
        return result
    }

    private mutating func value(at path: [String]) throws -> JSONValue {
        skipTrivia()
        guard path.count < 128 else { throw error("JSON is nested too deeply") }
        positions[path] = location
        switch current ?? 0 {
        case 0x7b: return try object(at: path)
        case 0x5b: return try array(at: path)
        case 0x22: return .string(try string())
        case 0x74: try literal("true"); return .bool(true)
        case 0x66: try literal("false"); return .bool(false)
        case 0x6e: try literal("null"); return .null
        case 0x2d, 0x30...0x39: return .number(try number())
        default: throw error("Expected a JSON value")
        }
    }

    private mutating func object(at path: [String]) throws -> JSONValue {
        advance()
        skipTrivia()
        var fields: [String: JSONValue] = [:]
        while !consume(0x7d) {
            let keyLocation = location
            let key = try string()
            skipTrivia()
            guard consume(0x3a) else { throw error("Expected ':' after the key") }
            let childPath = path + [key]
            guard fields[key] == nil else {
                throw SettingsDiagnostic(severity: .error, location: keyLocation, message: "Duplicate key '\(key)'")
            }
            fields[key] = try value(at: childPath)
            positions[childPath] = keyLocation
            skipTrivia()
            if consume(0x7d) { break }
            guard consume(0x2c) else { throw error("Expected ',' or '}'") }
            skipTrivia()
        }
        return .object(fields)
    }

    private mutating func array(at path: [String]) throws -> JSONValue {
        advance()
        skipTrivia()
        var values: [JSONValue] = []
        while !consume(0x5d) {
            values.append(try value(at: path + [String(values.count)]))
            skipTrivia()
            if consume(0x5d) { break }
            guard consume(0x2c) else { throw error("Expected ',' or ']'") }
            skipTrivia()
        }
        return .array(values)
    }

    private mutating func string() throws -> String {
        let start = index
        let startLocation = location
        guard consume(0x22) else { throw error("Expected a quoted key") }
        while let byte = current {
            if consume(0x22) {
                do {
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                } catch {
                    throw SettingsDiagnostic(severity: .error, location: startLocation, message: "Invalid JSON string")
                }
            }
            guard byte >= 0x20 else { throw error("Unescaped control character in string") }
            advance()
            if byte == 0x5c {
                switch current ?? 0 {
                case 0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74:
                    advance()
                case 0x75:
                    advance()
                    for _ in 0..<4 {
                        switch current ?? 0 {
                        case 0x30...0x39, 0x41...0x46, 0x61...0x66: advance()
                        default: throw error("Expected four hexadecimal digits in Unicode escape")
                        }
                    }
                default: throw error("Invalid string escape")
                }
            }
        }
        throw error("Unterminated string")
    }

    private mutating func number() throws -> String {
        let start = index
        _ = consume(0x2d)
        if consume(0x30) {
            if isDigit { throw error("Leading zero in number") }
        } else {
            try digits()
        }
        if consume(0x2e) { try digits() }
        if consume(0x65) || consume(0x45) {
            if !consume(0x2b) { _ = consume(0x2d) }
            try digits()
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private var isDigit: Bool {
        guard let byte = current else { return false }
        return (0x30...0x39).contains(byte)
    }

    private mutating func digits() throws {
        guard isDigit else { throw error("Expected a digit") }
        while isDigit { advance() }
    }

    private mutating func literal(_ text: String) throws {
        for byte in text.utf8 {
            guard consume(byte) else { throw error("Expected '\(text)'") }
        }
    }

    private mutating func skipTrivia() {
        while let byte = current {
            switch byte {
            case 0x20, 0x09, 0x0a, 0x0d: advance()
            case 0x2f where index + 1 < bytes.count && bytes[index + 1] == 0x2f:
                while let byte = current, byte != 0x0a, byte != 0x0d { advance() }
            default: return
            }
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        advance()
        return true
    }

    private mutating func advance() {
        let byte = bytes[index]
        index += 1
        switch byte {
        case 0x0d:
            line += 1
            column = 1
        case 0x0a:
            if index < 2 || bytes[index - 2] != 0x0d { line += 1 }
            column = 1
        case 0x80...0xbf: break // UTF-8 continuation byte
        default: column += 1
        }
    }

    private func error(_ message: String) -> SettingsDiagnostic {
        .init(severity: .error, location: location, message: message)
    }
}
