import Foundation

/// The location of a line-end hint from the editor's last draw. The editor
/// scrolls internally, so an overlay reads this instead of the Yoga layout.
public final class EditorLineEndHintAnchor: @unchecked Sendable {
    // Like the editor and detached overlay layout, this is used on the frame loop.
    /// The visible hint rectangle in window coordinates, or nil when hidden.
    public internal(set) var frame: CGRect?
    /// The zero-based logical line the hint was drawn on.
    public internal(set) var line: Int?
    /// The editor's scroll offset when it drew the hint.
    public internal(set) var scroll = CGPoint.zero

    var localFrame: CGRect?
    var isHovered = false

    public init() {}
}

/// Dimmed, single-row text after the last visual row of the caret's logical
/// line. It is ellipsized at the viewport edge and takes no layout space.
public struct EditorLineEndHint {
    let anchor: EditorLineEndHintAnchor
    let text: (Int) -> String?
    let onHover: (Bool) -> Void

    /// `text` is called during drawing with the zero-based logical line.
    /// Return nil to hide the hint. `onHover` reports entry and exit.
    public init(
        anchor: EditorLineEndHintAnchor,
        text: @escaping (Int) -> String?,
        onHover: @escaping (Bool) -> Void = { _ in }
    ) {
        self.anchor = anchor
        self.text = text
        self.onHover = onHover
    }

    func reportHover(_ point: CGPoint?) {
        let inside = point.map { anchor.localFrame?.contains($0) == true } ?? false
        guard anchor.isHovered != inside else { return }
        anchor.isHovered = inside
        onHover(inside)
    }
}
