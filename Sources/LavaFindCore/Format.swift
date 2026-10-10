import Foundation

// What LavaFind says about a file, as text: the badge, the folder, the size
// and the date on each row, the highlighted part of the name, and the footer's
// list of where it is looking. All of it is a function of a hit and a clock,
// so none of it needs a window to be checked.

public enum FindFormat {
    /// "2.4 MB", "412 MB", "120 KB". One decimal under ten, where it is the
    /// difference between two files; none above, where it is noise.
    public static func size(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        // Rounded first, so 9.96 MB reads "10 MB" rather than "10.0 MB".
        let tenths = (value * 10).rounded() / 10
        if tenths < 10 { return String(format: "%.1f %@", tenths, units[unit]) }
        return String(format: "%.0f %@", value.rounded(), units[unit])
    }

    /// "Oct 2" this year, "Oct 2, 2024" any other. The day is enough to
    /// recognise a file by; the time of day is not what anybody remembers.
    public static func date(
        _ seconds: Int64, now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        guard seconds > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let sameYear = calendar.component(.year, from: date)
            == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }

    /// The row's right-hand column: "2.4 MB · Oct 2". A folder has no size
    /// worth showing — the index does not add up what is inside one.
    public static func detail(
        size bytes: UInt64, mtime: Int64, isDirectory: Bool, now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let when = date(mtime, now: now, calendar: calendar)
        if isDirectory { return when }
        return when.isEmpty ? size(bytes) : "\(size(bytes)) · \(when)"
    }

    /// The badge on the left of a row: "PDF", "MP4", "DIR". Four characters
    /// at most, so the column stays one width; "FILE" when there is no
    /// extension to show.
    public static func badge(ext: String, isDirectory: Bool) -> String {
        if isDirectory { return "DIR" }
        if ext.isEmpty { return "FILE" }
        return String(ext.uppercased().prefix(4))
    }

    /// `path` with the home directory written as `~`.
    public static func tilde(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The file's name, and the folder it is in as the row's second line.
    public static func split(_ path: String, home: String) -> (name: String, folder: String) {
        guard path != "/", let slash = path.lastIndex(of: "/") else { return (path, "") }
        let name = String(path[path.index(after: slash)...])
        let folder = slash == path.startIndex ? "/" : String(path[..<slash])
        return (name.isEmpty ? path : name, tilde(folder, home: home))
    }

    /// `name` cut at the daemon's match, for drawing the middle part in the
    /// accent colour. The range is in UTF-8 bytes, which is what the index
    /// counts in; one that does not land on character boundaries — or does
    /// not fit — comes back as no highlight rather than as a broken string.
    public static func highlight(
        _ name: String, start: UInt32, length: UInt32
    ) -> (before: String, match: String, after: String) {
        guard length > 0 else { return (name, "", "") }
        let utf8 = Array(name.utf8)
        let a = Int(start), b = Int(start) + Int(length)
        guard b <= utf8.count,
              let before = String(validating: utf8[0..<a], as: UTF8.self),
              let match = String(validating: utf8[a..<b], as: UTF8.self),
              let after = String(validating: utf8[b...], as: UTF8.self)
        else { return (name, "", "") }
        return (before, match, after)
    }

    /// The footer's "where": "~ (Documents, Downloads, Pictures)", and any
    /// root outside home by its own path. The order is the config's.
    public static func roots(_ paths: [String], home: String) -> String {
        var inHome: [String] = []
        var elsewhere: [String] = []
        for path in paths {
            let short = tilde(path, home: home)
            if short == "~" {
                inHome.insert("~", at: 0)
            } else if short.hasPrefix("~/") {
                inHome.append(String(short.dropFirst(2)))
            } else {
                elsewhere.append(path)
            }
        }
        var parts: [String] = []
        if inHome.first == "~" {
            parts.append("~")
        } else if !inHome.isEmpty {
            parts.append("~ (\(inHome.joined(separator: ", ")))")
        }
        parts.append(contentsOf: elsewhere)
        return parts.joined(separator: ", ")
    }
}
