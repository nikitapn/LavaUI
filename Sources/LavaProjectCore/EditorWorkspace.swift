import Foundation

/// Disk-backed editor state. Expanded folders use the tree's project-relative
/// keys; the other paths are absolute in memory and in the implicit session.
public struct EditorSessionSnapshot: Codable, Equatable, Sendable {
    public struct Position: Codable, Equatable, Sendable {
        public var scrollX: Float
        public var scrollY: Double
        public var anchor: Int
        public var focus: Int
        public var topOffset: Int?
        public var topFraction: Float?

        public init(scrollX: Float = 0, scrollY: Double = 0, anchor: Int = 0,
                    focus: Int = 0, topOffset: Int? = nil, topFraction: Float? = nil) {
            self.scrollX = scrollX
            self.scrollY = scrollY
            self.anchor = anchor
            self.focus = focus
            self.topOffset = topOffset
            self.topFraction = topFraction
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            scrollX = try values.decodeIfPresent(Float.self, forKey: .scrollX) ?? 0
            scrollY = try values.decodeIfPresent(Double.self, forKey: .scrollY) ?? 0
            anchor = try values.decodeIfPresent(Int.self, forKey: .anchor) ?? 0
            focus = try values.decodeIfPresent(Int.self, forKey: .focus) ?? anchor
            topOffset = try values.decodeIfPresent(Int.self, forKey: .topOffset)
            topFraction = try values.decodeIfPresent(Float.self, forKey: .topFraction)
        }
    }

    public struct File: Codable, Equatable, Sendable {
        public var path: String
        public var position: Position?

        public init(path: String, position: Position? = nil) {
            self.path = path
            self.position = position
        }
    }

    public var files: [File]
    public var activePath: String?
    public var fontSize: Int?
    public var projectRoot: String?
    public var expandedFolders: [String]?
    public var showsSidebar: Bool?
    public var sidebarFraction: Float?

    public init(files: [File] = [], activePath: String? = nil, fontSize: Int? = nil,
                projectRoot: String? = nil, expandedFolders: [String]? = nil,
                showsSidebar: Bool? = nil, sidebarFraction: Float? = nil) {
        self.files = files
        self.activePath = activePath
        self.fontSize = fontSize
        self.projectRoot = projectRoot
        self.expandedFolders = expandedFolders
        self.showsSidebar = showsSidebar
        self.sidebarFraction = sidebarFraction
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        files = try values.decodeIfPresent([File].self, forKey: .files) ?? []
        activePath = try values.decodeIfPresent(String.self, forKey: .activePath)
        fontSize = try values.decodeIfPresent(Int.self, forKey: .fontSize)
        projectRoot = try values.decodeIfPresent(String.self, forKey: .projectRoot)
        expandedFolders = try values.decodeIfPresent([String].self, forKey: .expandedFolders)
        showsSidebar = try values.decodeIfPresent(Bool.self, forKey: .showsSidebar)
        sidebarFraction = try values.decodeIfPresent(Float.self, forKey: .sidebarFraction)
    }

    fileprivate func mappingPaths(_ transform: (String) -> String) -> Self {
        var result = self
        result.projectRoot = projectRoot.map(transform)
        result.activePath = activePath.map(transform)
        result.files = files.map { File(path: transform($0.path), position: $0.position) }
        return result
    }
}

public enum EditorWorkspace {
    public static let pathExtension = "lava-workspace"

    public static func encode(_ snapshot: EditorSessionSnapshot, at workspace: URL) throws -> Data {
        let directory = workspace.standardizedFileURL.deletingLastPathComponent().pathComponents
        let project = snapshot.projectRoot.map { absoluteURL($0).pathComponents }
        let relative = snapshot.mappingPaths { path in
            guard path.hasPrefix("/") else { return path }
            let url = absoluteURL(path)
            let target = url.pathComponents
            let inProject = project.map {
                directory.starts(with: $0) && target.starts(with: $0)
            } ?? false
            // Keep unrelated files absolute. A workspace inside the project may
            // reach up to its root or across to a sibling folder in the checkout.
            guard target.starts(with: directory) || inProject else { return url.path }
            let common = zip(directory, target).prefix { $0 == $1 }.count
            let parts = Array(repeating: "..", count: directory.count - common)
                + Array(target.dropFirst(common))
            return parts.isEmpty ? "." : parts.joined(separator: "/")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(relative)
    }

    public static func decode(_ data: Data, at workspace: URL) throws -> EditorSessionSnapshot {
        let directory = workspace.standardizedFileURL.deletingLastPathComponent()
        return try JSONDecoder().decode(EditorSessionSnapshot.self, from: data).mappingPaths { path in
            guard !path.isEmpty else { return path }
            if path.hasPrefix("/") { return absoluteURL(path).path }
            return directory.appendingPathComponent(path).standardizedFileURL.path
        }
    }

    private static func absoluteURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL
    }
}
