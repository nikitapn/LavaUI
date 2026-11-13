import Foundation

/// Ordered app ids the user asked the dock to keep, **per workspace**.
///
/// A work desk and a home desk do not want the same pins. The file is
/// still a preference: missing or unreadable is the defaults, not a crash.
/// A `[N]` section is workspace N's pins — an empty one is "none", which is
/// what unpinning the last of them writes. A workspace with **no** section
/// shows the defaults: a dock that was empty on every new workspace made the
/// desktop look unfinished. `[*]` in the file replaces the defaults; without
/// it they are `builtInDefaults`.
public struct DockPins: Equatable, Sendable {
    public var byWorkspace: [UInt32: [String]] = [:]
    /// `[*]`: what a workspace with no section of its own shows. Nil is the
    /// built-in set.
    public var defaults: [String]?

    /// A few of the desktop's own applications — the ones a desk is not
    /// usable without. Programs that come with the desktop, so they can be
    /// started from beside the dock even without a desktop entry.
    public static let builtInDefaults = ["LavaTerm", "LavaExplorer", "LavaEditor", "LavaWeather", "LavaPass", "LavaSettings"]

    /// Defaults this machine cannot start — no desktop entry, no program
    /// beside the dock. Left out of what a workspace shows, so a default that
    /// was never installed is not an icon that does nothing. Never saved: it
    /// is a fact about this install, not a preference.
    public var unavailable: Set<String> = []

    public init(byWorkspace: [UInt32: [String]] = [:], defaults: [String]? = nil) {
        self.byWorkspace = byWorkspace
        self.defaults = defaults
    }

    /// What a workspace with no section shows.
    public var fallback: [String] {
        (defaults ?? Self.builtInDefaults).filter { !unavailable.contains($0) }
    }

    /// Whether `workspace` has pins of its own, as opposed to the defaults.
    public func hasOwnPins(on workspace: UInt32) -> Bool {
        byWorkspace[workspace] != nil
    }

    public static var defaultPath: String {
        let env = ProcessInfo.processInfo.environment
        let root = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (env["HOME"] ?? NSHomeDirectory()) + "/.config"
        return root + "/lava/dock-pins"
    }

    public static func load(from path: String = defaultPath) -> DockPins {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else {
            return DockPins()
        }
        return parse(text)
    }

    public static func parse(_ text: String) -> DockPins {
        var byWorkspace: [UInt32: [String]] = [:]
        var defaults: [String]?
        // Which section the lines below belong to: a workspace, or `[*]`.
        enum Section { case workspace(UInt32), defaults }
        var current: Section?

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if isDefaultsHeader(line) {
                current = .defaults
                if defaults == nil { defaults = [] }
                continue
            }
            if let ws = workspaceHeader(line) {
                current = .workspace(ws)
                if byWorkspace[ws] == nil { byWorkspace[ws] = [] }
                continue
            }
            guard canPin(line) else { continue }
            switch current {
            case .workspace(let ws):
                if !(byWorkspace[ws] ?? []).contains(line) { byWorkspace[ws, default: []].append(line) }
            case .defaults:
                if !(defaults ?? []).contains(line) { defaults?.append(line) }
            case nil:
                continue
            }
        }
        return DockPins(byWorkspace: byWorkspace, defaults: defaults)
    }

    public func save(to path: String = defaultPath) {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        let temp = path + ".tmp-\(ProcessInfo.processInfo.processIdentifier)"
        do {
            try Data(serialized.utf8).write(
                to: URL(fileURLWithPath: temp), options: .atomic
            )
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            try FileManager.default.moveItem(atPath: temp, toPath: path)
        } catch {
            try? FileManager.default.removeItem(atPath: temp)
            FileHandle.standardError.write(
                Data("dock pins: \(error.localizedDescription)\n".utf8)
            )
        }
    }

    public var serialized: String {
        let keys = byWorkspace.keys.sorted()
        guard !keys.isEmpty || defaults != nil else { return "" }
        var lines = [
            "# lava dock pins, per workspace",
            "# [N] is workspace N; an empty section is no pins. A workspace with",
            "# no section shows [*], or the desktop's defaults when there is none.",
        ]
        if let defaults {
            lines.append("")
            lines.append("[*]")
            lines.append(contentsOf: defaults)
        }
        for ws in keys {
            lines.append("")
            lines.append("[\(ws)]")
            for id in byWorkspace[ws] ?? [] { lines.append(id) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The pins `workspace` shows: its own, or the defaults. Pinning,
    /// unpinning and reordering start from this, so the first change on a
    /// workspace showing the defaults keeps the rest of them — it becomes a
    /// section of its own with the defaults in it, changed.
    public func ids(on workspace: UInt32) -> [String] {
        byWorkspace[workspace] ?? fallback
    }

    public func contains(_ id: String, on workspace: UInt32) -> Bool {
        ids(on: workspace).contains(id)
    }

    public mutating func setIds(_ ids: [String], on workspace: UInt32) {
        var seen = Set<String>()
        byWorkspace[workspace] = ids.filter {
            DockPins.canPin($0) && seen.insert($0).inserted
        }
    }

    public mutating func pin(_ id: String, on workspace: UInt32, at index: Int? = nil) {
        guard DockPins.canPin(id) else { return }
        var ids = ids(on: workspace)
        ids.removeAll { $0 == id }
        if let index {
            ids.insert(id, at: min(max(0, index), ids.count))
        } else {
            ids.append(id)
        }
        byWorkspace[workspace] = ids
    }

    public mutating func unpin(_ id: String, on workspace: UInt32) {
        var ids = ids(on: workspace)
        ids.removeAll { $0 == id }
        byWorkspace[workspace] = ids
    }

    /// `[*]`, with optional spaces.
    static func isDefaultsHeader(_ line: String) -> Bool {
        guard line.first == "[", line.last == "]" else { return false }
        return line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces) == "*"
    }

    /// `[N]` with optional spaces. Anything else is an app id.
    static func workspaceHeader(_ line: String) -> UInt32? {
        guard line.first == "[", line.last == "]" else { return nil }
        let inner = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty, inner.allSatisfy(\.isNumber) else { return nil }
        return UInt32(inner)
    }

    /// Anonymous windows have no desktop identity to remember.
    public static func canPin(_ id: String) -> Bool {
        !id.isEmpty && !id.hasPrefix("window:") && workspaceHeader(id) == nil
            && !isDefaultsHeader(id)
    }
}
