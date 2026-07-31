import Foundation

// Explicit stable ids for agent automation (`.agentId("save")`).
//
// Process-local `NodeID` values change every launch and after remounts.
// Author-assigned agent ids do not. Structural path fallbacks (`sid` in the
// layout tree) cover untagged nodes: `0:VStack/0:HStack/3:Text`, with ForEach
// rows keyed as `k:<element-id>`.

#if canImport(CYoga)

/// Attaches a stable agent id to the content's root layout box.
public struct AgentIdentifiedView<Content: View>: PrimitiveView {
    public var agentId: String
    public var content: Content

    public init(agentId: String, content: Content) {
        self.agentId = agentId
        self.content = content
    }

    public var dumpDetail: String { "agentId=\(agentId)" }

    public func structureLines(indent: Int = 0) -> [String] {
        Dump.structureLines(
            indent: indent,
            label: "AgentId \"\(agentId)\"",
            childLines: [content.structureLines(indent: indent + 1)]
        )
    }

    public func mountPrimitive() -> any AnyViewNode {
        stamp(ViewGraph.mount(content))
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        // Wrapper *we* created for fragment content — `label` is only ever
        // "AgentId" via `stamp`'s wrap branch below, so this can't fire for
        // a box some other modifier owns (see the crash this replaced).
        if let box = node as? StyleBoxNode, box.label == "AgentId" {
            box.updateContent(ViewGraph.reconcile(box.contentNode, with: content))
            box.agentId = agentId
            return box
        }
        // Content was a single box last time — possibly one we merely
        // stamped an id onto (not wrapped), which another modifier (say,
        // `.padding(_:)`'s `ModifiedView`) still owns the reconciliation
        // contract for. `agentId != nil` alone used to be treated as proof
        // *we* owned it, which was true only when we had also wrapped it;
        // stamped-not-wrapped boxes have a non-nil `agentId` too, and
        // reconciling `box.contentNode` directly against our `content` (one
        // layer higher than what that box actually holds) fed the wrong
        // view into the wrong node — `ModifiedView`, still expecting to
        // reconcile its own box, saw a stranger and wrapped it again,
        // inserting an already-parented Yoga child into a second parent.
        // Going through `ViewGraph.reconcile` here instead lets whichever
        // type actually owns `node` handle it correctly.
        let next = ViewGraph.reconcile(node, with: content)
        return stamp(next)
    }

    private func stamp(_ node: any AnyViewNode) -> any AnyViewNode {
        if let box = node as? YogaBoxNode {
            box.agentId = agentId
            return box
        }
        // Fragment: wrap once so a single box carries the id (same as style).
        let wrapper = StyleBoxNode(content: node)
        wrapper.agentId = agentId
        wrapper.label = "AgentId"
        return wrapper
    }
}

extension View {
    /// Stable automation id for agents (`layout_tree` → `sid`, `click --sid`, …).
    ///
    /// Prefer short kebab-case names (`theme-toggle`, `sidebar-nav`). When set,
    /// this wins over the structural path fallback.
    public func agentId(_ id: String) -> AgentIdentifiedView<Self> {
        AgentIdentifiedView(agentId: id, content: self)
    }
}

extension AgentIdentifiedView {
    /// Collapse `.agentId("a").agentId("b")` → outer id wins (last in chain).
    public func agentId(_ id: String) -> AgentIdentifiedView<Content> {
        AgentIdentifiedView(agentId: id, content: content)
    }
}

#else

extension View {
    /// No-op without Yoga (stubs).
    public func agentId(_ id: String) -> Self { self }
}

#endif
