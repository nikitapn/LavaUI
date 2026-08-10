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
        guard let text = BootTrace.measure("    read file", {
            try? String(contentsOfFile: file, encoding: .utf8)
        }) else {
            return nil
        }
        return BootTrace.measure("    parse text") { parse(text: text, id: id) }
    }

    /// The parse itself, against text rather than a path — which is what makes
    /// it testable without a machine's worth of applications installed.
    static func parse(text: String, id: String) -> DesktopEntry? {
        var fields: [String: String] = [:]
        var inMainGroup = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                // Only `[Desktop Entry]`. A `[Desktop Action new-window]`
                // further down has its own Name, Exec and Icon describing
                // something else entirely — the right-click menu, not the app.
                inMainGroup = line == "[Desktop Entry]"
                continue
            }
            guard inMainGroup, !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<equals])
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { fields[key] = value }
        }

        // Only applications. The same directories hold `Type=Link` and
        // `Type=Directory` entries, which are not things to launch.
        guard fields["Type"] == "Application" else { return nil }
        // The entry asking not to be listed. `NoDisplay` is "I am a handler,
        // not an application" — a MIME association, a URL scheme — and
        // `Hidden` means the user deleted it in a way that leaves the file.
        guard !isTrue(fields["NoDisplay"]), !isTrue(fields["Hidden"]) else {
            return nil
        }
        // `TryExec` is the entry's own liveness check: a package that left its
        // entry behind names a binary that is not there any more.
        if let probe = fields["TryExec"], !probe.isEmpty,
           !BootTrace.measure("  TryExec probe", { exists(program: probe) })
        {
            return nil
        }
        guard let exec = fields["Exec"], !exec.isEmpty else { return nil }

        let name = localised("Name", in: fields) ?? id
        return DesktopEntry(
            id: id,
            name: name,
            genericName: localised("GenericName", in: fields) ?? "",
            comment: localised("Comment", in: fields) ?? "",
            icon: fields["Icon"] ?? "",
            exec: exec,
            workingDirectory: fields["Path"] ?? "",
            terminal: isTrue(fields["Terminal"]),
            categories: split(fields["Categories"]),
            keywords: split(fields["Keywords"]),
            startupWMClass: fields["StartupWMClass"] ?? ""
        )
    }

    /// `Name[de_DE]`, then `Name[de]`, then `Name`.
    ///
    /// Worth the twelve lines: an entry that has been translated shows the
    /// translation everywhere else on the machine, and a launcher that alone
    /// showed the English one would look like it was reading a different
    /// system.
    private static func localised(_ key: String, in fields: [String: String]) -> String? {
        for locale in preferredLocales() {
            if let value = fields["\(key)[\(locale)]"], !value.isEmpty {
                return value
            }
        }
        let value = fields[key]
        return (value?.isEmpty ?? true) ? nil : value
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

    private static func isTrue(_ value: String?) -> Bool { value == "true" }

    private static func split(_ value: String?) -> [String] {
        (value ?? "").split(separator: ";")
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
