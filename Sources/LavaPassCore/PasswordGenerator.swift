public enum PasswordGenerator {
    /// Swift's system generator uses the operating system's secure random source.
    public static func generate(length: Int = 24, symbols: Bool = true) -> String {
        let groups = [Array("ABCDEFGHJKLMNPQRSTUVWXYZ"), Array("abcdefghijkmnopqrstuvwxyz"), Array("23456789")]
            + (symbols ? [Array("!@#$%^&*()-_=+[]{}:,.?")] : [])
        let count = max(groups.count, min(length, 256))
        let all = groups.flatMap { $0 }
        var generator = SystemRandomNumberGenerator()
        var result = groups.map { $0.randomElement(using: &generator)! }
        for _ in result.count..<count { result.append(all.randomElement(using: &generator)!) }
        result.shuffle(using: &generator)
        return String(result)
    }
}
