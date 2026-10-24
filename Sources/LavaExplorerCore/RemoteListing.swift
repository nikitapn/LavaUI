import Foundation

/// A server's folder listing, read into rows.
///
/// Three dialects, told apart per line rather than per server, since a
/// listing is all one or the other and checking each line costs nothing:
///
/// - **MLSD**, FTP's machine-readable listing: `type=file;size=12;modify=
///   20240101120000; name`. Exact sizes and UTC times, and asked for first.
/// - **`ls -l`**, which is what an SFTP server sends (libssh2's long entry)
///   and what almost every FTP server's `LIST` is.
/// - **DOS**, IIS's `LIST`: `10-24-23  09:15PM  <DIR>  name`.
///
/// A line that is none of them is skipped rather than shown as a file with a
/// strange name: a "total 48" header is not something to double-click.
public enum RemoteListing {
    /// `timeZone` is what an `ls -l` or DOS time is read in. Those carry the
    /// server's wall clock with no zone, and the one guess that is right for
    /// a server down the hall is this machine's own. MLSD is UTC by
    /// definition and ignores it.
    public static func parse(
        _ text: String, in folder: RemoteURL, now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> [FileEntry] {
        var out: [FileEntry] = []
        var seen = Set<String>()
        var wall = Calendar(identifier: .gregorian)
        wall.timeZone = timeZone
        // `isNewline`, not a comparison with "\n": FTP's lines end in "\r\n",
        // which Swift reads as one Character equal to neither.
        for raw in text.split(whereSeparator: \.isNewline) {
            guard let row = parseLine(String(raw), now: now, wall: wall),
                  row.name != ".", row.name != "..", !row.name.contains("/"),
                  seen.insert(row.name).inserted
            else { continue }
            out.append(FileEntry(
                path: folder.appending(row.name).string,
                name: row.name,
                isDirectory: row.isDirectory,
                size: row.isDirectory ? nil : row.size,
                modified: row.modified,
                isHidden: row.name.hasPrefix("."),
                isSymlink: row.isLink
            ))
        }
        return out
    }

    struct Row: Equatable {
        var name: String
        var isDirectory: Bool
        var size: Int64?
        var modified: Date?
        var isLink = false
    }

    static func parseLine(_ line: String, now: Date, wall: Calendar = utc) -> Row? {
        if let row = mlsd(line) { return row }
        if let row = unix(line, now: now, wall: wall) { return row }
        return dos(line, wall: wall)
    }

    // MARK: MLSD

    /// `fact=value;fact=value; name` — the name follows the first space, and
    /// may itself contain spaces and semicolons.
    static func mlsd(_ line: String) -> Row? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let facts = line[..<space]
        guard facts.hasSuffix(";"), facts.contains("=") else { return nil }
        let name = String(line[line.index(after: space)...])
        guard !name.isEmpty else { return nil }
        var row = Row(name: name, isDirectory: false)
        var typed = false
        for fact in facts.split(separator: ";") {
            guard let eq = fact.firstIndex(of: "=") else { continue }
            let key = fact[..<eq].lowercased()
            let value = String(fact[fact.index(after: eq)...])
            switch key {
            case "type":
                typed = true
                switch value.lowercased() {
                case "dir": row.isDirectory = true
                // This folder and its parent, by another name.
                case "cdir", "pdir": return nil
                case let other where other.hasPrefix("os.unix=slink") || other.hasPrefix("os.unix=symlink"):
                    row.isLink = true
                default: break
                }
            case "size", "sizd":
                row.size = Int64(value)
            case "modify":
                row.modified = mlsdTime(value)
            default:
                break
            }
        }
        return typed ? row : nil
    }

    /// `YYYYMMDDHHMMSS`, optionally `.sss`, always UTC.
    static func mlsdTime(_ value: String) -> Date? {
        let digits = value.prefix { $0.isNumber }
        guard digits.count >= 14 else { return nil }
        let chars = Array(digits)
        func number(_ from: Int, _ count: Int) -> Int? { Int(String(chars[from..<from + count])) }
        guard let year = number(0, 4), let month = number(4, 2), let day = number(6, 2),
              let hour = number(8, 2), let minute = number(10, 2), let second = number(12, 2)
        else { return nil }
        var parts = DateComponents()
        (parts.year, parts.month, parts.day) = (year, month, day)
        (parts.hour, parts.minute, parts.second) = (hour, minute, second)
        return utc.date(from: parts)
    }

    // MARK: ls -l

