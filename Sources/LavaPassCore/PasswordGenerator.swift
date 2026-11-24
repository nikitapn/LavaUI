import Foundation

public enum PasswordGenerator {
    public struct Characters: OptionSet, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let uppercase = Self(rawValue: 1 << 0)
        public static let lowercase = Self(rawValue: 1 << 1)
        public static let numbers = Self(rawValue: 1 << 2)
        public static let symbols = Self(rawValue: 1 << 3)
        public static let all: Self = [.uppercase, .lowercase, .numbers, .symbols]
    }

    /// Swift's system generator uses the operating system's secure random source.
    public static func generate(length: Int = 24, symbols: Bool = true) -> String {
        generate(length: length, characters: symbols ? .all : [.uppercase, .lowercase, .numbers])
    }

    public static func generate(length: Int, characters: Characters) -> String {
        let alphabets: [(Characters, String)] = [
            (.uppercase, "ABCDEFGHJKLMNPQRSTUVWXYZ"),
            (.lowercase, "abcdefghijkmnopqrstuvwxyz"),
            (.numbers, "23456789"),
            (.symbols, "!@#$%^&*()-_=+[]{}:,.?"),
        ]
        let groups = alphabets.filter { characters.contains($0.0) }.map { Array($0.1) }
        guard !groups.isEmpty else { return "" }
        let count = max(groups.count, min(length, 256))
        let all = groups.flatMap { $0 }
        var generator = SystemRandomNumberGenerator()
        var result = groups.map { $0.randomElement(using: &generator)! }
        for _ in result.count..<count { result.append(all.randomElement(using: &generator)!) }
        result.shuffle(using: &generator)
        return String(result)
    }
}

/// Length and character-class estimate for the vault's visual meter.
public enum PasswordStrength: Int, Sendable {
    case empty, weak, fair, strong, excellent

    public init(password: String) {
        guard !password.isEmpty else { self = .empty; return }
        let classes = [
            password.contains(where: \.isLowercase),
            password.contains(where: \.isUppercase),
            password.contains(where: \.isNumber),
            password.contains { !$0.isLetter && !$0.isNumber },
        ].filter { $0 }.count
        let score = Double(password.count) * log2([1, 26, 52, 62, 75][classes])
        self = switch score {
        case ..<40: .weak
        case ..<64: .fair
        case ..<90: .strong
        default: .excellent
        }
    }

    public var label: String {
        switch self {
        case .empty: "Empty"
        case .weak: "Weak"
        case .fair: "Fair"
        case .strong: "Strong"
        case .excellent: "Excellent"
        }
    }
}
