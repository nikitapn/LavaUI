import Foundation

// OS drag-and-drop onto a view (`.onDrop { paths in ... }`).
//
// Delivery is a `DropRouter` lookup at the moment a `.fileDrop` `InputEvent`
// arrives (see `LavaApp.run`), resolved the same way hover is — the node
// under the cursor when the files were released.

#if canImport(CYoga)

/// Registers `perform` as the drop handler for the content's root layout box.
public struct DropTargetView<Content: View>: PrimitiveView {
    public var perform: ([URL]) -> Void
    public var content: Content

    public init(perform: @escaping ([URL]) -> Void, content: Content) {
        self.perform = perform
        self.content = content
    }

    public var dumpDetail: String { "onDrop" }

    public func structureLines(indent: Int = 0) -> [String] {
        Dump.structureLines(
            indent: indent,
            label: "DropTarget",
            childLines: [content.structureLines(indent: indent + 1)]
        )
    }

    public func mountPrimitive() -> any AnyViewNode {
        stamp(ViewGraph.mount(content))
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        // Wrapper created for fragment content.
        if let box = node as? StyleBoxNode, box.label == "DropTarget" {
            box.updateContent(ViewGraph.reconcile(box.contentNode, with: content))
            DropRouter.register(box.id) { [perform] in perform($0.map(URL.init(fileURLWithPath:))) }
            return box
        }
        // Content was a single box we stamped last time.
        return stamp(ViewGraph.reconcile(node, with: content))
    }

    private func stamp(_ node: any AnyViewNode) -> any AnyViewNode {
        let box: YogaBoxNode
        if let existing = node as? YogaBoxNode {
            box = existing
        } else {
            // Fragment: wrap once so a single box carries the registration,
            // same as `.agentId(_:)` and `.theme(_:)`.
            let wrapper = StyleBoxNode(content: node)
            wrapper.label = "DropTarget"
            box = wrapper
        }
        DropRouter.register(box.id) { [perform] in perform($0.map(URL.init(fileURLWithPath:))) }
        return box
    }
}

extension View {
    /// Runs `perform` with the dropped file paths (as `URL`s) when the user
    /// releases an OS drag over this view.
    public func onDrop(perform: @escaping ([URL]) -> Void) -> DropTargetView<Self> {
        DropTargetView(perform: perform, content: self)
    }
}

#else

extension View {
    /// No-op without Yoga (stubs).
    public func onDrop(perform: @escaping ([URL]) -> Void) -> Self { self }
}

#endif
