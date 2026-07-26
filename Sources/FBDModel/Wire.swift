/// Connects exactly one output slot to exactly one input slot.
///
/// Deliberately pure data — no geometry. The original C++ model's `CLine`
/// bundled the connection together with its bezier-curve rendering cache;
/// keeping those separate here means the rendering layer can route wires
/// however it likes (orthogonal, curved, whatever) purely from `from`/`to`
/// slot positions, without the data model needing to know or care.
public struct Wire: Identifiable, Sendable {
    public let id: WireID
    /// Must reference an output slot.
    public var from: SlotID
    /// Must reference an input slot. A `Diagram` enforces at most one wire
    /// per input slot (an input can't be driven by two sources at once).
    public var to: SlotID

    public init(id: WireID, from: SlotID, to: SlotID) {
        self.id = id
        self.from = from
        self.to = to
    }
}
