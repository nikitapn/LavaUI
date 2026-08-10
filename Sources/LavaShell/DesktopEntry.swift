import Foundation

/// The list of applications installed on this machine.
///
/// There is no registry, no daemon and no database — the answer is a directory
/// walk. Freedesktop's *desktop entry* spec says an application advertises
/// itself by dropping a `.desktop` file into `applications/` under one of the
/// XDG data directories, and that file is the whole of what the system knows
/// about it: what to call it, what to run, which icon to draw. Everything that
/// shows you a list of apps — every launcher, every menu, every dock — is
/// reading these files. So is this.
///
/// Two consequences worth knowing, because they explain most of the surprises:
///
///   * **The file is the identity.** `firefox.desktop` is the app id, and it is
///     what a window's `app_id` is supposed to match. When it does not, the
///     entry says so itself in `StartupWMClass` — which is why `IconLookup`
///     has to read that field at all.
///   * **Precedence is by directory order.** The user's own
///     `~/.local/share/applications` comes before `/usr/share/applications`, so
///     dropping a file there overrides the packaged one under the same name.
///     First one wins; later ones with that id are not merged, they are
///     ignored.
public struct DesktopEntry: Sendable, Identifiable, Equatable {
    /// The entry's id: its filename without `.desktop`, with any subdirectory
    /// folded in as the spec says (`kde/konsole.desktop` → `kde-konsole`).
    public var id: String
    /// What to call it. Localised if the entry offers this machine's language.
    public var name: String
    /// What kind of thing it is — "Web Browser", "Text Editor". Often empty,
    /// and worth showing beside the name when it is not: two entries called
    /// "Chrome" are told apart by this and nothing else.
    public var genericName: String
    /// The longer description, used for searching rather than for showing.
    public var comment: String
    /// Icon name (looked up in a theme) or an absolute path.
    public var icon: String
    /// The `Exec=` line, field codes and all. `command()` turns it into argv.
    public var exec: String
    /// Working directory, when the entry asks for one.
    public var workingDirectory: String
    /// Whether it needs a terminal to run in — a command-line program with an
    /// entry, which without this would start invisibly and exit.
    public var terminal: Bool
    /// For searching: `Categories=` and `Keywords=`, which is how "browser"
    /// finds Firefox even though the word appears nowhere in its name.
    public var categories: [String]
    public var keywords: [String]
    /// The window class this application's windows actually report, when that
    /// differs from the entry's id. The field exists precisely because the two
    /// often disagree, and it is the only reason an X11 window under Wayland
    /// can be matched to its icon at all.
    public var startupWMClass: String

    public static func == (a: DesktopEntry, b: DesktopEntry) -> Bool {
        a.id == b.id
    }
}

extension DesktopEntry {
    /// Everything installed, in the order a launcher should show it: by name,
    /// case-insensitively.
    ///
    /// Not cached. It is a few hundred small files and about ten milliseconds,
    /// and a launcher that runs for four seconds should see an application
    /// that was installed while it was closed.
    public static func installed() -> [DesktopEntry] {
        BootTrace.measure("desktop entries: installed()") {
            var byId: [String: DesktopEntry] = [:]
            var order: [String] = []

            for directory in applicationDirectories() {
                let files = BootTrace.measure("  walk") { desktopFiles(in: directory) }
                BootTrace.count("  .desktop files", files.count)
                for file in files {
                    let id = entryId(for: file, root: directory)
                    // First wins: `applicationDirectories` is in precedence
                    // order, so a user's override is already ahead of the
                    // packaged one.
                    guard byId[id] == nil else { continue }
                    guard let entry = BootTrace.measure("  read + parse", {
                        parse(file: file, id: id)
                    }) else { continue }
                    byId[id] = entry
                    order.append(id)
                }
            }

            return order.compactMap { byId[$0] }
                .sorted { $0.name.lowercased() < $1.name.lowercased() }
        }
    }

