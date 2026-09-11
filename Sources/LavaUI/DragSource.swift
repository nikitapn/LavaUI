import Foundation

// Dragging files *out* of a view (`.onFileDrag { chip }`), and the picture
// that follows the pointer while it happens.
//
// The mirror of `DropTarget.swift`. A drop comes in as an event plus a call
// for the paths; a drag goes out as a call — the compositor becomes the
// Wayland drag source, since a client is not a Wayland client and has nothing
// to start one with — and the chip travels on that call as a draw list.

/// A drag chip: views laid out and emitted into a draw list of their own.
///
/// The arrays are canvas's own `DrawCommand`, `GlyphInstance`, `MeshVertex`
/// and `GradientDesc` structs, as bytes. Whoever draws it compiles against
/// the same `draw_command.hpp`, so this is the frame format rather than a new
/// one — and a chip is a few kilobytes, sent once when the drag starts.
///
/// Chip-local: the list is emitted with the chip's top-left at 0,0, and
/// `width` × `height` is what it laid out to, in pixels.
public struct DragChipImage: Sendable, Equatable {
    public var width: UInt32
    public var height: UInt32
    public var commands: [UInt8]
    public var glyphs: [UInt8]
    public var meshVertices: [UInt8]
    public var gradients: [UInt8]

    /// Past this a chip is not sent, and the drag goes ahead with the cursor
    /// alone. Well under the control plane's per-message ceiling; a chip that
    /// big is a window, not a chip.
    public static let maxWireBytes = 256 * 1024

    public var byteCount: Int {
        commands.count + glyphs.count + meshVertices.count + gradients.count
    }
}

/// How a view starts an OS drag.
///
/// `DropBridge`'s shape, facing the other way. Unset means windowed, and there
/// is no engine fallback this time: GLFW can receive a drop but has no way to
/// start one. So a windowed app's `.onFileDrag` does nothing, and the press
/// stays an ordinary press.
public enum DragBridge {
    /// Starts a drag of `paths` with `chip`, if any, hung `offsetX`,`offsetY`
    /// from the pointer, while the button that pressed is still held.
    ///
    /// True when the request was delivered — not that a drag started, which is
    /// the compositor's to decide: the button may already be up, or another
    /// drag running.
    public typealias Provider = (
        _ paths: [String], _ chip: DragChipImage?, _ offsetX: Float, _ offsetY: Float
    ) -> Bool

    nonisolated(unsafe) public static var startFileDrag: Provider?
}

/// When a press on a `.onFileDrag` view becomes a drag.
public enum FileDrag {
    /// Travel, in window pixels, before a press is a drag rather than a click.
    /// GTK's default is 8; a little less suits a list, where the drag is the
    /// point of pressing on a row at all and a lazy one should still start.
    public static let threshold: Float = 6
}

#if canImport(CYoga)
import CxxCanvas
import CYoga

/// One `.onFileDrag` registration.
struct FileDragEntry {
    /// Asked when the drag starts, so it can answer with the selection then.
    let paths: () -> [String]
    /// Mounts the chip's content fresh; nil for a drag with no chip.
    let chip: (() -> any AnyViewNode)?
    let offsetX: Float
    let offsetY: Float
}

/// `.onFileDrag` registrations by node, the way `DropRouter` keeps drops.
enum FileDragRouter {
    nonisolated(unsafe) private static var entries: [NodeID: FileDragEntry] = [:]

    static func register(_ id: NodeID, _ entry: FileDragEntry) { entries[id] = entry }

    static func unregisterAll(ids: Set<NodeID>) {
        for id in ids { entries[id] = nil }
    }

    static func hasSource(_ id: NodeID) -> Bool { entries[id] != nil }

    static func entry(_ id: NodeID) -> FileDragEntry? { entries[id] }
}

/// Registers the content's root layout box as something files can be dragged
/// out of.
public struct FileDragSourceView<Content: View, Chip: View>: PrimitiveView {
    public var paths: () -> [String]
    public var chip: (() -> Chip)?
    public var offsetX: Float
    public var offsetY: Float
    public var content: Content

    public var dumpDetail: String { "onFileDrag" }

    public func structureLines(indent: Int = 0) -> [String] {
        Dump.structureLines(
            indent: indent,
            label: "FileDragSource",
            childLines: [content.structureLines(indent: indent + 1)]
        )
    }

    public func mountPrimitive() -> any AnyViewNode {
        stamp(ViewGraph.mount(content))
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        // Wrapper created for fragment content.
        if let box = node as? StyleBoxNode, box.label == "FileDragSource" {
            box.updateContent(ViewGraph.reconcile(box.contentNode, with: content))
            FileDragRouter.register(box.id, entry)
            return box
        }
        // Content was a single box we stamped last time.
        return stamp(ViewGraph.reconcile(node, with: content))
    }

