import Foundation

/// Ordered app ids the user asked the dock to keep, **per workspace**.
///
/// A work desk and a home desk do not want the same pins. The file is
/// still a preference: missing or unreadable is an empty dock, not a
/// crash. A `[N]` section is workspace N; workspaces with no section
/// have no pins.
struct DockPins: Equatable {
    var byWorkspace: [UInt32: [String]] = [:]

    static var defaultPath: String {
        let env = ProcessInfo.processInfo.environment
        let root = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (env["HOME"] ?? NSHomeDirectory()) + "/.config"
        return root + "/lava/dock-pins"
    }

    static func load(from path: String = defaultPath) -> DockPins {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else {
            return DockPins()
        }
        return parse(text)
    }

    static func parse(_ text: String) -> DockPins {
        var byWorkspace: [UInt32: [String]] = [:]
        var current: UInt32?
        var seenByWorkspace: [UInt32: Set<String>] = [:]

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if let ws = workspaceHeader(line) {
                current = ws
                if byWorkspace[ws] == nil {
                    byWorkspace[ws] = []
                    seenByWorkspace[ws] = []
                }
                continue
            }
            guard let ws = current, canPin(line) else { continue }
            var seen = seenByWorkspace[ws] ?? []
            guard seen.insert(line).inserted else { continue }
            seenByWorkspace[ws] = seen
            byWorkspace[ws, default: []].append(line)
        }
        return DockPins(byWorkspace: byWorkspace)
    }

    func save(to path: String = defaultPath) {
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

    var serialized: String {
        let keys = byWorkspace.keys.sorted()
        guard !keys.isEmpty else { return "" }
        var lines = [
            "# lava dock pins, per workspace",
            "# [N] is workspace N. A workspace with no section has no pins.",
        ]
        for ws in keys {
            lines.append("")
            lines.append("[\(ws)]")
            for id in byWorkspace[ws] ?? [] { lines.append(id) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func ids(on workspace: UInt32) -> [String] {
        byWorkspace[workspace] ?? []
    }

    func contains(_ id: String, on workspace: UInt32) -> Bool {
        ids(on: workspace).contains(id)
    }

    mutating func setIds(_ ids: [String], on workspace: UInt32) {
        var seen = Set<String>()
        byWorkspace[workspace] = ids.filter {
            DockPins.canPin($0) && seen.insert($0).inserted
        }
    }

    mutating func pin(_ id: String, on workspace: UInt32, at index: Int? = nil) {
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

    mutating func unpin(_ id: String, on workspace: UInt32) {
        var ids = ids(on: workspace)
        ids.removeAll { $0 == id }
        byWorkspace[workspace] = ids
    }

    /// `[N]` with optional spaces. Anything else is an app id.
    static func workspaceHeader(_ line: String) -> UInt32? {
        guard line.first == "[", line.last == "]" else { return nil }
        let inner = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty, inner.allSatisfy(\.isNumber) else { return nil }
        return UInt32(inner)
    }

    /// Anonymous windows have no desktop identity to remember.
    static func canPin(_ id: String) -> Bool {
        !id.isEmpty && !id.hasPrefix("window:") && workspaceHeader(id) == nil
    }
}
