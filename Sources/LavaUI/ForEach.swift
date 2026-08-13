/// Variable-length children with **explicit** key identity.
/// Fragment: children splice into the parent (inherits row/column).
/// No `buildArray` — plain `for` in builders is intentionally unsupported.
///
/// **Children are built in `init`, not at mount time.** That is a correctness
/// decision, not a performance one, and it is the whole reason this type looks
/// the way it does.
///
/// `ViewNode.computeBody` evaluates `view.body` inside
/// `withObservationTracking`, so a read registers a dependency only if it
/// happens while that call runs. When this type stored its content as an
/// `@escaping` closure and called it later — during mount and reconcile — every
/// observable read inside that closure landed outside the tracking scope and
/// subscribed to nothing. A row written as
///
/// ```swift
/// ForEach(fits, id: \.value) { fit in
///     PickerRow(..., selected: store.fit == fit.value)   // registers nothing
/// }
/// ```
///
/// drew the right answer once and then never updated, while the same
/// comparison hoisted into `body` worked. LavaSettings shipped that bug on its
/// Background page: the wallpaper changed and the radio button did not move.
///
/// Deferring the closure could not be fixed by tracking it separately. The
/// closure captures the enclosing body's locals and `data` came from that body
/// too, so `ForEachFragmentNode` cannot regenerate children on its own — the
/// only correct response to such a dependency changing is "run the parent body
/// again", which is exactly what registering during the parent body already
/// means. Building here makes the reads happen in the parent body, where they
/// belong, and the trap becomes unwriteable rather than merely documented.
///
/// The cost is that every element's *view value* is built on each body pass.
/// Those are cheap structs; the retained work — nodes, Yoga, draw lists — is
/// still reconciled by key below, not rebuilt. Nothing in this repo feeds an
/// unbounded collection through here: the long lists cap themselves first
/// (`prefix(visibleLimit)`), and a terminal's scrollback or an editor's lines
/// never take this path at all.
public struct ForEach<
    Data: RandomAccessCollection,
    ID: Hashable,
    Content: View
>: PrimitiveView {
    /// One built child per element, in order, with the key it is identified by.
    public var rows: [(id: ID, content: Content)]

    public init(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        @ViewBuilder content: (Data.Element) -> Content
    ) {
        rows = data.map { (id: $0[keyPath: id], content: content($0)) }
    }

    public var dumpDetail: String { "[\(rows.count) keyed]" }

    public func structureLines(indent: Int = 0) -> [String] {
        Dump.structureLines(
            indent: indent,
            label: "ForEach[\(rows.count)]",
            childLines: rows.map { $0.content.structureLines(indent: indent + 1) }
        )
    }

    public func mountPrimitive() -> any AnyViewNode {
        let node = ForEachFragmentNode<ID>()
        node.update(rows: rows)
        return node
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let fe = node as? ForEachFragmentNode<ID> else {
            return mountPrimitive()
        }
        fe.update(rows: rows)
        return fe
    }
}

extension ForEach where Data.Element: Identifiable, ID == Data.Element.ID {
    public init(
        _ data: Data,
        @ViewBuilder content: (Data.Element) -> Content
    ) {
        self.init(data, id: \.id, content: content)
    }
}