    private var entry: FileDragEntry {
        let mountChip: (() -> any AnyViewNode)? = chip.map { make in
            { () -> any AnyViewNode in ViewGraph.mount(make()) }
        }
        return FileDragEntry(
            paths: paths, chip: mountChip, offsetX: offsetX, offsetY: offsetY
        )
    }

    private func stamp(_ node: any AnyViewNode) -> any AnyViewNode {
        let box: YogaBoxNode
        if let existing = node as? YogaBoxNode {
            box = existing
        } else {
            // Fragment: wrap once so a single box carries the registration,
            // same as `.onDrop`.
            let wrapper = StyleBoxNode(content: node)
            wrapper.label = "FileDragSource"
            box = wrapper
        }
        FileDragRouter.register(box.id, entry)
        return box
    }
}

extension View {
    /// Lets files be dragged out of this view — onto another window, into
    /// another app, anywhere a `text/uri-list` drop is understood.
    ///
    /// `paths` is asked when the drag starts, not when the view is built, so
    /// it can answer with whatever is selected by then. `chip` is what follows
    /// the pointer: ordinary views, laid out at their natural size and drawn
    /// **once** by the compositor, which then only moves the result (see
    /// `DragChipImage`). It hangs `offsetX`,`offsetY` from the pointer —
    /// below and to the right by default, clear of what is being aimed at.
    ///
    /// The left button only, after `FileDrag.threshold` of travel, and only
    /// where a compositor can carry a drag (`DragBridge`). The press is
    /// delivered as a press either way, so a row selects itself first.
    public func onFileDrag<Chip: View>(
        offsetX: Float = 16,
        offsetY: Float = 12,
        paths: @escaping () -> [String],
        @ViewBuilder chip: @escaping () -> Chip
    ) -> FileDragSourceView<Self, Chip> {
        FileDragSourceView(
            paths: paths, chip: chip, offsetX: offsetX, offsetY: offsetY,
            content: self
        )
    }

    /// The same, with nothing but the cursor to show for it.
    public func onFileDrag(
        paths: @escaping () -> [String]
    ) -> FileDragSourceView<Self, EmptyView> {
        FileDragSourceView(
            paths: paths, chip: nil, offsetX: 0, offsetY: 0, content: self
        )
    }
}

// ─── Capture ────────────────────────────────────────────────────────────────

/// Lays a chip out at its own size and keeps what it draws.
enum DragChipCapture {
    /// Longest side a chip may lay out to, in pixels. A chip names what is
    /// being dragged; much bigger and it covers what it is being dropped on.
    static let maxSide: Float = 480

    static func capture(view: some View, editor: Editor) -> DragChipImage? {
        capture(ViewGraph.mount(view), editor: editor)
    }

    /// `root` is mounted for this and nothing else, and is let go of here.
    static func capture(_ root: any AnyViewNode, editor: Editor) -> DragChipImage? {
        // Whatever the chip registered while mounting — a hover tint, a
        // scroll handler — would otherwise outlive it in routers keyed by id;
        // see `LavaWindow.teardown`, which does the same for a whole window.
        defer { release(root) }
        guard let yoga = root.flattenedLayoutNodes().first?.yoga else { return nil }

        // Natural size, the way an overlay measures itself — a chip decides
        // how big it is, not the window it came from. Unlike an overlay the
        // root is not reset to auto first: it was mounted a moment ago, so
        // any size it has is one its own `.frame` asked for.
        YGNodeStyleSetMaxWidth(yoga, maxSide)
        YGNodeStyleSetMaxHeight(yoga, maxSide)
        YGNodeCalculateLayout(yoga, .nan, .nan, YGDirectionLTR)
        let width = YGNodeLayoutGetWidth(yoga).rounded(.up)
        let height = YGNodeLayoutGetHeight(yoga).rounded(.up)
        guard width.isFinite, height.isFinite, width >= 1, height >= 1 else {
            return nil
        }

        let sink = CapturedFrameSink()
        let list = DrawList(editor: editor, sink: sink)
        list.clear()
        list.emitDetached(root, width: width, height: height)
        list.publish()
        return sink.image(width: UInt32(width), height: UInt32(height))
    }

