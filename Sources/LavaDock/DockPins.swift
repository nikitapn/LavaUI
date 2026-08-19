import Foundation

/// Ordered app ids the user asked the dock to keep.
///
/// One id per line, top to bottom is left to right. Missing or unreadable
/// is an empty dock, not a crash — a pin file is a preference, and a
/// corrupt one must not take the running applications with it.
struct DockPins: Equatable {
    var ids: [String]

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
            return DockPins(ids: [])
        }
        var seen = Set<String>()
        var ids: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let id = line.trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !id.hasPrefix("#"), !seen.contains(id) else {
                continue
            }
            seen.insert(id)
            ids.append(id)
        }
        return DockPins(ids: ids)
    }

    func save(to path: String = defaultPath) {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        let body = ids.isEmpty ? "" : ids.joined(separator: "\n") + "\n"
        let temp = path + ".tmp-\(ProcessInfo.processInfo.processIdentifier)"
        do {
            try Data(body.utf8).write(
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

    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    mutating func pin(_ id: String, at index: Int? = nil) {
        guard DockPins.canPin(id) else { return }
        ids.removeAll { $0 == id }
        if let index {
            ids.insert(id, at: min(max(0, index), ids.count))
        } else {
            ids.append(id)
        }
    }

    mutating func unpin(_ id: String) {
        ids.removeAll { $0 == id }
    }

    /// Anonymous windows have no desktop identity to remember.
    static func canPin(_ id: String) -> Bool {
        !id.isEmpty && !id.hasPrefix("window:")
    }
}
