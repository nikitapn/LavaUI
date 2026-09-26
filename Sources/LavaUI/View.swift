@_exported import LavaText
@_exported import LavaMenu
import Foundation

// View protocol + retained-tree mount/reconcile.
//
// Defaults on `View` forward to `body` (SwiftCrossUI pattern).
// Primitives implement `PrimitiveMount` — **no default** — so missing
// mount/reconcile is a compile error.

/// Stable identity for a retained node (lifetime of the node object).
public struct NodeID: Hashable, Sendable {
    /// The counter value behind this id. Unique within the process, never reused.
    public let raw: UInt64

    /// Process-wide counter; UI construction is single-threaded (frame loop).
    private final class Counter: @unchecked Sendable {
        var value: UInt64 = 1
    }
    private static let counter = Counter()

    /// Returns a fresh id, one greater than the last one handed out.
    public static func generate() -> NodeID {
        let raw = counter.value
        counter.value += 1
        return NodeID(raw: raw)
    }
}

/// A declarative UI description.
public protocol View {
    /// The view type `body` returns. Primitive views, which draw themselves, use `Never`.
    associatedtype Body: View

    /// The content of this view, built from other views.
    ///
    /// Evaluated whenever the view's state or inputs change, so keep it free of
    /// side effects. Primitive views (`PrimitiveView`) do not use it.
    @ViewBuilder var body: Body { get }

    /// A text rendering of this view's structure, one line per view, for debugging.
    ///
    /// - Parameter indent: Nesting depth of this view; each level indents two spaces.
    func structureLines(indent: Int) -> [String]
}

extension View {
    /// Prints `structureLines(indent:)` to standard error.
    public func dumpStructure(indent: Int = 0) {
        for line in structureLines(indent: indent) {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }

    public func structureLines(indent: Int = 0) -> [String] {
        defaultStructureLines(indent: indent)
    }

    /// The structure dump every composite view gets: its own type name, then its
    /// `body` one level deeper. Call it from a custom `structureLines(indent:)`
    /// that wants to add to the default rather than replace it.
    public func defaultStructureLines(indent: Int) -> [String] {
        var lines = [Dump.line(indent, "\(type(of: self))")]
        lines += body.structureLines(indent: indent + 1)
        return lines
    }
}

// MARK: - Never

extension Never: View {
    public var body: Never {
        fatalError("Never has no body")
    }

    public func structureLines(indent: Int = 0) -> [String] { [] }
}

// MARK: - Primitive mount (compile-time enforced)

/// Required retained-tree construction for primitives. **No default.**
public protocol PrimitiveMount {
    /// Create a new retained node (and its Yoga node, if any).
    func mountPrimitive() -> any AnyViewNode

    /// Update `node` in place when types match; otherwise remount.
    func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode
}

/// Marker for views that own content directly (`Body == Never`).
public protocol PrimitiveView: View, PrimitiveMount where Body == Never {
    /// Extra text shown after the type name in `structureLines(indent:)`, such as
    /// a label or an id. Empty by default.
    var dumpDetail: String { get }
}

extension PrimitiveView {
    public var body: Never {
        fatalError("\(Self.self) is a primitive view — body is not used")
    }

    public var dumpDetail: String { "" }

    public func structureLines(indent: Int = 0) -> [String] {
        let detail = dumpDetail.isEmpty ? "" : " \(dumpDetail)"
        return [Dump.line(indent, "\(type(of: self))\(detail)")]
    }
}

// MARK: - Dump helpers

enum Dump {
    static func line(_ indent: Int, _ text: String) -> String {
        String(repeating: "  ", count: indent) + text
    }

    static func structureLines(
        indent: Int,
        label: String,
        childLines: [[String]]
    ) -> [String] {
        var lines = [line(indent, label)]
        for chunk in childLines {
            lines += chunk
        }
        return lines
    }
}

// MARK: - ViewGraph (mount / reconcile entry)

enum ViewGraph {
    /// First mount of a view value into a retained node.
    static func mount<V: View>(_ view: V) -> any AnyViewNode {
        if let p = view as? any PrimitiveMount {
            return p.mountPrimitive()
        }
        return CompositeNode(view)
    }

    /// Reconcile an existing node with a new view value of the same static type
    /// when possible; remounts on type mismatch.
    static func reconcile<V: View>(_ node: any AnyViewNode, with view: V) -> any AnyViewNode {
        if let c = node as? CompositeNode<V> {
            c.update(view)
            return c
        }
        if let p = view as? any PrimitiveMount {
            return p.reconcilePrimitive(node)
        }
        // Composite remount if types diverged.
        return mount(view)
    }
}
