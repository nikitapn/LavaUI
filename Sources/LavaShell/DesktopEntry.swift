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
    /// The names in `Actions=`, in the order the entry lists them.
    ///
    /// Names only: what each one is called and what it runs live in a
    /// `[Desktop Action …]` group further down the file, which the walk does
    /// not read. `actions()` goes back for those.
    public var actionNames: [String] = []
    /// The file this was read from, kept so `actions()` can go back to it.
    /// Empty for an entry parsed from text rather than from a file.
    public var path: String = ""

    public static func == (a: DesktopEntry, b: DesktopEntry) -> Bool {
        a.id == b.id
    }
}

/// One `[Desktop Action …]` group: an extra way to start an application, shown
/// on its dock icon's right-click menu.
///
/// This is the whole of what a Linux desktop has for "New Window" / "New
/// Private Window" on a launcher icon — there is no Wayland protocol for it,
/// and nothing asks the running application. The entry declares what the
/// application can always be asked to do, so an application that is not
/// running offers exactly the same items as one that is.
public struct DesktopAction: Sendable, Identifiable, Equatable {
    /// The group's name — `new-window` in `[Desktop Action new-window]`.
    /// Unique within an entry and stable across runs, which is what makes it
    /// usable as a menu id.
    public var id: String
    /// What to call it, localised the way the entry's own name is.
    public var name: String
    /// The action's own icon, when it has one. Usually empty; an action
    /// without one belongs under the application's icon.
    public var icon: String
    /// The command, field codes and all — same shape as `DesktopEntry.exec`,
    /// and turned into argv by the same `command()`.
    public var exec: String
}

