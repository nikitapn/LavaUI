// Throwaway spike: can a modifier apply style to the child's *existing* node
// instead of introducing a Yoga box?
//
// Extra boxes are not free here. EitherView/ForEach wrappers had to be removed
// in Phase 2 precisely because an interposed flex container swallowed flexGrow
// and forced a direction on its children. A modifier chain like
// .padding().background().cornerRadius() would add three such boxes per view.
//
// Question 1: does style-onto-child work for a single-node child?
// Question 2: what happens when the child is a fragment (TupleView/ForEach),
//             which has no single node to style?
// Question 3: does the flexGrow-swallowing problem come back?

#if canImport(CxxCanvas)
import Foundation
import LavaUI

/// Style a modifier wants to push onto a node. Only the fields set are applied,
/// so chained modifiers compose rather than overwrite.
struct SpikeStyle {
    var padding: Float?
    var fill: SpikeColor?
    var cornerRadius: Float?
    var width: Float?

    func merged(over other: SpikeStyle) -> SpikeStyle {
        SpikeStyle(
            padding: padding ?? other.padding,
            fill: fill ?? other.fill,
            cornerRadius: cornerRadius ?? other.cornerRadius,
            width: width ?? other.width
        )
    }
}

struct SpikeColor { var r, g, b: Float }

/// Stand-in for the real node hierarchy: a box owns style, a fragment does not.
class SpikeNode {
    var label: String
    var isBox: Bool
    var children: [SpikeNode]
    var applied = SpikeStyle()
    /// Set by whoever created the node, not by a modifier.
    var flexGrow: Float = 0

    init(label: String, isBox: Bool, children: [SpikeNode] = [], flexGrow: Float = 0) {
        self.label = label
        self.isBox = isBox
        self.children = children
        self.flexGrow = flexGrow
    }

    /// Boxes this node contributes to its parent's layout.
    var boxCount: Int {
        (isBox ? 1 : 0) + children.reduce(0) { $0 + $1.boxCount }
    }

    func dump(_ depth: Int = 0) -> String {
        let pad = String(repeating: "  ", count: depth)
        var s = "\(pad)\(label)\(isBox ? "" : " [fragment]")"
        if let p = applied.padding { s += " pad=\(p)" }
        if applied.fill != nil { s += " filled" }
        if let r = applied.cornerRadius { s += " radius=\(r)" }
        if flexGrow > 0 { s += " grow=\(flexGrow)" }
        for c in children { s += "\n" + c.dump(depth + 1) }
        return s
    }
}

// MARK: Strategy under test

enum Strategy {
    /// Apply to the child's node when it is a single box; otherwise materialise
    /// one wrapper box (the only case that costs anything).
    static func apply(_ style: SpikeStyle, to node: SpikeNode) -> SpikeNode {
        if node.isBox {
            node.applied = style.merged(over: node.applied)
            return node
        }
        // Fragment: nothing to style. One box is unavoidable here — but it
        // inherits nothing, so flex properties must be forwarded deliberately.
        let box = SpikeNode(label: "ModifierBox", isBox: true, children: [node])
        box.applied = style
        box.flexGrow = node.children.reduce(0) { max($0, $1.flexGrow) }
        return box
    }
}

// MARK: Cases

func report(_ title: String, _ node: SpikeNode, expectedBoxes: Int) {
    let ok = node.boxCount == expectedBoxes
    print("\n── \(title) — boxes=\(node.boxCount) expected=\(expectedBoxes) \(ok ? "OK" : "REGRESSION")")
    print(node.dump(1))
}

// 1. Single-node child, three chained modifiers.
let text = SpikeNode(label: "Text", isBox: true)
var n1: SpikeNode = text
n1 = Strategy.apply(SpikeStyle(padding: 8), to: n1)
n1 = Strategy.apply(SpikeStyle(fill: SpikeColor(r: 1, g: 0, b: 0)), to: n1)
n1 = Strategy.apply(SpikeStyle(cornerRadius: 4), to: n1)
report("Q1 chained modifiers on a single-node view", n1, expectedBoxes: 1)

// 2. Fragment child (a TupleView of two texts).
let fragment = SpikeNode(
    label: "TupleView", isBox: false,
    children: [SpikeNode(label: "Text", isBox: true), SpikeNode(label: "Text", isBox: true)]
)
let n2 = Strategy.apply(SpikeStyle(padding: 8), to: fragment)
report("Q2 modifier on a fragment", n2, expectedBoxes: 3)

// 3. flexGrow must survive a modifier.
let spacer = SpikeNode(label: "Spacer", isBox: true, flexGrow: 1)
let n3 = Strategy.apply(SpikeStyle(padding: 4), to: spacer)
report("Q3 flexGrow survives on a single node", n3, expectedBoxes: 1)

// 4. flexGrow through a materialised wrapper — the Phase 2 failure mode.
let growingFragment = SpikeNode(
    label: "TupleView", isBox: false,
    children: [SpikeNode(label: "Spacer", isBox: true, flexGrow: 1)]
)
let n4 = Strategy.apply(SpikeStyle(padding: 4), to: growingFragment)
report("Q4 flexGrow through a wrapper", n4, expectedBoxes: 2)
print(n4.flexGrow > 0
    ? "   wrapper forwarded flexGrow — no swallow"
    : "   REGRESSION: wrapper swallowed flexGrow")
#else
print("spike needs CxxCanvas")
#endif
