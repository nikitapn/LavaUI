import Foundation

/// Shared ordering and identity for the editor's folder and workspace histories.
public enum RecentProjectPaths {
    public static func normalized(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var recent: [String] = []
        for path in paths where path.hasPrefix("/") {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seen.insert(standardized).inserted else { continue }
            recent.append(standardized)
            if recent.count == 10 { break }
        }
        return recent
    }

    public static func recording(_ url: URL, in paths: [String]) -> [String] {
        normalized([url.path] + paths)
    }
}