    /// Where entries live, most specific first.
    public static func applicationDirectories() -> [String] {
        var directories: [String] = []
        let environment = ProcessInfo.processInfo.environment
        if let home = environment["XDG_DATA_HOME"], !home.isEmpty {
            directories.append(home + "/applications")
        } else if let home = environment["HOME"] {
            directories.append(home + "/.local/share/applications")
        }
        let system = environment["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"
        directories.append(contentsOf: system.split(separator: ":")
            .filter { !$0.isEmpty }
            .map { String($0) + "/applications" })
        return directories
    }

    // MARK: - Walking

    private static func desktopFiles(in directory: String) -> [String] {
        let manager = FileManager.default
        guard let walk = manager.enumerator(atPath: directory) else { return [] }
        var files: [String] = []
        for case let relative as String in walk where relative.hasSuffix(".desktop") {
            files.append(directory + "/" + relative)
        }
        // Alphabetical, so two runs on one machine produce the same list. The
        // enumerator's own order is the filesystem's, which is not an order.
        return files.sorted()
    }

    /// `…/applications/kde/konsole.desktop` under `…/applications` is the id
    /// `kde-konsole`, which is what the spec says and what a `StartupWMClass`
    /// is matched against.
    private static func entryId(for file: String, root: String) -> String {
        var relative = file
        if relative.hasPrefix(root + "/") {
            relative.removeFirst(root.count + 1)
        }
        if relative.hasSuffix(".desktop") { relative.removeLast(".desktop".count) }
        return relative.replacingOccurrences(of: "/", with: "-")
    }

    // MARK: - Parsing

    private static func parse(file: String, id: String) -> DesktopEntry? {
        guard let data = BootTrace.measure("    read file", {
            FileManager.default.contents(atPath: file)
        }) else {
            return nil
        }
        return BootTrace.measure("    parse bytes") {
            data.withUnsafeBytes { parse(bytes: $0, id: id) }
        }
    }

    /// The parse itself, against text rather than a path — which is what makes
    /// it testable without a machine's worth of applications installed.
    static func parse(text: String, id: String) -> DesktopEntry? {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBytes { parse(bytes: $0, id: id) }
    }

    /// The keys this reads, as bytes, because that is what a file is.
    ///
    /// The parser works on bytes rather than on `String` for one reason, and
    /// it is worth writing down: a desktop entry is mostly translations. A
    /// typical `/usr/share/applications` file is a hundred lines of which
    /// eighty are `Name[xx]`, `Comment[xx]` and `GenericName[xx]` for
    /// languages this machine is not set to, plus `[Desktop Action]` groups
    /// describing right-click items. Reading that into a `[String: String]`
    /// allocates a grapheme-aware `String` for every key and every value, all
    /// but a dozen of which are discarded immediately. On this machine that
    /// was 172 ms across 257 files — more than a third of the launcher's
    /// entire startup, spent building dictionaries to throw away.
    ///
    /// Comparing byte spans against these instead allocates a `String` only
    /// for a value that is actually kept.
    private enum Key {
        static let type           = Array("Type".utf8)
        static let noDisplay      = Array("NoDisplay".utf8)
        static let hidden         = Array("Hidden".utf8)
        static let tryExec        = Array("TryExec".utf8)
        static let exec           = Array("Exec".utf8)
        static let icon           = Array("Icon".utf8)
        static let path           = Array("Path".utf8)
        static let terminal       = Array("Terminal".utf8)
        static let categories     = Array("Categories".utf8)
        static let keywords       = Array("Keywords".utf8)
        static let startupWMClass = Array("StartupWMClass".utf8)
        static let name           = Array("Name".utf8)
        static let genericName    = Array("GenericName".utf8)
        static let comment        = Array("Comment".utf8)
        static let application    = Array("Application".utf8)
        static let `true`         = Array("true".utf8)
        static let desktopEntry   = Array("[Desktop Entry]".utf8)
    }

    /// A localisable field, kept with the rank of the locale it came from so a
    /// later `Name=` cannot displace an earlier `Name[de]=`.
    ///
    /// Rank 0 is the best match this machine's language offers; the
    /// unlocalised key ranks last. Worth the bookkeeping: an entry that has
    /// been translated shows the translation everywhere else on the machine,
    /// and a launcher that alone showed the English one would look like it was
    /// reading a different system.
    private struct Localised {
        var value = ""
        var rank = Int.max

        mutating func offer(_ candidate: String, rank candidateRank: Int) {
            // Strictly better only, so the first of two equal-ranked keys wins
            // — which is what the format says about a repeated key.
            guard candidateRank < rank, !candidate.isEmpty else { return }
            value = candidate
            rank = candidateRank
        }
    }

    private static func parse(bytes: UnsafeRawBufferPointer, id: String)
        -> DesktopEntry?
    {
        let locales = preferredLocales()

        var isApplication = false
        var exec = "", icon = "", path = "", tryExec = "", startupWMClass = ""
        var categories = "", keywords = ""
        var terminal = false
        var name = Localised(), genericName = Localised(), comment = Localised()

        var inMainGroup = false
        var seenMainGroup = false
        var lineStart = 0

        while lineStart <= bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != UInt8(ascii: "\n") {
                lineEnd += 1
            }
            defer { lineStart = lineEnd + 1 }

            var begin = lineStart, end = lineEnd
            while begin < end, isSpace(bytes[begin]) { begin += 1 }
            while end > begin, isSpace(bytes[end - 1]) { end -= 1 }
            if begin >= end { continue }

            if bytes[begin] == UInt8(ascii: "[") {
                // Only `[Desktop Entry]`. A `[Desktop Action new-window]`
                // further down has its own Name, Exec and Icon describing
                // something else entirely — the right-click menu, not the app
                // — and once the main group has ended there is nothing left in
                // the file this cares about.
                if seenMainGroup { break }
                inMainGroup = equal(bytes, begin, end, Key.desktopEntry)
                seenMainGroup = inMainGroup
                continue
            }
            guard inMainGroup, bytes[begin] != UInt8(ascii: "#") else { continue }

            var equals = begin
            while equals < end, bytes[equals] != UInt8(ascii: "=") { equals += 1 }
            guard equals < end else { continue }

            var keyEnd = equals
            while keyEnd > begin, isSpace(bytes[keyEnd - 1]) { keyEnd -= 1 }
            var valueStart = equals + 1
            while valueStart < end, isSpace(bytes[valueStart]) { valueStart += 1 }

            // `Name[de_DE]` splits into the key and the locale it is for.
            var keyBase = keyEnd
            var localeStart = keyEnd
            var i = begin
            while i < keyEnd, bytes[i] != UInt8(ascii: "[") { i += 1 }
            if i < keyEnd {
                keyBase = i
                localeStart = i + 1
            }
            let localeEnd = keyBase == keyEnd ? keyEnd
                : (bytes[keyEnd - 1] == UInt8(ascii: "]") ? keyEnd - 1 : keyEnd)

            let rank: Int
            if keyBase == keyEnd {
                rank = locales.count // the unlocalised key, ranked last
            } else if let found = locales.firstIndex(where: {
                equal(bytes, localeStart, localeEnd, Array($0.utf8))
            }) {
                rank = found
            } else {
                continue // a language this machine is not set to
            }

            @inline(__always) func value() -> String {
                String(decoding: UnsafeRawBufferPointer(
                    rebasing: bytes[valueStart..<end]), as: UTF8.self)
            }
            @inline(__always) func isKey(_ key: [UInt8]) -> Bool {
                rank == locales.count && equal(bytes, begin, keyBase, key)
            }
            @inline(__always) func isLocalisable(_ key: [UInt8]) -> Bool {
                equal(bytes, begin, keyBase, key)
            }

            // Decisive on their own, and usually near the top of the file: an
            // entry that is not an application, or that asks not to be listed,
            // is not worth reading the rest of. `NoDisplay` is "I am a
            // handler, not an application" — a MIME association, a URL scheme
            // — and `Hidden` means the user deleted it in a way that leaves
            // the file behind.
            if isKey(Key.type) {
                guard equal(bytes, valueStart, end, Key.application) else { return nil }
                isApplication = true
                continue
            }
            if isKey(Key.noDisplay) || isKey(Key.hidden) {
                if equal(bytes, valueStart, end, Key.true) { return nil }
                continue
            }

            if isLocalisable(Key.name) { name.offer(value(), rank: rank); continue }
            if isLocalisable(Key.genericName) {
                genericName.offer(value(), rank: rank); continue
            }
            if isLocalisable(Key.comment) {
                comment.offer(value(), rank: rank); continue
            }

            if isKey(Key.exec), exec.isEmpty { exec = value() }
            else if isKey(Key.icon), icon.isEmpty { icon = value() }
            else if isKey(Key.tryExec), tryExec.isEmpty { tryExec = value() }
            else if isKey(Key.path), path.isEmpty { path = value() }
            else if isKey(Key.categories), categories.isEmpty { categories = value() }
            else if isKey(Key.keywords), keywords.isEmpty { keywords = value() }
            else if isKey(Key.startupWMClass), startupWMClass.isEmpty {
                startupWMClass = value()
            } else if isKey(Key.terminal) {
                terminal = equal(bytes, valueStart, end, Key.true)
            }
        }

        // Only applications. The same directories hold `Type=Link` and
        // `Type=Directory` entries, which are not things to launch.
        guard isApplication else { return nil }
        // `TryExec` is the entry's own liveness check: a package that left its
        // entry behind names a binary that is not there any more.
        if !tryExec.isEmpty,
           !BootTrace.measure("  TryExec probe", { exists(program: tryExec) })
        {
            return nil
        }
        guard !exec.isEmpty else { return nil }

        return DesktopEntry(
            id: id,
            name: name.value.isEmpty ? id : name.value,
            genericName: genericName.value,
            comment: comment.value,
            icon: icon,
            exec: exec,
            workingDirectory: path,
            terminal: terminal,
            categories: split(categories),
            keywords: split(keywords),
            startupWMClass: startupWMClass
        )
    }

