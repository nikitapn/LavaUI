import Foundation

/// The view each folder was last shown in, kept between launches.
///
/// A folder of photographs wants the icon view and a source tree wants the
/// list, and the person browsing knows which is which better than any rule
/// about file types would. So the choice is remembered where it was made:
/// switching the view of a folder records it for that folder, and the next
/// time any tab arrives there — this launch or a later one — it opens that
/// way. A folder never switched follows the tab that walked into it, which is
/// how browsing felt before there was a memory at all.
///
/// Bounded: the oldest choices go once there are `capacity` of them, so a
/// year of browsing does not grow the settings file without end. Order is
/// recency of the *choice*, not of the visit — a folder visited daily but set
/// once a year ago is not more likely to be forgotten than it should be,
/// since it is the choice that would have to be made again.
public struct FolderViewMemory: Codable, Equatable, Sendable {
    public struct Choice: Codable, Equatable, Sendable {
        public var path: String
        public var mode: FileViewMode
    }

    /// Oldest first.
    public private(set) var choices: [Choice] = []
    public static let capacity = 1000

    public init() {}

    public func mode(for folder: String) -> FileViewMode? {
        let path = FolderHistory.normalize(folder)
        return choices.last { $0.path == path }?.mode
    }

    /// Records `mode` for `folder`, as the newest choice.
    public mutating func remember(_ mode: FileViewMode, for folder: String) {
        let path = FolderHistory.normalize(folder)
        choices.removeAll { $0.path == path }
        choices.append(Choice(path: path, mode: mode))
        if choices.count > Self.capacity {
            choices.removeFirst(choices.count - Self.capacity)
        }
    }

    /// A folder renamed or moved keeps its choice, and so does everything
    /// under it.
    public mutating func rebase(from old: String, to new: String) {
        for index in choices.indices {
            choices[index].path = FolderHistory.rebased(choices[index].path, from: old, to: new)
        }
    }
}
