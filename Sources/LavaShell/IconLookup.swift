import Foundation

/// Finding the picture that belongs to an application.
///
/// Two lookups, in the order the freedesktop specs put them: an `app_id` names
/// a **desktop entry**, and the desktop entry's `Icon=` names an **icon**,
/// which is a name rather than a path and has to be found in a theme. Skipping
/// the first step and searching the theme for the app id directly works often
/// enough to be tempting and is wrong exactly where it matters — `org.kde.
/// konsole` files its icon under `utilities-terminal`.
///
/// Everything here is cached, because it is a directory walk answering a
/// question whose answer does not change while the dock runs, and it happens
/// on the frame loop.
public enum IconLookup {
    /// Icon theme roots, most specific first.
    ///
    /// XDG data dirs, not a hard-coded `/usr/share/icons`. Flatpak exports
    /// Steam's icon under `~/.local/share/flatpak/exports/share/icons`, and
    /// that path is on `XDG_DATA_DIRS` — searching only the three classic
    /// roots is why the launcher drew an S.
    private static var iconRoots: [String] {
        var roots: [String] = []
        var seen = Set<String>()
        func add(_ path: String) {
            guard !path.isEmpty, !seen.contains(path) else { return }
            seen.insert(path)
            roots.append(path)
        }
        let env = ProcessInfo.processInfo.environment
        if let home = env["XDG_DATA_HOME"], !home.isEmpty {
            add(home + "/icons")
        } else if let home = env["HOME"] {
            add(home + "/.local/share/icons")
        }
        let dataDirs = env["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"
        for dir in dataDirs.split(separator: ":") where !dir.isEmpty {
            add(String(dir) + "/icons")
        }
        // Present even when `XDG_DATA_DIRS` was not inherited — a nested
        // compositor started from a stripped environment still finds them.
        if let home = env["HOME"] {
            add(home + "/.local/share/flatpak/exports/share/icons")
        }
        add("/var/lib/flatpak/exports/share/icons")
        add("/usr/local/share/icons")
        add("/usr/share/icons")
        return roots
    }

    /// Themes to search, in preference order.
    ///
    /// `LAVA_ICON_THEME` first, because the desktop this runs on has no
    /// settings daemon to ask and guessing wrongly is worse than being told.
    /// `hicolor` is last and is not a fallback in the ordinary sense: it is
    /// where applications install their *own* icons, so it is the theme most
    /// likely to have an entry for something obscure and least likely to have
    /// a nice one.
    private static var themes: [String] {
        var list: [String] = []
        if let named = ProcessInfo.processInfo.environment["LAVA_ICON_THEME"],
           !named.isEmpty
        {
            list.append(named)
        }
        list.append(contentsOf: [
            "breeze", "Adwaita", "Papirus", "Arc", "HighContrast", "hicolor",
        ])
        return list
    }

    nonisolated(unsafe) private static var iconPathCache: [String: String?] = [:]
    nonisolated(unsafe) private static var namePathCache: [String: String?] = [:]

    /// The file for an icon *name* — what a desktop entry's `Icon=` holds.
    ///
    /// The lookup for a caller that already has the entry, and the reason it
    /// is separate from `iconPath(forAppId:)`: that one starts from a window's
    /// `app_id` and has to find the entry before it can find the icon, which
    /// means reading every desktop entry on the machine. A launcher showing a
    /// list it has already read should not pay for a second walk to be told
    /// what it is holding.
    ///
    /// An absolute path is used as given, since `Icon=` is allowed to be one.
    public static func themePath(forIconName name: String) -> String? {
        guard !name.isEmpty else { return nil }
        if let cached = namePathCache[name] {
            BootTrace.count("icon: cache hit")
            return cached
        }
        let found = BootTrace.measure("icon: search") { () -> String? in
            if name.hasPrefix("/") {
                return FileManager.default.fileExists(atPath: name) ? name : nil
            }
            return themeIcon(named: name) ?? themeIcon(named: name.lowercased())
        }
        namePathCache[name] = found
        return found
    }

    /// The file for a desktop entry, including ones that forgot `Icon=`.
    ///
    /// A hand-written `evince.desktop` often has a Name and an Exec and
    /// nothing else. The packaged `org.gnome.Evince` entry next to it names
    /// the icon; we inherit that rather than drawing a letter.
    public static func themePath(forEntry entry: DesktopEntry) -> String? {
        if let path = themePath(forIconName: entry.icon) { return path }
        if let path = themePath(forIconName: entry.id) { return path }
        if entry.icon.isEmpty {
            let key = executableKey(entry.exec)
            if !key.isEmpty, key != "flatpak", key != "env" {
                for other in entries() where other.id != entry.id && !other.icon.isEmpty {
                    if executableKey(other.exec) == key {
                        if let path = themePath(forIconName: other.icon) {
                            return path
                        }
                    }
                }
            }
        }
        return nil
    }

    /// First `Exec=` token, basename only — ` /usr/bin/evince %u` → `evince`.
    private static func executableKey(_ exec: String) -> String {
        let token = exec.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard !token.isEmpty else { return "" }
        return URL(fileURLWithPath: token).lastPathComponent.lowercased()
    }

    /// The best icon file for an application id, or nil if nothing was found.
    ///
    /// For a caller holding a window rather than an entry — a dock, a task
    /// list — where the `app_id` is all there is and the entry has to be found
    /// first. A caller that already has the entry wants
    /// `themePath(forIconName:)`.
    ///
    /// Nil is a normal answer, not a failure: a lava app that installed no
    /// desktop entry has no icon anywhere on the system, and the dock draws its
    /// initial instead.
    public static func iconPath(forAppId appId: String) -> String? {
        if let cached = iconPathCache[appId] {
            BootTrace.count("icon: cache hit")
            return cached
        }
        let found = search(appId: appId)
        iconPathCache[appId] = found
        return found
    }

    /// Hands over a list of entries already read, so the lookup by app id does
    /// not walk the directories again.
    ///
    /// For a process that shows the applications *and* looks icons up by
    /// window — the launcher reads the list to display it, and the dock will
    /// read it to name windows. The walk costs about 170 ms on a normal
    /// install, which is worth not doing twice in one process.
    public static func useEntries(_ entries: [DesktopEntry]) {
        cachedEntries = entries
        iconPathCache.removeAll()
        namePathCache.removeAll()
    }

    private static func search(appId: String) -> String? {
        guard !appId.isEmpty else { return nil }
        // The desktop entry names the icon; without one, the app id is the
        // only name there is and is worth trying directly, since applications
        // that ship an icon and no entry do exist.
        let name = desktopIconName(appId: appId) ?? appId
        return themePath(forIconName: name)
            ?? themePath(forIconName: appId.lowercased())
    }

    // MARK: - Desktop entries

    /// The `Icon=` of the entry belonging to `appId`.
    ///
    /// By id first, which is how a well-behaved application names its entry
    /// after the `app_id` its windows report. Failing that, by
    /// `StartupWMClass` — the field that exists precisely because the two do
    /// not always agree, and the reason an X11 application under Xwayland can
    /// be matched to an icon at all.
    ///
    /// Both come from `DesktopEntry.installed()`, which is the same list the
    /// launcher shows. One parser for the format, so an entry the launcher can
    /// read is one the dock can find an icon for.
    private static func desktopIconName(appId: String) -> String? {
        BootTrace.count("icon: entry scan")
        let needle = appId.lowercased()
        var byWMClass: String?
        for entry in entries() where !entry.icon.isEmpty {
            let id = entry.id.lowercased()
            if id == needle || id == "org.\(needle)" { return entry.icon }
            if byWMClass == nil, entry.startupWMClass.lowercased() == needle {
                byWMClass = entry.icon
            }
        }
        return byWMClass
    }

    /// Every installed entry, read once.
    ///
    /// A few hundred small files, and the answer does not change while a dock
    /// or a launcher is showing — so it is worth avoiding the second walk and
    /// not worth watching the directories for a third.
    nonisolated(unsafe) private static var cachedEntries: [DesktopEntry]?

    private static func entries() -> [DesktopEntry] {
        if let cachedEntries { return cachedEntries }
        let found = DesktopEntry.installed()
        cachedEntries = found
        return found
    }

    // MARK: - Icon themes

    /// The theme directories that are actually on this machine, in preference
    /// order: theme first, then root, which is the order the search wants.
    ///
    /// Computed once. Five themes across three roots is fifteen combinations
    /// and six of them exist here — the other nine were being asked about
    /// thirty times per icon, which is most of a stat storm spent confirming
    /// that Papirus is not installed.
    private static let themeDirectories: [String] = {
        var found: [String] = []
        for theme in themes {
            for root in iconRoots {
                let base = "\(root)/\(theme)"
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(
                    atPath: base, isDirectory: &isDirectory
                ), isDirectory.boolValue {
                    found.append(base)
                }
            }
        }
        return found
    }()

    /// Sizes to try, best first. A raster icon is a compromise made by whoever
    /// packaged it, so this asks for the big ones before the small.
    private static let sizes = [128, 96, 64, 48, 256, 512, 32]

    /// Where the themes on this machine actually put their files.
    ///
    /// Four layouts rather than one because they genuinely differ: breeze is
    /// `apps/48/`, Adwaita and Papirus are `48x48/apps/`, and scalable
    /// directories are spelled both ways round. The spec describes an index
    /// file that would answer this properly; reading it is worth doing the day
    /// one of these guesses misses something.
    ///
    /// Built one path at a time rather than as a list to iterate: the answer
    /// is usually in the first few, and a list means allocating four hundred
    /// strings to look at six of them.
    private static func themeIcon(named name: String) -> String? {
        let manager = FileManager.default

        func hit(_ path: String) -> Bool {
            BootTrace.count("icon: fileExists")
            return manager.fileExists(atPath: path)
        }

        for base in themeDirectories {
            // Vector first at every size: it is exact at whatever the dock
            // magnifies to.
            for path in ["\(base)/scalable/apps/\(name).svg",
                         "\(base)/apps/scalable/\(name).svg"] where hit(path) {
                return path
            }
            for size in sizes {
                for path in ["\(base)/apps/\(size)/\(name).svg",
                             "\(base)/\(size)x\(size)/apps/\(name).svg",
                             "\(base)/apps/\(size)/\(name).png",
                             "\(base)/\(size)x\(size)/apps/\(name).png"]
                where hit(path) {
                    return path
                }
            }
        }

        // The pre-theme dumping ground, still where a surprising number of
        // applications put their only icon. After every theme now rather than
        // after the first one, which is the order the comment always claimed.
        for path in ["/usr/share/pixmaps/\(name).svg",
                     "/usr/share/pixmaps/\(name).png"] where hit(path) {
            return path
        }

        BootTrace.count("icon: not found")
        return nil
    }
}
