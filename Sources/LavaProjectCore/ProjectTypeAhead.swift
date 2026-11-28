import Foundation

/// Jumping to a row by typing the start of its name, as file trees and
/// file managers do.
///
/// Letters typed within `pause` of each other build one prefix — "rea"
/// finds README.md — and the search starts at the selected row, so a
/// longer prefix that still fits stays where it is. A run of one letter
/// pressed again and again ("ttt") steps through the rows starting with it
/// instead, which is what someone means who presses T three times.
public struct ProjectTypeAhead: Sendable {
    /// Seconds without a key after which typing starts a new prefix.
    public static let pause: Double = 1.0

    public private(set) var typed = ""
    private var lastAt = -Double.infinity

    public init() {}

    /// Adds `character`, typed at `now` (seconds, any monotonic clock), and
    /// returns the path of the row to select — nil when nothing matches.
    public mutating func type(
        _ character: Character, at now: Double, from selected: String?, in rows: [ProjectRow]
    ) -> String? {
        if now - lastAt > Self.pause { typed = "" }
        lastAt = now
        typed += character.lowercased()
        guard !rows.isEmpty else { return nil }

        let current = rows.firstIndex { $0.node.path == selected }
        let repeated = typed.count > 1 && Set(typed).count == 1
        let prefix = repeated ? String(typed.prefix(1)) : typed
        // A fresh letter, or the same letter again, looks past the current
        // row; a growing prefix starts on it.
        let skipCurrent = typed.count == 1 || repeated
        let start = current.map { skipCurrent ? $0 + 1 : $0 } ?? 0
        for step in 0..<rows.count {
            let row = rows[(start + step) % rows.count]
            if row.node.name.lowercased().hasPrefix(prefix) { return row.node.path }
        }
        return nil
    }

    /// Forgets the prefix: the selection moved some other way.
    public mutating func reset() {
        typed = ""
        lastAt = -.infinity
    }
}
