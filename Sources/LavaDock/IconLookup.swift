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
enum IconLookup {
    /// Where a desktop entry can live, most specific first. A user's own
    /// override of an application's entry has to win over the system's.
    private static var applicationDirs: [String] {
        var dirs: [String] = []
        let env = ProcessInfo.processInfo.environment
        if let home = env["XDG_DATA_HOME"], !home.isEmpty {
            dirs.append(home + "/applications")
        } else if let home = env["HOME"] {
            dirs.append(home + "/.local/share/applications")
        }
        let system = env["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"
        dirs.append(contentsOf: system.split(separator: ":").map {
            String($0) + "/applications"
        })
        return dirs
    }

    /// Icon theme roots, most specific first.
    private static var iconRoots: [String] {
        var roots: [String] = []
        let env = ProcessInfo.processInfo.environment
        if let home = env["HOME"] { roots.append(home + "/.local/share/icons") }
        roots.append("/usr/share/icons")
        roots.append("/usr/local/share/icons")
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
        list.append(contentsOf: ["breeze", "Adwaita", "Papirus", "Arc", "hicolor"])
        return list
    }

    nonisolated(unsafe) private static var iconPathCache: [String: String?] = [:]

    /// The best icon file for an application id, or nil if nothing was found.
    ///
    /// Nil is a normal answer, not a failure: a lava app that installed no
    /// desktop entry has no icon anywhere on the system, and the dock draws its
    /// initial instead.
    static func iconPath(forAppId appId: String) -> String? {
        if let cached = iconPathCache[appId] { return cached }
        let found = search(appId: appId)
        iconPathCache[appId] = found
        return found
    }

    private static func search(appId: String) -> String? {
        guard !appId.isEmpty else { return nil }
        // The desktop entry names the icon; without one, the app id is the
        // only name there is and is worth trying directly, since applications
        // that ship an icon and no entry do exist.
        let name = desktopIconName(appId: appId) ?? appId
        if name.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: name) ? name : nil
        }
        return themeIcon(named: name) ?? themeIcon(named: appId.lowercased())
    }

    // MARK: - Desktop entries

    /// The `Icon=` of the entry belonging to `appId`.
    ///
    /// Tried by filename first, which is how a well-behaved application names
    /// its entry after its app id. Failing that the entries are scanned for a
    /// `StartupWMClass` matching it — the field that exists precisely because
    /// the two do not always agree, and the reason X11 apps under Wayland are
    /// findable at all.
    private static func desktopIconName(appId: String) -> String? {
        let candidates = [appId, appId.lowercased(), "org.\(appId)"]
        for dir in applicationDirs {
            for candidate in candidates {
                let path = "\(dir)/\(candidate).desktop"
                if let icon = iconField(inFile: path) { return icon }
            }
        }
        return scanForWMClass(appId: appId)
    }

    private static func iconField(inFile path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return field("Icon", in: text)
    }

    /// One pass over every entry, done at most once per dock run.
    ///
    /// Expensive enough to be worth avoiding — a few hundred small files — and
    /// cheap enough not to be worth avoiding twice, which is what the cache is
    /// for. Built lazily so a desktop whose applications all name themselves
    /// properly never pays for it at all.
    nonisolated(unsafe) private static var wmClassIndex: [String: String]?

    private static func scanForWMClass(appId: String) -> String? {
        if wmClassIndex == nil {
            var index: [String: String] = [:]
            for dir in applicationDirs {
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                for entry in entries where entry.hasSuffix(".desktop") {
                    let path = "\(dir)/\(entry)"
                    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                          let wmClass = field("StartupWMClass", in: text),
                          let icon = field("Icon", in: text)
                    else { continue }
                    // First wins: `applicationDirs` is in precedence order.
                    if index[wmClass.lowercased()] == nil {
                        index[wmClass.lowercased()] = icon
                    }
                }
            }
            wmClassIndex = index
        }
        return wmClassIndex?[appId.lowercased()]
    }

    /// A `Key=Value` from the `[Desktop Entry]` group.
    ///
    /// Stops at the next group header, because an action group further down
    /// (`[Desktop Action new-window]`) has its own `Icon=` for a different
    /// thing entirely.
    private static func field(_ key: String, in text: String) -> String? {
        var inMainGroup = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inMainGroup = line == "[Desktop Entry]"
                continue
            }
            guard inMainGroup, line.hasPrefix(key) else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key
            else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - Icon themes

    /// Where the themes on this machine actually put their files.
    ///
    /// Four layouts rather than one because they genuinely differ: breeze is
    /// `apps/48/`, Adwaita and Papirus are `48x48/apps/`, and scalable
    /// directories are spelled both ways round. The spec describes an index
    /// file that would answer this properly; reading it is worth doing the day
    /// one of these guesses misses something.
    private static func candidatePaths(theme: String, name: String) -> [String] {
        var paths: [String] = []
        for root in iconRoots {
            let base = "\(root)/\(theme)"
            // Vector first at every size: it is exact at whatever the dock
            // magnifies to, where a raster icon is a compromise made by
            // whoever packaged it.
            paths.append("\(base)/scalable/apps/\(name).svg")
            paths.append("\(base)/apps/scalable/\(name).svg")
            for size in [128, 96, 64, 48, 256, 512, 32] {
                paths.append("\(base)/apps/\(size)/\(name).svg")
                paths.append("\(base)/\(size)x\(size)/apps/\(name).svg")
                paths.append("\(base)/apps/\(size)/\(name).png")
                paths.append("\(base)/\(size)x\(size)/apps/\(name).png")
            }
        }
        // The pre-theme dumping ground, still where a surprising number of
        // applications put their only icon.
        paths.append("/usr/share/pixmaps/\(name).svg")
        paths.append("/usr/share/pixmaps/\(name).png")
        return paths
    }

    private static func themeIcon(named name: String) -> String? {
        let manager = FileManager.default
        for theme in themes {
            for path in candidatePaths(theme: theme, name: name)
            where manager.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
}
