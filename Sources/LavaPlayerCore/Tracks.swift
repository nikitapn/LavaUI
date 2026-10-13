import Foundation

/// One stream of the playing file, as mpv's `track-list` describes it.
///
/// Plain values, so the menu's wording and order can be tested without mpv:
/// the app turns mpv's node tree into these and never looks at it again.
public struct Track: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case video, audio, subtitle = "sub"
    }

    /// mpv's id, per kind: what `sid` / `aid` are set to.
    public var id: Int
    public var kind: Kind
    public var title: String?
    /// A language tag as the container spells it — `eng`, `en`, `pt-BR`.
    public var language: String?
    public var codec: String?
    /// Loaded from a file of its own rather than muxed into the video.
    public var isExternal: Bool
    public var isSelected: Bool
    public var isDefault: Bool
    public var isForced: Bool

    public init(
        id: Int, kind: Kind, title: String? = nil, language: String? = nil,
        codec: String? = nil, isExternal: Bool = false, isSelected: Bool = false,
        isDefault: Bool = false, isForced: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.language = language
        self.codec = codec
        self.isExternal = isExternal
        self.isSelected = isSelected
        self.isDefault = isDefault
        self.isForced = isForced
    }

    /// What a menu row says: the language and the title, whichever exist,
    /// then what is worth knowing when two rows would otherwise read alike.
    ///
    /// `English — SDH`, `Commentary`, `Track 3`. A title that only repeats
    /// the language (`English` on an `eng` track) is said once.
    public var label: String {
        let language = language.flatMap(Self.languageName)
        var title = title?.trimmingCharacters(in: .whitespaces)
            .nilIfEmpty
        // mpv titles a file's track with the rest of its name — `de.srt`
        // beside `Movie.mkv` — which says nothing the language and "file"
        // do not. Kept when there is no language: then it is all there is.
        if isExternal, language != nil {
            title = nil
        }
        var parts: [String] = []
        if let language { parts.append(language) }
        if let title, title.caseInsensitiveCompare(language ?? "") != .orderedSame {
            parts.append(title)
        }
        var text = parts.isEmpty ? "Track \(id)" : parts.joined(separator: " — ")
        var notes: [String] = []
        if isForced { notes.append("forced") }
        if isExternal { notes.append("file") }
        if !notes.isEmpty { text += " (\(notes.joined(separator: ", ")))" }
        return text
    }

    /// `eng` → `English`, through the system's own names; a tag it does not
    /// know is shown as it is rather than dropped.
    static func languageName(_ tag: String) -> String? {
        let tag = tag.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty, tag != "und" else { return nil }
        let locale = Locale(identifier: "en")
        if let name = locale.localizedString(forIdentifier: tag) { return name }
        return tag
    }
}

extension Array where Element == Track {
    public func of(_ kind: Track.Kind) -> [Track] { filter { $0.kind == kind } }

    /// The id of the selected track of `kind`, or nil for none.
    public func selected(_ kind: Track.Kind) -> Int? {
        first { $0.kind == kind && $0.isSelected }?.id
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
