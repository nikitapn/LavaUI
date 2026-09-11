import Foundation

// OS drag-and-drop onto a view (`.onDrop { paths in ... }`).
//
// Delivery is a `DropRouter` lookup at the moment a `.fileDrop` `InputEvent`
// arrives (see `LavaApp.run`), resolved the same way hover is — the node
// under the cursor when the files were released. While the drag is still in
// the air, `.dragOver` events resolve the same way and drive `targeted` and
// `springLoaded`.

#if canImport(CYoga)

/// Where the paths for a `.fileDrop` come from.
///
/// The same shape as `ClipboardBridge` and for the same reason: a windowed app
/// asks its own engine, and a client has no window to ask. The event itself
/// crosses the wire unchanged — it is the variable-length payload that needs
/// a call of its own, which `LavaClient` installs here.
///
/// Unset means windowed, which is why the fallback is the engine rather than
/// an empty list: an app that never heard of a compositor should not have to
/// install anything.
public enum DropBridge {
    nonisolated(unsafe) public static var provider: (@Sendable (UInt32) -> [String])?

    static func paths(window: WindowID, editor: Editor) -> [String] {
        if let provider { return provider(window.raw) }
        return editor.droppedFiles(window: window)
    }
}

/// Registers `perform` as the drop handler for the content's root layout box.
public struct DropTargetView<Content: View>: PrimitiveView {
    public var perform: ([URL]) -> Void
    public var targeted: ((Bool) -> Void)?
    public var springLoaded: (() -> Void)?
    public var content: Content

    public init(perform: @escaping ([URL]) -> Void, content: Content) {
        self.init(targeted: nil, springLoaded: nil, perform: perform, content: content)
    }

    public init(
        targeted: ((Bool) -> Void)?,
        springLoaded: (() -> Void)?,
        perform: @escaping ([URL]) -> Void,
        content: Content
    ) {
        self.perform = perform
        self.targeted = targeted
        self.springLoaded = springLoaded
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
            register(box.id)
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
        register(box.id)
        return box
    }

    private func register(_ id: NodeID) {
        let perform = self.perform
        DropRouter.register(
            id,
            hover: DropRouter.Hover(targeted: targeted, springLoaded: springLoaded)
        ) { perform($0.map(URL.init(fileURLWithPath:))) }
    }
}

extension View {
    /// Runs `perform` with the dropped file paths (as `URL`s) when the user
    /// releases an OS drag over this view.
    ///
    /// While a drag is still over it: `targeted` hears `true` as the drag
    /// becomes aimed at this view and `false` as it leaves, is dropped, or
    /// ends elsewhere — the place to light a target up. `springLoaded` runs
    /// once the drag has rested here for `DropRouter.springDelay`, the way a
    /// tab or a folder opens under a file being carried to it. Both need a
    /// compositor to say where a drag is; a windowed app gets the drop alone.
    ///
    /// Nested targets resolve innermost first, like the drop itself: a folder
    /// row inside a list is its own target, a file row is not and the list
    /// behind it answers.
    public func onDrop(
        targeted: ((Bool) -> Void)? = nil,
        springLoaded: (() -> Void)? = nil,
        perform: @escaping ([URL]) -> Void
    ) -> DropTargetView<Self> {
        DropTargetView(
            targeted: targeted, springLoaded: springLoaded, perform: perform, content: self
        )
    }
}

#else

extension View {
    /// No-op without Yoga (stubs).
    public func onDrop(
        targeted: ((Bool) -> Void)? = nil,
        springLoaded: (() -> Void)? = nil,
        perform: @escaping ([URL]) -> Void
    ) -> Self { self }
}

#endif
