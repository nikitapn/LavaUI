/// The details list's column widths, and what dragging an edge between two
/// columns does to them.
///
/// Name takes whatever is left, so only Size and Modified are stored. An edge
/// follows the pointer: the one left of Size moves the boundary between Name
/// and Size, and the one left of Modified trades width between Size and
/// Modified — Modified sits against the right edge and has nowhere else to go.
public struct ListColumns: Equatable, Sendable {
    public enum Edge: Sendable { case nameSize, sizeModified }

    public static let minimumWidth: Float = 48
    public static let minimumNameWidth: Float = 96

    public var size: Float
    public var modified: Float

    public init(size: Float = 88, modified: Float = 148) {
        self.size = size
        self.modified = modified
    }

    /// These widths with `edge` moved `dx` to the right. `nameRoom` is what
    /// Name and the two stored columns share, spacing already taken out; nil
    /// before the list has been laid out, when only the minimums apply.
    public func dragging(_ edge: Edge, by dx: Float, nameRoom: Float?) -> ListColumns {
        var next = self
        switch edge {
        case .nameSize:
            var grown = size - dx
            if let room = nameRoom {
                grown = min(grown, room - modified - Self.minimumNameWidth)
            }
            next.size = max(Self.minimumWidth, grown)
        case .sizeModified:
            let shift = min(max(dx, Self.minimumWidth - size), modified - Self.minimumWidth)
            next.size = size + shift
            next.modified = modified - shift
        }
        return next
    }
}
