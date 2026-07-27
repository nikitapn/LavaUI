// Phase 0a — Parameter packs for TupleView (throwaway spike).
//
// Goal: prove we can avoid gyb-generated TupleView1…N by using Swift
// parameter packs on both the ViewBuilder side and a retained-children
// storage class that iterates into a [LayoutChild]-like array.

// Minimal stand-in for the Phase 1 View protocol.
protocol SpikeView {
    associatedtype Body: SpikeView
    var body: Body { get }
}

/// Primitive leaf — Body is Never via EmptySpike (Swift forbids Body == Never
/// without compiler magic; EmptySpike is the practical substitute).
struct EmptySpike: SpikeView {
    var body: EmptySpike { self }
}

struct SpikeText: SpikeView {
    var string: String
    var body: EmptySpike { EmptySpike() }
}

struct SpikeSpacer: SpikeView {
    var body: EmptySpike { EmptySpike() }
}

/// Pack-based tuple of heterogeneous views — the replacement for
/// TupleView1…N codegen.
struct SpikeTupleView<each C: SpikeView>: SpikeView {
    var content: (repeat each C)
    var body: EmptySpike { EmptySpike() }
}

@resultBuilder
enum SpikeViewBuilder {
    static func buildBlock<each C: SpikeView>(
        _ c: repeat each C
    ) -> SpikeTupleView<repeat each C> {
        SpikeTupleView(content: (repeat each c))
    }

    static func buildExpression<V: SpikeView>(_ v: V) -> V { v }
}

// MARK: - Children side (the harder half)

/// Type-erased layout child — what a retained node tree walks for Yoga/draw.
struct LayoutChild {
    var label: String
    var viewTypeName: String
}

/// Per-child retained node (stand-in for ViewNode).
final class AnyViewNode {
    let label: String
    let typeName: String
    init(label: String, typeName: String) {
        self.label = label
        self.typeName = typeName
    }
}

/// Store `(repeat AnyViewNode-like)` for a pack of child view types and
/// flatten to `[LayoutChild]` via pack iteration.
final class PackChildren<each C: SpikeView> {
    /// One hosted node per pack element. Parameter packs of class
    /// references work; packs of *protocol existentials* do not need to
    /// appear here.
    var nodes: (repeat HostedNode<each C>)

    init(views: (repeat each C)) {
        self.nodes = (repeat HostedNode(each views))
    }

    func asLayoutChildren() -> [LayoutChild] {
        var out: [LayoutChild] = []
        for node in repeat each nodes {
            out.append(LayoutChild(
                label: node.label,
                viewTypeName: node.typeName
            ))
        }
        return out
    }
}

final class HostedNode<V: SpikeView> {
    var view: V
    var label: String
    var typeName: String

    init(_ view: V) {
        self.view = view
        self.typeName = String(describing: V.self)
        // Best-effort label for the spike dump.
        if let t = view as? SpikeText {
            self.label = t.string
        } else {
            self.label = typeName
        }
    }
}

enum Spike0a {
    @SpikeViewBuilder
    static func sampleBody() -> some SpikeView {
        SpikeText(string: "Hello")
        SpikeSpacer()
        SpikeText(string: "World")
    }

    static func run() -> Bool {
        print("=== 0a: parameter packs / TupleView ===")

        let body = sampleBody()
        let typeName = String(describing: type(of: body))
        print("  buildBlock type: \(typeName)")

        // Must be a SpikeTupleView of three elements, not an Array.
        let isTuple = typeName.contains("SpikeTupleView")
        guard isTuple else {
            print("  FAIL: expected SpikeTupleView, got \(typeName)")
            return false
        }

        // Children storage + pack iteration → [LayoutChild]
        // We need the concrete tuple type. Mirror the builder call:
        let tuple = SpikeViewBuilder.buildBlock(
            SpikeText(string: "Hello"),
            SpikeSpacer(),
            SpikeText(string: "World")
        )
        let children = PackChildren(views: tuple.content)
        let flat = children.asLayoutChildren()
        print("  layout children (\(flat.count)):")
        for c in flat {
            print("    - \(c.label) [\(c.viewTypeName)]")
        }

        let ok = flat.count == 3
            && flat[0].label == "Hello"
            && flat[2].label == "World"
        print(ok ? "  PASS" : "  FAIL: unexpected child dump")
        return ok
    }
}
