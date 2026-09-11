import Foundation

// A press that travels — `.onDragGesture { value in }` — its quieter sibling
// `.onAnyPress { }`, which hears every press inside a view without taking it
// from whatever is under the pointer, and `.onFrame { }`, which says where a
// view ended up so a gesture has somewhere to aim.
//
// The first two resolve the way `.onDrop` does, by walking the hit chain
// *outwards* from the press, rather than through the click walk, which stops
// at the innermost handler. That is the point of both. A tab is a stack whose
// own press selects it and whose drag moves it; a pane is a column of rows and
// buttons that each take their own clicks, and the pane still has to learn it
// was clicked in. The click walk can give either of them one handler. The
// chain gives both.

public enum DragGesturePhase: Equatable, Sendable {
    /// The press has travelled `minimumDistance`. Carries where it is now.
    case began
    case changed
    /// Released. Always follows a `.began`.
    case ended
}

public struct DragGestureValue: Equatable, Sendable {
    public var phase: DragGesturePhase
    /// Where the press went down, in window coordinates.
    public var startX: Float
    public var startY: Float
    /// Where the pointer is now, in window coordinates.
    public var x: Float
    public var y: Float

    public var translationX: Float { x - startX }
    public var translationY: Float { y - startY }
}

#if canImport(CYoga)

struct DragGestureEntry {
    let minimumDistance: Float
    let perform: (DragGestureValue) -> Void
}

/// `.onDragGesture` registrations, and the one gesture the pointer is in.
///
/// Process-wide rather than per window for the reason `PointerCapture` is:
/// there is one pointer, and a press belongs to one window at a time.
enum DragGestureRouter {
    nonisolated(unsafe) private static var entries: [NodeID: DragGestureEntry] = [:]
    nonisolated(unsafe) private static var pending: (entry: DragGestureEntry, x: Float, y: Float)?
    nonisolated(unsafe) private static var active: (entry: DragGestureEntry, x: Float, y: Float)?

    static func register(_ id: NodeID, _ entry: DragGestureEntry) { entries[id] = entry }

    static func unregisterAll(ids: Set<NodeID>) {
        for id in ids { entries[id] = nil }
    }

    static func hasGesture(_ id: NodeID) -> Bool { entries[id] != nil }

    static var isActive: Bool { active != nil }

    /// A press went down on `source`, or on nothing that drags.
    static func press(source: NodeID?, x: Float, y: Float) {
        active = nil
        pending = source.flatMap { entries[$0] }.map { ($0, x, y) }
    }

    /// True when this move belongs to a gesture and nothing else should see
    /// it as a move.
    ///
    /// `captured` is whether something under the press took the pointer for
    /// itself — a slider on a draggable row, being dragged as a slider. Then
    /// the gesture never starts: the press already has an owner.
    static func move(x: Float, y: Float, captured: Bool) -> Bool {
        if let active {
            active.entry.perform(value(.changed, from: active, x: x, y: y))
            return true
        }
        guard let press = pending else { return false }
        if captured {
            pending = nil
            return false
        }
        let dx = x - press.x
        let dy = y - press.y
        let distance = press.entry.minimumDistance
        guard dx * dx + dy * dy >= distance * distance else { return false }
        pending = nil
        active = press
        press.entry.perform(value(.began, from: press, x: x, y: y))
        return true
    }

    /// True when the release ended a gesture.
    static func release(x: Float, y: Float) -> Bool {
        pending = nil
        guard let gesture = active else { return false }
        active = nil
        gesture.entry.perform(value(.ended, from: gesture, x: x, y: y))
        return true
    }

    private static func value(
        _ phase: DragGesturePhase,
        from press: (entry: DragGestureEntry, x: Float, y: Float),
        x: Float, y: Float
    ) -> DragGestureValue {
        DragGestureValue(phase: phase, startX: press.x, startY: press.y, x: x, y: y)
    }
}

/// `.onAnyPress` registrations.
enum PressObserverRouter {
    nonisolated(unsafe) private static var observers: [NodeID: (Int32) -> Void] = [:]

    static func register(_ id: NodeID, _ observer: @escaping (Int32) -> Void) {
        observers[id] = observer
    }

    static func unregisterAll(ids: Set<NodeID>) {
        for id in ids { observers[id] = nil }
    }

    static func hasObserver(_ id: NodeID) -> Bool { observers[id] != nil }

    static func notify(_ id: NodeID, button: Int32) {
        observers[id]?(button)
    }
}

