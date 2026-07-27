#if canImport(CxxCanvas)
import Foundation

// MARK: - Declarative UI (SwiftUI-inspired, not SwiftUI)

/// Widget kinds must match `shell::WidgetKind` in C++.
public enum UIKind: Int32, Sendable {
    case row = 0
    case column = 1
    case text = 2
    case spacer = 3
    case diagramHost = 4
}

/// Opaque description node. Built by `UI` helpers; committed via `Editor.commitUI`.
public struct UINode: Sendable {
    public enum NodeKind: Sendable {
        case row(flexGrow: Float, width: Float, height: Float, padding: Float, children: [UINode])
        case column(flexGrow: Float, width: Float, height: Float, padding: Float, children: [UINode])
        case text(id: Int32, string: String, r: Float, g: Float, b: Float, clickable: Bool)
        case spacer(flexGrow: Float)
        case diagramHost(flexGrow: Float)
    }

    public var kind: NodeKind

    public init(_ kind: NodeKind) { self.kind = kind }
}

/// Registry of click handlers + id allocation. Rebuilt on every `commit`
/// (structural hot update). Source-level hot reload is a later step.
public final class UI: @unchecked Sendable {
    private var nextId: Int32 = 1
    private var handlers: [Int32: () -> Void] = [:]

    public init() {}

    /// Allocate a stable-looking id for this commit. Handlers are cleared
    /// when you call `beginCommit()` so re-building the tree re-binds clicks.
    public func beginCommit() {
        nextId = 1
        handlers.removeAll(keepingCapacity: true)
    }

    public func Text(
        _ string: String,
        r: Float = 0.90, g: Float = 0.90, b: Float = 0.90,
        onClick: (() -> Void)? = nil
    ) -> UINode {
        let id = nextId
        nextId += 1
        if let onClick {
            handlers[id] = onClick
        }
        return UINode(.text(
            id: id, string: string, r: r, g: g, b: b,
            clickable: onClick != nil
        ))
    }

    public func HStack(
        flexGrow: Float = 0,
        width: Float = -1,
        height: Float = -1,
        padding: Float = 0,
        @UIBuilder _ children: () -> [UINode]
    ) -> UINode {
        UINode(.row(
            flexGrow: flexGrow, width: width, height: height,
            padding: padding, children: children()
        ))
    }

    public func VStack(
        flexGrow: Float = 0,
        width: Float = -1,
        height: Float = -1,
        padding: Float = 0,
        @UIBuilder _ children: () -> [UINode]
    ) -> UINode {
        UINode(.column(
            flexGrow: flexGrow, width: width, height: height,
            padding: padding, children: children()
        ))
    }

    public func Spacer(flexGrow: Float = 1) -> UINode {
        UINode(.spacer(flexGrow: flexGrow))
    }

    /// Reserves the flex-grow center for the FBD diagram (sets diagramViewport).
    public func DiagramHost(flexGrow: Float = 1) -> UINode {
        UINode(.diagramHost(flexGrow: flexGrow))
    }

    func dispatch(widgetId: Int32) {
        handlers[widgetId]?()
    }

    func push(_ node: UINode, into editor: Editor) {
        switch node.kind {
        case .row(let grow, let w, let h, let pad, let kids):
            editor.uiBegin(kind: .row, id: 0, flexGrow: grow, flexShrink: 1,
                           width: w, height: h, padding: pad)
            kids.forEach { push($0, into: editor) }
            editor.uiEnd()
        case .column(let grow, let w, let h, let pad, let kids):
            editor.uiBegin(kind: .column, id: 0, flexGrow: grow, flexShrink: 1,
                           width: w, height: h, padding: pad)
            kids.forEach { push($0, into: editor) }
            editor.uiEnd()
        case .text(let id, let string, let r, let g, let b, let clickable):
            editor.uiText(id: id, text: string, r: r, g: g, b: b, clickable: clickable)
        case .spacer(let grow):
            editor.uiBegin(kind: .spacer, id: 0, flexGrow: grow, flexShrink: 0,
                           width: -1, height: -1, padding: 0)
            editor.uiEnd()
        case .diagramHost(let grow):
            editor.uiBegin(kind: .diagramHost, id: 0, flexGrow: grow, flexShrink: 1,
                           width: -1, height: -1, padding: 0)
            editor.uiEnd()
        }
    }
}

@resultBuilder
public enum UIBuilder {
    public static func buildExpression(_ node: UINode) -> [UINode] { [node] }
    public static func buildExpression(_ nodes: [UINode]) -> [UINode] { nodes }

    public static func buildBlock(_ parts: [UINode]...) -> [UINode] {
        parts.flatMap { $0 }
    }

    public static func buildArray(_ parts: [[UINode]]) -> [UINode] {
        parts.flatMap { $0 }
    }

    public static func buildOptional(_ part: [UINode]?) -> [UINode] {
        part ?? []
    }

    public static func buildEither(first part: [UINode]) -> [UINode] { part }
    public static func buildEither(second part: [UINode]) -> [UINode] { part }
}

#endif
