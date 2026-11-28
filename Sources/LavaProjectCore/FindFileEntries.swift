import Foundation
import Glibc

public struct FindFileEntry: Equatable, Sendable {
    public let name: String
    public let isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }

    /// Keep the directory order ready for an empty query.
    public static func list(in directory: URL) throws -> [Self] {
        let files = FileManager.default
        return try files.contentsOfDirectory(atPath: directory.path).map { name in
            var isDirectory: ObjCBool = false
            files.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isDirectory)
            return Self(name: name, isDirectory: isDirectory.boolValue)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            let order = $0.name.compare($1.name, options: .caseInsensitive)
            return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
        }
    }
}

public struct FindFileDetails: Equatable, Sendable {
    public let permissions: String
    public let size: String
    public let modified: String

    public static func read(_ url: URL, now: Date = Date()) -> Self? {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return nil }
        return Self(permissions: permissionText(info.st_mode),
                    size: sizeText(Int64(info.st_size)),
                    modified: modifiedText(Date(timeIntervalSince1970: Double(info.st_mtim.tv_sec)), now: now))
    }

    public static func permissionText(_ mode: mode_t) -> String {
        let types: [mode_t: Character] = [
            S_IFDIR: "d", S_IFREG: "-", S_IFLNK: "l", S_IFIFO: "p",
            S_IFSOCK: "s", S_IFCHR: "c", S_IFBLK: "b",
        ]
        var text = String(types[mode & S_IFMT] ?? "?")
        for (index, shift) in [6, 3, 0].enumerated() {
            let bits = mode >> shift
            text.append(bits & 4 == 0 ? "-" : "r")
            text.append(bits & 2 == 0 ? "-" : "w")
            let executable = bits & 1 != 0
            if mode & ([S_ISUID, S_ISGID, S_ISVTX][index]) != 0 {
                text.append(index == 2 ? (executable ? "t" : "T") : (executable ? "s" : "S"))
            } else {
                text.append(executable ? "x" : "-")
            }
        }
        return text
    }

    public static func sizeText(_ bytes: Int64) -> String {
        guard bytes >= 1024 else { return String(bytes) }
        var size = Double(bytes)
        for unit in ["k", "M", "G", "T", "P"] {
            size /= 1024
            if size < 1024 || unit == "P" {
                let decimals = size < 10 && size != size.rounded() && unit != "k"
                return String(format: decimals ? "%.1f%@" : "%.0f%@", locale: Locale(identifier: "en_US_POSIX"),
                              size, unit)
            }
        }
        return String(bytes)
    }

    public static func modifiedText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if sameYear, (1...14).contains(days) { return days == 1 ? "1 day ago" : "\(days) days ago" }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = sameYear ? "MMM dd HH:mm" : "yyyy MMM dd"
        return format.string(from: date)
    }
}
