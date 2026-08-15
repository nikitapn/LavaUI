import Foundation

/// A saved set of logs and the rules each is read with.
///
/// **Logs are referenced, not embedded.** A workspace is a few kilobytes
/// sitting next to files that are routinely gigabytes; copying those into it
/// would make saving as slow as the parse it exists to skip, and would leave
/// two versions of a log that a running system is still appending to. The file
/// on disk is the log — this records where it was and what was being asked of
/// it.
///
/// **Rules are embedded.** They are small, and they are the part that only
/// exists here: a log can always be reopened, but the afternoon spent working
/// out which regex pulls the latency number out of it cannot.
///
/// Reading is deliberately tolerant. A workspace outlives the logs it points
/// at — they get rotated, moved, or cleaned up — and one missing file must not
/// cost the user the other nine documents and their rules. `read` therefore
/// only fails when the *workspace* is unreadable; whether each log still
/// exists is the caller's problem to report, one document at a time.
public struct Workspace: Codable, Equatable, Sendable {
    /// Bumped when a change cannot be expressed as new optional fields.
    /// Anything additive stays at 1 and older files keep loading.
    public static let currentVersion = 1
    public static let fileExtension = "traceloom"

    public var version: Int
    public var documents: [WorkspaceDocument]
    /// Which document was in front. Out-of-range values are clamped on load
    /// rather than rejected — an index is a convenience, not a contract.
    public var activeIndex: Int

    public init(
        version: Int = Workspace.currentVersion,
        documents: [WorkspaceDocument],
        activeIndex: Int = 0
    ) {
        self.version = version
        self.documents = documents
        self.activeIndex = activeIndex.clamped(to: documents.indices)
    }

    public enum LoadError: Error, CustomStringConvertible, Equatable {
        case unreadable(path: String, underlying: String)
        case malformed(path: String, underlying: String)
        case unsupportedVersion(path: String, version: Int, supported: Int)

        public var description: String {
            switch self {
            case let .unreadable(path, underlying):
                return "Could not read \(path): \(underlying)"
            case let .malformed(path, underlying):
                return "\(path) is not a TraceLoom workspace: \(underlying)"
            case let .unsupportedVersion(path, version, supported):
                return "\(path) is a version \(version) workspace; "
                    + "this TraceLoom reads up to version \(supported)"
            }
        }
    }

    public enum SaveError: Error, CustomStringConvertible, Equatable {
        case unwritable(path: String, underlying: String)

        public var description: String {
            switch self {
            case let .unwritable(path, underlying):
                return "Could not write \(path): \(underlying)"
            }
        }
    }

    public static func read(at url: URL) throws -> Workspace {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.unreadable(path: url.path, underlying: error.localizedDescription)
        }
        return try decode(data, path: url.path)
    }

    /// Split from `read` so the format can be tested without a filesystem.
    public static func decode(_ data: Data, path: String = "<data>") throws -> Workspace {
        let decoded: Workspace
        do {
            decoded = try JSONDecoder().decode(Workspace.self, from: data)
        } catch {
            throw LoadError.malformed(path: path, underlying: "\(error)")
        }
        guard decoded.version <= currentVersion else {
            throw LoadError.unsupportedVersion(
                path: path, version: decoded.version, supported: currentVersion
            )
        }
        return Workspace(
            version: decoded.version,
            documents: decoded.documents,
            activeIndex: decoded.activeIndex
        )
    }

    public func write(to url: URL) throws {
        let data: Data
        do {
            data = try encoded()
        } catch {
            throw SaveError.unwritable(path: url.path, underlying: "\(error)")
        }
        do {
            // Atomically: a workspace is usually saved over the one currently
            // open, and a half-written file would take the rules with it.
            try data.write(to: url, options: .atomic)
        } catch {
            throw SaveError.unwritable(path: url.path, underlying: error.localizedDescription)
        }
    }

    /// Pretty-printed with sorted keys: a workspace is a small text file that
    /// people put in a repository next to the logs' analysis, and a diff of one
    /// should show the rule that changed rather than a reordered blob.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// One log in a workspace: where it is, how it is parsed, and where the user
/// was looking when they left it.
public struct WorkspaceDocument: Codable, Equatable, Sendable {
    /// Tab title. Usually the file's last path component, but kept separately
    /// so two `app.log`s from different directories can be told apart.
    public var name: String
    public var path: String
    public var rules: String
    /// Timeline domain, nil for "fit everything".
    public var zoomStart: Double?
    public var zoomEnd: Double?
    /// Where the log editor was. Absent in a workspace written before this
    /// existed, and for a document that was never opened.
    public var position: Position?

    public init(
        name: String,
        path: String,
        rules: String,
        zoomStart: Double? = nil,
        zoomEnd: Double? = nil,
        position: Position? = nil
    ) {
        self.name = name
        self.path = path
        self.rules = rules
        self.zoomStart = zoomStart
        self.zoomEnd = zoomEnd
        self.position = position
    }

    /// Scroll offsets and selection, in the same units LavaUI's
    /// `EditorPosition` uses — restated here because `TraceLoomCore` knows
    /// nothing about the UI, and a file format should not change because a
    /// widget did.
    public struct Position: Codable, Equatable, Sendable {
        public var scrollX: Float
        public var scrollY: Float
        public var anchor: Int
        public var focus: Int

        public init(scrollX: Float, scrollY: Float, anchor: Int, focus: Int) {
            self.scrollX = scrollX
            self.scrollY = scrollY
            self.anchor = anchor
            self.focus = focus
        }
    }
}

extension Int {
    fileprivate func clamped(to range: Range<Int>) -> Int {
        guard !range.isEmpty else { return 0 }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound - 1)
    }
}