extension DesktopEntry {
    /// Everything installed, sorted by name (case-insensitively).
    ///
    /// A launcher that wants "most used first" reorders this with
    /// `LaunchHistory` — frequency is a property of the user's habits, not of
    /// the install, so it does not belong in the walk.
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
            var entry = data.withUnsafeBytes { parse(bytes: $0, id: id) }
            entry?.path = file
            return entry
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
        static let actions        = Array("Actions".utf8)
        static let name           = Array("Name".utf8)
        static let genericName    = Array("GenericName".utf8)
        static let comment        = Array("Comment".utf8)
        static let application    = Array("Application".utf8)
        static let `true`         = Array("true".utf8)
        static let desktopEntry   = Array("[Desktop Entry]".utf8)
        // With the separating space, so `[Desktop ActionX]` is not a group.
        static let desktopAction  = Array("[Desktop Action ".utf8)
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
        var categories = "", keywords = "", actions = ""
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
                // something else entirely — the right-click menu, not the app.
                // Those groups are read by `actions()`, on the one file whose
                // menu is about to be shown, rather than by this walk over
                // every entry on the machine.
                if seenMainGroup { break }
                inMainGroup = equal(bytes, begin, end, Key.desktopEntry)
                seenMainGroup = inMainGroup
                continue
            }
            guard inMainGroup else { continue }
            guard let field = parseField(bytes, begin, end),
                  // A language this machine is not set to.
                  let rank = localeRank(field, bytes, locales)
            else { continue }

            @inline(__always) func value() -> String {
                DesktopEntry.value(bytes, field)
            }
            @inline(__always) func isKey(_ key: [UInt8]) -> Bool {
                rank == locales.count
                    && equal(bytes, field.keyStart, field.keyEnd, key)
            }
            @inline(__always) func isLocalisable(_ key: [UInt8]) -> Bool {
                equal(bytes, field.keyStart, field.keyEnd, key)
            }
            @inline(__always) func isValue(_ expected: [UInt8]) -> Bool {
                equal(bytes, field.valueStart, field.valueEnd, expected)
            }

            // Decisive on their own, and usually near the top of the file: an
            // entry that is not an application, or that asks not to be listed,
            // is not worth reading the rest of. `NoDisplay` is "I am a
            // handler, not an application" — a MIME association, a URL scheme
            // — and `Hidden` means the user deleted it in a way that leaves
            // the file behind.
            if isKey(Key.type) {
                guard isValue(Key.application) else { return nil }
                isApplication = true
                continue
            }
            if isKey(Key.noDisplay) || isKey(Key.hidden) {
                if isValue(Key.true) { return nil }
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
            else if isKey(Key.actions), actions.isEmpty { actions = value() }
            else if isKey(Key.startupWMClass), startupWMClass.isEmpty {
                startupWMClass = value()
            } else if isKey(Key.terminal) {
                terminal = isValue(Key.true)
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
            startupWMClass: startupWMClass,
            actionNames: split(actions)
        )
    }



    // MARK: - Actions

    /// The `[Desktop Action …]` groups this entry names, in `Actions=` order.
    ///
    /// A second pass over the one file, rather than part of the first, and
    /// deliberately — see the note on `Key`. The walk reads every entry on the
    /// machine at startup and throws away most of what it touches, so it stops
    /// at the end of the main group; this reads a single file at the moment a
    /// right-click is about to show what is in it. One file is well under a
    /// millisecond, against the ~170 ms that reading action groups for all of
    /// them would have added to a launcher's startup.
    ///
    /// Dropped on the way through: groups with no `Name` or no `Exec`, which
    /// the spec requires both of; names in `Actions=` with no group in the
    /// file; and groups the entry never listed, which the spec says to ignore.
    public func actions() -> [DesktopAction] {
        guard !actionNames.isEmpty, !path.isEmpty,
              let data = FileManager.default.contents(atPath: path)
        else { return [] }
        return data.withUnsafeBytes {
            DesktopEntry.parseActions(bytes: $0, named: actionNames)
        }
    }

    /// The action pass against text, for the same reason `parse(text:id:)`
    /// exists: it is testable without a machine's worth of applications.
    static func parseActions(text: String, named: [String]) -> [DesktopAction] {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBytes { parseActions(bytes: $0, named: named) }
    }

    private static func parseActions(
        bytes: UnsafeRawBufferPointer, named: [String]
    ) -> [DesktopAction] {
        let locales = preferredLocales()
        var found: [String: DesktopAction] = [:]

        // The wanted group being read, empty between them, and what has been
        // read out of it so far.
        var current = ""
        var name = Localised(), exec = "", icon = ""

        func flush() {
            defer { current = ""; name = Localised(); exec = ""; icon = "" }
            guard !current.isEmpty, !name.value.isEmpty, !exec.isEmpty,
                  // First group of a repeated name wins, as with a repeated key.
                  found[current] == nil
            else { return }
            found[current] = DesktopAction(
                id: current, name: name.value, icon: icon, exec: exec
            )
        }

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
                // A group ends where the next one begins, whatever that one is
                // — including `[Desktop Entry]`, which is how the main group's
                // own Name and Exec stay out of this.
                flush()
                current = actionGroupName(bytes, begin, end, wanted: named) ?? ""
                continue
            }
            guard !current.isEmpty,
                  let field = parseField(bytes, begin, end),
                  let rank = localeRank(field, bytes, locales)
            else { continue }

            if equal(bytes, field.keyStart, field.keyEnd, Key.name) {
                name.offer(value(bytes, field), rank: rank)
            } else if rank == locales.count {
                if equal(bytes, field.keyStart, field.keyEnd, Key.exec),
                   exec.isEmpty
                {
                    exec = value(bytes, field)
                } else if equal(bytes, field.keyStart, field.keyEnd, Key.icon),
                          icon.isEmpty
                {
                    icon = value(bytes, field)
                }
            }
        }
        // The last group in the file has no next header to close it.
        flush()

        // `Actions=` order, not file order: it is the order the application's
        // author put them in, and it is what every other desktop shows.
        var seen = Set<String>()
        return named.compactMap {
            seen.insert($0).inserted ? found[$0] : nil
        }
    }

    /// The name in a `[Desktop Action new-window]` header, when the header is
    /// one of the ones asked for. Nil for any other group.
    private static func actionGroupName(
        _ bytes: UnsafeRawBufferPointer, _ begin: Int, _ end: Int,
        wanted: [String]
    ) -> String? {
        let prefix = Key.desktopAction
        guard end - begin > prefix.count,
              bytes[end - 1] == UInt8(ascii: "]"),
              equal(bytes, begin, begin + prefix.count, prefix)
        else { return nil }

        var nameStart = begin + prefix.count
        var nameEnd = end - 1
        while nameStart < nameEnd, isSpace(bytes[nameStart]) { nameStart += 1 }
        while nameEnd > nameStart, isSpace(bytes[nameEnd - 1]) { nameEnd -= 1 }
        guard nameStart < nameEnd else { return nil }

        let name = String(decoding: UnsafeRawBufferPointer(
            rebasing: bytes[nameStart..<nameEnd]), as: UTF8.self)
        return wanted.contains(name) ? name : nil
    }


    // MARK: - Lines

    /// One `Key[locale]=value` line, as ranges into the file's bytes.
    ///
    /// Both kinds of group in this file — the main one and the action groups
    /// — are the same format, and telling a key from its locale suffix is the
    /// fiddly part of reading either. Doing it once, into ranges, is what lets
    /// the action pass rank translations exactly as the main pass does rather
    /// than approximate it.
    private struct Field {
        var keyStart: Int
        /// End of the key proper: `Name[de]` ends where the `[` begins.
        var keyEnd: Int
        var localeStart: Int
        var localeEnd: Int
        var hasLocale: Bool
        var valueStart: Int
        var valueEnd: Int
    }

    /// Splits an already-trimmed line. Nil when it is not a key/value pair at
    /// all — a comment, or a line with no `=` in it.
    private static func parseField(
        _ bytes: UnsafeRawBufferPointer, _ begin: Int, _ end: Int
    ) -> Field? {
        guard begin < end, bytes[begin] != UInt8(ascii: "#") else { return nil }

        var equals = begin
        while equals < end, bytes[equals] != UInt8(ascii: "=") { equals += 1 }
        guard equals < end else { return nil }

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

        return Field(
            keyStart: begin, keyEnd: keyBase,
            localeStart: localeStart, localeEnd: localeEnd,
            hasLocale: keyBase != keyEnd,
            valueStart: valueStart, valueEnd: end
        )
    }

    /// Where a field's locale sits in this machine's preference order, or nil
    /// for a language the machine is not set to. The unlocalised key ranks
    /// last, behind every translation the entry offered.
    private static func localeRank(
        _ field: Field, _ bytes: UnsafeRawBufferPointer, _ locales: [String]
    ) -> Int? {
        guard field.hasLocale else { return locales.count }
        return locales.firstIndex {
            equal(bytes, field.localeStart, field.localeEnd, Array($0.utf8))
        }
    }

    private static func value(
        _ bytes: UnsafeRawBufferPointer, _ field: Field
    ) -> String {
        String(decoding: UnsafeRawBufferPointer(
            rebasing: bytes[field.valueStart..<field.valueEnd]), as: UTF8.self)
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