/// Attaches something to the content's root layout box — the shape `.onDrop`
/// and `.onFileDrag` share, factored out once there were more of them.
public struct BoxRegistrationView<Content: View>: PrimitiveView {
    let label: String
    let register: (YogaBoxNode) -> Void
    let content: Content

    public var dumpDetail: String { label }

    public func structureLines(indent: Int = 0) -> [String] {
        Dump.structureLines(
            indent: indent, label: label,
            childLines: [content.structureLines(indent: indent + 1)]
        )
    }

    public func mountPrimitive() -> any AnyViewNode {
        stamp(ViewGraph.mount(content))
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        // Wrapper created for fragment content.
        if let box = node as? StyleBoxNode, box.label == label {
            box.updateContent(ViewGraph.reconcile(box.contentNode, with: content))
            register(box)
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
            let wrapper = StyleBoxNode(content: node)
            wrapper.label = label
            box = wrapper
        }
        register(box)
        return box
    }
}

extension LayoutHost {
    /// The nearest `.onDragGesture` at this point, walking outwards.
    public func dragGestureSource(
        x: Float, y: Float, originX: Float = 0, originY: Float = 0
    ) -> NodeID? {
        hitTestScrollChain(x: x, y: y, originX: originX, originY: originY)
            .first { DragGestureRouter.hasGesture($0) }
    }

    /// Every `.onAnyPress` containing this point, innermost first.
    public func pressObservers(
        x: Float, y: Float, originX: Float = 0, originY: Float = 0
    ) -> [NodeID] {
        hitTestScrollChain(x: x, y: y, originX: originX, originY: originY)
            .filter { PressObserverRouter.hasObserver($0) }
    }
}

extension View {
    /// Runs `perform` as a left press on this view travels: `.began` once it
    /// has moved `minimumDistance` pixels, `.changed` on every move after —
    /// wherever the pointer goes, including out of the view — and `.ended` on
    /// release.
    ///
    /// The press still goes to whatever is under it first, so a tab that
    /// selects on press and moves on drag is two modifiers, not a gesture that
    /// has to remember to select. It is resolved outwards through the hit
    /// chain, so a label inside the view does not hide it. A press something
    /// else captures — a slider inside it — never becomes this gesture.
    public func onDragGesture(
        minimumDistance: Float = 6,
        perform: @escaping (DragGestureValue) -> Void
    ) -> BoxRegistrationView<Self> {
        BoxRegistrationView(
            label: "DragGesture",
            register: {
                DragGestureRouter.register(
                    $0.id,
                    DragGestureEntry(minimumDistance: minimumDistance, perform: perform)
                )
            },
            content: self
        )
    }

    /// Runs `perform` with the button for every press inside this view,
    /// **before** the press reaches what it landed on, and without taking it.
    ///
    /// For a container that needs to know it was used — a pane becoming the
    /// active one — while every row and button in it keeps its own clicks.
    /// Before, so that the handler of what was pressed already sees the
    /// consequence.
    public func onAnyPress(
        perform: @escaping (_ button: Int32) -> Void
    ) -> BoxRegistrationView<Self> {
        BoxRegistrationView(
            label: "AnyPress",
            register: { PressObserverRouter.register($0.id, perform) },
            content: self
        )
    }

    /// Runs `perform` with this view's rectangle, in window coordinates, after
    /// each layout pass that places it.
    ///
    /// For aiming at views from somewhere that is not their own handler: a tab
    /// dragged across a window needs to know which pane is under the pointer,
    /// and the panes are not what is receiving the moves.
    ///
    /// Called from inside layout. Store the frame; do not change what the tree
    /// shows from here — that is a second layout the frame loop never asked
    /// for. Not called while the view is hidden.
    public func onFrame(
        perform: @escaping (CanvasFrame) -> Void
    ) -> BoxRegistrationView<Self> {
        BoxRegistrationView(
            label: "OnFrame",
            register: { $0.onFrame = perform },
            content: self
        )
    }
}

#else

extension View {
    /// No-op without Yoga (stubs).
    public func onDragGesture(
        minimumDistance: Float = 6, perform: @escaping (DragGestureValue) -> Void
    ) -> Self { self }

    /// No-op without Yoga (stubs).
    public func onAnyPress(perform: @escaping (_ button: Int32) -> Void) -> Self { self }

    /// No-op without Yoga (stubs).
    public func onFrame(perform: @escaping (CanvasFrame) -> Void) -> Self { self }
}

#endif