    /// ASCII whitespace, which is all a key/value format can contain around
    /// its delimiters. Covers the `\r` of a file written on Windows.
    @inline(__always)
    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\r")
    }

    @inline(__always)
    private static func equal(
        _ bytes: UnsafeRawBufferPointer, _ start: Int, _ end: Int, _ other: [UInt8]
    ) -> Bool {
        guard end - start == other.count else { return false }
        for offset in 0..<other.count where bytes[start + offset] != other[offset] {
            return false
        }
        return true
    }

    private static func preferredLocales() -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let raw = environment["LC_MESSAGES"] ?? environment["LANG"] ?? ""
        // "de_DE.UTF-8@euro" → ["de_DE", "de"]
        var value = raw
        if let cut = value.firstIndex(of: ".") { value = String(value[..<cut]) }
        if let cut = value.firstIndex(of: "@") { value = String(value[..<cut]) }
        guard !value.isEmpty, value != "C", value != "POSIX" else { return [] }
        var locales = [value]
        if let underscore = value.firstIndex(of: "_") {
            locales.append(String(value[..<underscore]))
        }
        return locales
    }

    private static func split(_ value: String) -> [String] {
        value.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func exists(program: String) -> Bool {
        let manager = FileManager.default
        if program.contains("/") { return manager.isExecutableFile(atPath: program) }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            if manager.isExecutableFile(atPath: "\(directory)/\(program)") {
                return true
            }
        }
        return false
    }
}