    static let months = ["jan", "feb", "mar", "apr", "may", "jun",
                         "jul", "aug", "sep", "oct", "nov", "dec"]

    /// `drwxr-xr-x  2 owner group  4096 Oct 24 12:00 name`. Some servers
    /// leave out the group, or the link count, so the columns are found from
    /// the date: a month name, after the size, followed by a day and a time
    /// or a year. The name is everything after that, spaces and all.
    static func unix(_ line: String, now: Date, wall: Calendar) -> Row? {
        guard let kind = line.first, "-dlbcps".contains(kind) else { return nil }
        let permissions = line.prefix { !$0.isWhitespace }
        guard permissions.count >= 10 else { return nil }
        let tokens = tokenize(line)
        // [0] is the permissions; the month is the earliest token that is one,
        // with a number before it.
        // Day, time-or-year and at least one word of name follow it.
        guard let m = tokens.indices.dropFirst(2).first(where: {
            months.contains(tokens[$0].text.lowercased()) && Int64(tokens[$0 - 1].text) != nil
        }), m + 3 < tokens.count, let day = Int(tokens[m + 1].text)
        else { return nil }
        let size = Int64(tokens[m - 1].text)
        let month = months.firstIndex(of: tokens[m].text.lowercased())! + 1
        let clock = String(tokens[m + 2].text)
        var name = String(line[tokens[m + 3].start...])
        var isLink = false
        if kind == "l", let arrow = name.range(of: " -> ") {
            name = String(name[..<arrow.lowerBound])
            isLink = true
        }
        return Row(
            name: name,
            isDirectory: kind == "d",
            size: kind == "-" ? size : nil,
            modified: unixTime(month: month, day: day, clock: clock, now: now, wall: wall),
            isLink: isLink
        )
    }

    /// `12:00` is this year — or last year, for a date that would otherwise be
    /// in the future, which is how `ls` decides to show a time at all — and
    /// `2023` is a date at midnight.
    static func unixTime(month: Int, day: Int, clock: String, now: Date, wall: Calendar) -> Date? {
        var parts = DateComponents()
        parts.month = month
        parts.day = day
        if clock.contains(":") {
            let hm = clock.split(separator: ":")
            guard hm.count == 2, let h = Int(hm[0]), let mi = Int(hm[1]) else { return nil }
            parts.hour = h
            parts.minute = mi
            parts.year = wall.component(.year, from: now)
            if let date = wall.date(from: parts), date > now.addingTimeInterval(86_400) {
                parts.year! -= 1
            }
        } else {
            guard let year = Int(clock) else { return nil }
            parts.year = year
        }
        return wall.date(from: parts)
    }

    // MARK: DOS

    /// `10-24-23  09:15PM  <DIR>  name` or `… 1234 name`.
    static func dos(_ line: String, wall: Calendar) -> Row? {
        let tokens = tokenize(line)
        guard tokens.count >= 4 else { return nil }
        let date = tokens[0].text.split(separator: "-")
        guard date.count == 3, let month = Int(date[0]), let day = Int(date[1]),
              var year = Int(date[2])
        else { return nil }
        if year < 100 { year += year < 70 ? 2000 : 1900 }
        let clock = tokens[1].text.uppercased()
        guard clock.hasSuffix("AM") || clock.hasSuffix("PM") else { return nil }
        let hm = clock.dropLast(2).split(separator: ":")
        guard hm.count == 2, var hour = Int(hm[0]), let minute = Int(hm[1]) else { return nil }
        if clock.hasSuffix("PM"), hour < 12 { hour += 12 }
        if clock.hasSuffix("AM"), hour == 12 { hour = 0 }
        let isDirectory = tokens[2].text.uppercased() == "<DIR>"
        let size = isDirectory ? nil : Int64(tokens[2].text)
        guard isDirectory || size != nil else { return nil }
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute) = (year, month, day, hour, minute)
        return Row(
            name: String(line[tokens[3].start...]),
            isDirectory: isDirectory,
            size: size,
            modified: wall.date(from: parts)
        )
    }

    // MARK: Pieces

    struct Token {
        var text: Substring
        var start: String.Index
    }

    static func tokenize(_ line: String) -> [Token] {
        var tokens: [Token] = []
        var i = line.startIndex
        while i < line.endIndex {
            while i < line.endIndex, line[i].isWhitespace { i = line.index(after: i) }
            guard i < line.endIndex else { break }
            let start = i
            while i < line.endIndex, !line[i].isWhitespace { i = line.index(after: i) }
            tokens.append(Token(text: line[start..<i], start: start))
        }
        return tokens
    }

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
