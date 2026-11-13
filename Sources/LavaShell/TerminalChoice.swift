import Foundation

/// Which terminal "Open Terminal Here" starts, and starting it in a folder.
///
/// There is no freedesktop standard for "the user's terminal" — GNOME keeps
/// one in gsettings, KDE in kdeglobals, everything else in `$TERMINAL` by
/// convention — so this asks in the order a Lava session can answer:
///
/// 1. `$TERMINAL`, a command line, when the user has set one: it is the only
///    statement of preference there is, and it outranks the house terminal.
/// 2. LavaTerm, the desktop's own.
/// 3. Any installed entry in the `TerminalEmulator` category, first by name.
///
/// The folder is the terminal's working directory, which every terminal's
/// shell inherits — so it works for all of them, with no flag that each
/// spells differently (`--working-directory`, `-d`, `--cwd`).
public enum TerminalChoice {
    /// The desktop id LavaTerm is installed under (`packaging/apps.conf`).
    public static let houseTerminalID = "LavaTerm"

    public static func choose(
        from entries: [DesktopEntry],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DesktopEntry? {
        if let command = environment["TERMINAL"]?.trimmingCharacters(in: .whitespaces),
           !command.isEmpty
        {
            return DesktopEntry(id: "TERMINAL", name: command, exec: command)
        }
        if let house = entries.first(where: { $0.id == houseTerminalID }) {
            return house
        }
        return entries.first { $0.categories.contains("TerminalEmulator") }
    }

    /// Starts the chosen terminal in `directory`. False when there is no
    /// terminal to start, or it would not start.
    @discardableResult
    public static func open(
        in directory: String, entries: [DesktopEntry] = DesktopEntry.installed()
    ) -> Bool {
        guard var entry = choose(from: entries) else { return false }
        entry.workingDirectory = directory
        return entry.launch()
    }
}
