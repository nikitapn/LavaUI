import Foundation

/// One name in a folder.
///
/// Directories and files share a row type because the list is one list: a
/// file manager that split them into two widgets would make "go into this,
/// open that" two different gestures. The kind is a flag, not a type.
public struct FileEntry: Equatable, Sendable, Identifiable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    /// Regular-file length. Directories leave this nil so the list can say
    /// "—" rather than a block size nobody asked for.
    public var size: Int64?
    public var modified: Date?
    public var isHidden: Bool
    public var isSymlink: Bool

    public var id: String { path }

    public init(
        path: String,
        name: String? = nil,
        isDirectory: Bool,
        size: Int64? = nil,
        modified: Date? = nil,
        isHidden: Bool = false,
        isSymlink: Bool = false
    ) {
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.isHidden = isHidden
        self.isSymlink = isSymlink
    }

    public var sizeLabel: String {
        guard !isDirectory, let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// How the list is ordered. Folders stay first in every mode — that is what
/// Explorer and Thunar both do, and mixing them by size or date is how a
/// folder of photographs loses its subfolders in the middle of the pile.
public enum FileSort: String, CaseIterable, Sendable {
    case name
    case size
    case modified

    public var title: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .modified: return "Modified"
        }
    }
}

/// Filename ordering that reads runs of digits as numbers.
///
/// `file2` before `file10`. Byte order puts them the other way round, which
/// is wrong for the one thing a file manager does constantly — walking a
/// folder whose names are a prefix and a counter.
///
/// Same rule as `LavaViewCore.NaturalOrder`, kept here rather than imported:
/// this module must not depend on a picture viewer, and the two copies are
/// cheap enough that sharing them is a later cleanup, not a first-commit
/// coupling.
public enum FileName {
    /// Walks the two names' UTF-8 in place. A sort calls this n·log n times —
    /// 60,000 for `/tmp` — and the first version copied both names into
    /// arrays of scalars on every call, which made sorting a folder slower
    /// than reading it. Bytes rather than scalars costs nothing in meaning:
    /// UTF-8 orders exactly as the code points it encodes, and the only
    /// characters folded or read as digits are ASCII.
    public static func compare(_ lhs: String, _ rhs: String) -> Bool {
        var lhs = lhs
        var rhs = rhs
        let order = lhs.withUTF8 { a in rhs.withUTF8 { b in compare(a, b) } }
        return order == 0 ? lhs < rhs : order < 0
    }

    private static func compare(
        _ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>
    ) -> Int {
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if isDigit(a[i]), isDigit(b[j]) {
                let (ls, le) = digitRun(a, from: i)
                let (rs, re) = digitRun(b, from: j)
                // Leading zeros are gone, so the longer run is the larger
                // number; equal lengths compare digit by digit.
                if le - ls != re - rs { return le - ls < re - rs ? -1 : 1 }
                for k in 0..<(le - ls) where a[ls + k] != b[rs + k] {
                    return a[ls + k] < b[rs + k] ? -1 : 1
                }
                i = le
                j = re
                continue
            }
            let ca = fold(a[i])
            let cb = fold(b[j])
            if ca != cb { return ca < cb ? -1 : 1 }
            i += 1
            j += 1
        }
        // A name that is the start of the other sorts first.
        let restA = a.count - i
        let restB = b.count - j
        return restA == restB ? 0 : (restA < restB ? -1 : 1)
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }

    /// The digits from `start`, as the range that remains once leading zeros
    /// are dropped — all but the last, so a run of zeros is "0" — and where
    /// the run ends.
    private static func digitRun(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int
    ) -> (start: Int, end: Int) {
        var end = start
        while end < bytes.count, isDigit(bytes[end]) { end += 1 }
        var begin = start
        while begin < end - 1, bytes[begin] == 48 { begin += 1 }
        return (begin, end)
    }

    private static func fold(_ byte: UInt8) -> UInt8 {
        (byte >= 65 && byte <= 90) ? byte + 32 : byte
    }
}

/// A folder as the list shows it: filtered, sorted, and named.
public struct FolderListing: Equatable, Sendable {
    public var path: String
    public var entries: [FileEntry]
    /// Set when the folder could not be read. The list is empty then; the
    /// path is still where we tried to go, so Up and the address bar work.
    public var error: String?

    public init(path: String, entries: [FileEntry] = [], error: String? = nil) {
        self.path = path
        self.entries = entries
        self.error = error
    }

    public var folderCount: Int { entries.reduce(0) { $0 + ($1.isDirectory ? 1 : 0) } }
    public var fileCount: Int { entries.count - folderCount }

    public static func load(
        path: String,
        source: any FileSource,
        showHidden: Bool = false,
        sort: FileSort = .name,
        descending: Bool = false
    ) -> FolderListing {
        let path = FolderHistory.normalize(path)
        do {
            var entries = try source.entries(in: path)
            if !showHidden {
                entries.removeAll { $0.isHidden }
            }
            entries.sort { less($0, $1, sort: sort, descending: descending) }
            return FolderListing(path: path, entries: entries)
        } catch {
            return FolderListing(
                path: path, error: (error as? FileAccessError)?.message
                    ?? error.localizedDescription
            )
        }
    }

    /// Folders first, always. Then the requested column, inverted when
    /// `descending`. A path tie-break keeps the order total so two files
    /// that compare equal do not swap on every reload.
    public static func less(
        _ a: FileEntry, _ b: FileEntry, sort: FileSort, descending: Bool
    ) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        let lhs = descending ? b : a
        let rhs = descending ? a : b
        switch sort {
        case .name:
            if lhs.name != rhs.name { return FileName.compare(lhs.name, rhs.name) }
        case .size:
            let ls = lhs.size ?? -1
            let rs = rhs.size ?? -1
            if ls != rs { return ls < rs }
        case .modified:
            let ld = lhs.modified ?? .distantPast
            let rd = rhs.modified ?? .distantPast
            if ld != rd { return ld < rd }
        }
        return lhs.path < rhs.path
    }
}