    private static func release(_ root: any AnyViewNode) {
        var ids: Set<NodeID> = []
        collect(root, into: &ids)
        ScrollRouter.unregisterAll(ids: ids)
        DropRouter.unregisterAll(ids: ids)
        HoverState.unregisterAll(ids: ids)
        FileDragRouter.unregisterAll(ids: ids)
        PointerCapture.discard(ids: ids)
    }

    private static func collect(_ node: any AnyViewNode, into ids: inout Set<NodeID>) {
        ids.insert(node.id)
        for child in node.childNodes { collect(child, into: &ids) }
    }
}

/// Plain memory, for a frame that is read back rather than shown.
///
/// Grows the way the engine's own vectors do, and keeps the prefix across a
/// growth because `DrawList` may be halfway through a frame when it asks.
final class CapturedFrameSink: FrameSink {
    private var commands = UnsafeMutablePointer<canvas.DrawCommand>.allocate(capacity: 1)
    private var glyphs = UnsafeMutablePointer<canvas.GlyphInstance>.allocate(capacity: 1)
    private var meshVertices = UnsafeMutablePointer<canvas.MeshVertex>.allocate(capacity: 1)
    private var spatialVertices =
        UnsafeMutablePointer<canvas.SpatialVertex>.allocate(capacity: 1)
    private var gradients = UnsafeMutablePointer<canvas.GradientDesc>.allocate(capacity: 1)
    private var capacity = FrameCapacity(
        commands: 1, glyphs: 1, meshVertices: 1, spatialVertices: 1, gradients: 1
    )
    /// What the last committed frame filled in.
    private(set) var written = FrameCapacity()

    deinit {
        commands.deallocate()
        glyphs.deallocate()
        meshVertices.deallocate()
        spatialVertices.deallocate()
        gradients.deallocate()
    }

    func beginFrame(minimum: FrameCapacity) -> FrameBuffers? {
        written = FrameCapacity()
        return grow(to: minimum, written: FrameCapacity())
    }

    func grow(to wanted: FrameCapacity, written: FrameCapacity) -> FrameBuffers? {
        Self.reserve(&commands, &capacity.commands, wanted.commands, keeping: written.commands)
        Self.reserve(&glyphs, &capacity.glyphs, wanted.glyphs, keeping: written.glyphs)
        Self.reserve(
            &meshVertices, &capacity.meshVertices, wanted.meshVertices,
            keeping: written.meshVertices
        )
        Self.reserve(
            &spatialVertices, &capacity.spatialVertices, wanted.spatialVertices,
            keeping: written.spatialVertices
        )
        Self.reserve(&gradients, &capacity.gradients, wanted.gradients, keeping: written.gradients)
        return FrameBuffers(
            commands: commands, glyphs: glyphs, meshVertices: meshVertices,
            spatialVertices: spatialVertices, gradients: gradients,
            capacity: capacity
        )
    }

    func commit(_ written: FrameCapacity) {
        self.written = written
    }

    /// The committed frame as a chip. Nil if it drew nothing.
    ///
    /// Spatial vertices stay behind: a 3D scene on a drag chip is not a thing,
    /// and a `SpatialTriangles` command with no vertices to index is skipped
    /// by the renderer's range check rather than drawn wrong.
    func image(width: UInt32, height: UInt32) -> DragChipImage? {
        guard written.commands > 0 else { return nil }
        return DragChipImage(
            width: width, height: height,
            commands: Self.bytes(commands, written.commands),
            glyphs: Self.bytes(glyphs, written.glyphs),
            meshVertices: Self.bytes(meshVertices, written.meshVertices),
            gradients: Self.bytes(gradients, written.gradients)
        )
    }

    private static func reserve<T>(
        _ storage: inout UnsafeMutablePointer<T>, _ capacity: inout Int,
        _ wanted: Int, keeping count: Int
    ) {
        guard wanted > capacity else { return }
        let next = UnsafeMutablePointer<T>.allocate(capacity: wanted)
        next.initialize(from: storage, count: min(count, capacity))
        storage.deallocate()
        storage = next
        capacity = wanted
    }

    private static func bytes<T>(_ storage: UnsafeMutablePointer<T>, _ count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        return Array(
            UnsafeRawBufferPointer(
                start: UnsafeRawPointer(storage),
                count: count * MemoryLayout<T>.stride
            )
        )
    }
}

#else

extension View {
    /// No-op without Yoga (stubs).
    public func onFileDrag<Chip: View>(
        offsetX: Float = 16,
        offsetY: Float = 12,
        paths: @escaping () -> [String],
        @ViewBuilder chip: @escaping () -> Chip
    ) -> Self { self }

    /// No-op without Yoga (stubs).
    public func onFileDrag(paths: @escaping () -> [String]) -> Self { self }
}

#endif
