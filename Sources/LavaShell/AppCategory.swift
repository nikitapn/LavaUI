/// Which shelf of the launcher an application goes on.
///
/// From the freedesktop *main* categories, which every well-formed entry
/// lists, folded into the handful a person actually browses by — nobody looks
/// for "AudioVideo" and "Audio" as two places. One category per application:
/// an entry names several (`Network;WebBrowser`, `Office;Graphics;Viewer`)
/// and a launcher that showed it under each would be a list with duplicates.
public enum AppCategory: String, CaseIterable, Sendable, Hashable {
    case internet
    case multimedia
    case graphics
    case office
    case development
    case games
    case education
    case accessories
    case system
    case other

    public var title: String {
        switch self {
        case .internet: "Internet"
        case .multimedia: "Multimedia"
        case .graphics: "Graphics"
        case .office: "Office"
        case .development: "Development"
        case .games: "Games"
        case .education: "Education"
        case .accessories: "Accessories"
        case .system: "System"
        case .other: "Other"
        }
    }

    /// The one shelf for `categories`, as `Categories=` lists them.
    ///
    /// By precedence, not by the order the entry happens to list them in,
    /// because the ambiguous cases are predictable and the first-listed one is
    /// often the weakest claim: Steam is `Network;FileTransfer;Game` and
    /// belongs with games, LibreOffice Draw is `Office;Graphics` and belongs
    /// with documents, an IDE is often `TextEditor;Development`.
    public static func of(_ categories: [String]) -> AppCategory {
        let set = Set(categories)
        func has(_ names: String...) -> Bool { names.contains(where: set.contains) }
        if has("Game") { return .games }
        if has("Development") { return .development }
        if has("Office") { return .office }
        if has("Graphics") { return .graphics }
        if has("AudioVideo", "Audio", "Video") { return .multimedia }
        if has("Education", "Science") { return .education }
        if has("Network") { return .internet }
        if has("Settings", "System") { return .system }
        if has("Utility") { return .accessories }
        return .other
    }
}

extension DesktopEntry {
    public var category: AppCategory { AppCategory.of(categories) }
}
