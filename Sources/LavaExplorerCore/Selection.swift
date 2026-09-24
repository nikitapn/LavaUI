/// Which rows are selected, the way every file manager's list does it.
///
/// Three things, not one. `paths` is what an operation acts on. `lead` is the
/// row the keyboard is on — where Up and Down move from, what Enter opens —
/// and is always selected when anything is. `anchor` is where a Shift range
/// starts: Shift+click after a click selects everything between the two, and
/// a second Shift+click moves the far end, not the anchor, so a range can be
/// grown and shrunk from the same starting row.
public struct FileSelection: Equatable, Sendable {
    public private(set) var paths: Set<String> = []
    public private(set) var lead: String?
    public private(set) var anchor: String?

    public init() {}

    public var isEmpty: Bool { paths.isEmpty }
    public var count: Int { paths.count }

    public func contains(_ path: String) -> Bool { paths.contains(path) }

    /// A plain click: only this.
    public mutating func select(_ path: String) {
        paths = [path]
        lead = path
        anchor = path
    }

    /// Ctrl+click: in or out, leaving the rest. The row becomes the lead and
    /// the anchor either way, which is what makes Ctrl+click then Shift+click
    /// add a second range rather than extend the first.
    public mutating func toggle(_ path: String) {
        if paths.contains(path) {
            paths.remove(path)
        } else {
            paths.insert(path)
        }
        lead = path
        anchor = path
        if paths.isEmpty { lead = nil }
    }

    /// Shift+click or Shift+arrow: the anchor through `path`, in list order.
    /// With `adding` (Ctrl+Shift) the range joins what was selected; without,
    /// it replaces it.
    public mutating func extend(to path: String, in order: [String], adding: Bool = false) {
        guard let anchor, let from = order.firstIndex(of: anchor),
              let to = order.firstIndex(of: path)
        else {
            select(path)
            return
        }
        let range = order[min(from, to)...max(from, to)]
        paths = adding ? paths.union(range) : Set(range)
        lead = path
    }

    public mutating func selectAll(_ order: [String]) {
        paths = Set(order)
        if lead == nil || !paths.contains(lead!) { lead = order.first }
        if anchor == nil || !paths.contains(anchor!) { anchor = lead }
    }

    public mutating func clear() {
        paths = []
        lead = nil
        anchor = nil
    }

    /// After a reload: whatever is gone from the folder is gone from the
    /// selection too.
    public mutating func keep(only present: Set<String>) {
        paths.formIntersection(present)
        if let lead, !paths.contains(lead) { self.lead = nil }
        if let anchor, !present.contains(anchor) { self.anchor = nil }
        if lead == nil, paths.count == 1 { lead = paths.first }
    }

    /// Every path put through `transform` — for a folder that was renamed or
    /// moved under the rows that are selected.
    public func mapped(_ transform: (String) -> String) -> FileSelection {
        var out = self
        out.paths = Set(paths.map(transform))
        out.lead = lead.map(transform)
        out.anchor = anchor.map(transform)
        return out
    }

    /// The selected paths in the order the list shows them.
    public func ordered(_ order: [String]) -> [String] {
        order.filter { paths.contains($0) }
    }
}
