/// Which files to fill the semantic-token cache for first, while the editor
/// is idle: those most likely to be opened next.
public enum SemanticTokenWarmup {
    /// `files` reordered: the paths of the session's tabs first, in their
    /// order — a tab not yet shown is the likeliest next — then the files
    /// beside them, then the rest by path. Each path once; a tab outside
    /// `files` is kept, since being a tab is reason enough.
    public static func order(files: [String], tabs: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(files.count + tabs.count)
        func add(_ path: String) { if seen.insert(path).inserted { result.append(path) } }
        tabs.forEach(add)
        let folders = Set(tabs.map(folder))
        let sorted = files.sorted()
        for path in sorted where folders.contains(folder(of: path)) { add(path) }
        sorted.forEach(add)
        return result
    }

    private static func folder(of path: String) -> Substring {
        path.lastIndex(of: "/").map { path[..<$0] } ?? ""
    }
}
