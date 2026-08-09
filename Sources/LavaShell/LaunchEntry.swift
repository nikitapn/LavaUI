import Foundation

#if canImport(Glibc)
import Glibc
#endif

extension DesktopEntry {
    /// The `Exec=` line as an argv, with the spec's field codes removed.
    ///
    /// `Exec` is not a shell command, though it looks like one. It is a
    /// quoted-argument list with placeholders the launcher is supposed to fill
    /// in: `%f` a file, `%u` a URL, `%i` the icon as two arguments, `%c` the
    /// translated name. Launching nothing in particular means every one of
    /// them is dropped — which is what a launcher opening an app with no
    /// document does, and what leaving them in would get wrong: an editor
    /// handed the literal string `%F` opens a file by that name.
    ///
    /// Empty if the line is empty, which the parser has already rejected.
    public func command() -> [String] {
        var argv: [String] = []
        var current = ""
        var haveCurrent = false
        var quoted = false
        var escaped = false

        for character in exec {
            if escaped {
                current.append(character)
                haveCurrent = true
                escaped = false
                continue
            }
            switch character {
            case "\\" where quoted:
                escaped = true
            case "\"":
                quoted.toggle()
                haveCurrent = true
            case " ", "\t":
                if quoted {
                    current.append(character)
                } else if haveCurrent {
                    argv.append(current)
                    current = ""
                    haveCurrent = false
                }
            default:
                current.append(character)
                haveCurrent = true
            }
        }
        if haveCurrent { argv.append(current) }

        var out: [String] = []
        for argument in argv {
            // A field code standing alone is dropped; `%%` is a literal
            // percent, and anything else with a percent in it keeps its shape.
            if argument.count == 2, argument.hasPrefix("%") {
                if argument == "%%" { out.append("%") }
                continue
            }
            out.append(argument.replacingOccurrences(of: "%%", with: "%"))
        }
        return out
    }

    /// Starts the application, detached from this process.
    ///
    /// Detached matters here more than usual: a launcher exits as soon as it
    /// has launched something, and a child in its process group would be a
    /// child of a process that is about to disappear. `setsid` puts it in a
    /// session of its own first, so closing the launcher cannot take the
    /// application with it — the same reason a terminal's `&` is not enough.
    ///
    /// Returns false if there was nothing runnable in the entry.
    @discardableResult
    public func launch(terminalProgram: String = "alacritty") -> Bool {
        var argv = command()
        guard !argv.isEmpty else { return false }

        // A command-line program with a desktop entry. Without a terminal it
        // starts, prints into nowhere and exits, which reads as "nothing
        // happened" — the entry says so, and honouring it is the difference
        // between htop working and htop appearing not to exist.
        if terminal {
            argv = [terminalProgram, "-e"] + argv
        }

        // `posix_spawn` rather than `Process`, for the one flag that matters:
        // Foundation has no way to ask for a new session, and without it the
        // application stays in the process group of a launcher that is about
        // to exit — so anything signalling that group hits it too.
        //
        // The constant is spelled out because Swift's Glibc overlay does not
        // export it: it is a `#define` in `spawn.h` rather than an enum, and
        // the importer only brings across the latter. glibc has had it at
        // 0x80 since 2.26; a kernel or libc without it ignores the bit, which
        // costs the new session and nothing else.
        let spawnSetsid: Int16 = 0x80
        var attributes = posix_spawnattr_t()
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, spawnSetsid)

        let cArgv: [UnsafeMutablePointer<CChar>?] =
            argv.map { strdup($0) } + [nil]
        defer { for pointer in cArgv where pointer != nil { free(pointer) } }

        // The entry's `Path=`, applied around the spawn. Not thread-safe in
        // general; this process is about to exit and has one thread doing
        // this, which is the only reason it is acceptable here.
        var previousDirectory: String?
        if !workingDirectory.isEmpty {
            previousDirectory = FileManager.default.currentDirectoryPath
            _ = FileManager.default.changeCurrentDirectoryPath(workingDirectory)
        }
        defer {
            if let previousDirectory {
                _ = FileManager.default.changeCurrentDirectoryPath(previousDirectory)
            }
        }

        var pid: pid_t = 0
        let failure = posix_spawnp(&pid, argv[0], nil, &attributes, cArgv, environ)
        if failure != 0 {
            FileHandle.standardError.write(
                Data("launch \(id): \(String(cString: strerror(failure)))\n".utf8)
            )
            return false
        }
        return true
    }
}

// MARK: - Searching

extension DesktopEntry {
    /// How well this entry answers `query`, or nil for "not at all".
    ///
    /// Ranked rather than filtered, because with a few hundred applications
    /// the difference between a good launcher and a bad one is entirely in the
    /// order. Higher is better; the ladder is deliberately coarse, since what
    /// matters is that a prefix of the name beats a mention in a description,
    /// not by how much.
    public func matchScore(_ query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let needle = query.lowercased()
        let name = self.name.lowercased()

        if name == needle { return 100 }
        if name.hasPrefix(needle) { return 90 }
        // A word inside the name: "code" should find "Visual Studio Code"
        // rather than only things beginning with it.
        if name.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) {
            return 80 }
        if name.contains(needle) { return 70 }

        if id.lowercased().contains(needle) { return 60 }
        if genericName.lowercased().contains(needle) { return 50 }
        if keywords.contains(where: { $0.lowercased().contains(needle) }) { return 40 }
        if categories.contains(where: { $0.lowercased().contains(needle) }) { return 30 }
        // Last, and the reason "browser" finds anything at all on a machine
        // where no application is called that.
        if comment.lowercased().contains(needle) { return 20 }
        return nil
    }

    /// `installed()` narrowed to `query`, best first, ties broken by name so
    /// the order does not shuffle as the user types.
    public static func search(_ query: String, in entries: [DesktopEntry]) -> [DesktopEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return entries }
        return entries.compactMap { entry -> (DesktopEntry, Int)? in
            guard let score = entry.matchScore(trimmed) else { return nil }
            return (entry, score)
        }
        .sorted {
            $0.1 != $1.1 ? $0.1 > $1.1
                         : $0.0.name.lowercased() < $1.0.name.lowercased()
        }
        .map(\.0)
    }
}
