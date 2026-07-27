// Phase 0b — Yoga measure function from Swift (throwaway spike).
//
// Goal: set YGMeasureFunc from Swift with a no-capture C function pointer,
// stash the leaf in YGNode context via Unmanaged, verify MarkDirty +
// recalculate re-invokes the measure callback.

#if canImport(CYoga)
import CYoga
import Foundation

/// Leaf that Yoga measures — analogous to a Text primitive's node.
final class TextLeaf {
    var text: String
    var measureCallCount = 0
    /// Simulated font: 8px per character, 18px line height.
    var charWidth: Float = 8
    var lineHeight: Float = 18

    init(_ text: String) { self.text = text }

    func measure(width: Float, mode: YGMeasureMode) -> YGSize {
        measureCallCount += 1
        let ideal = Float(text.utf8.count) * charWidth + 8
        var w = ideal
        switch mode {
        case YGMeasureModeUndefined:
            w = ideal
        case YGMeasureModeExactly:
            w = width
        case YGMeasureModeAtMost:
            w = min(ideal, width)
        default:
            w = ideal
        }
        return YGSize(width: w, height: lineHeight + 6)
    }
}

/// Must capture nothing — only then is it a C function pointer.
private func textLeafMeasure(
    _ node: YGNodeConstRef?,
    _ width: Float,
    _ widthMode: YGMeasureMode,
    _ height: Float,
    _ heightMode: YGMeasureMode
) -> YGSize {
    guard let node,
          let ctx = YGNodeGetContext(node)
    else {
        return YGSize(width: 0, height: 0)
    }
    let leaf = Unmanaged<TextLeaf>.fromOpaque(ctx).takeUnretainedValue()
    return leaf.measure(width: width, mode: widthMode)
}

enum Spike0b {
    static func run() -> Bool {
        print("=== 0b: Yoga measure func from Swift ===")

        let leaf = TextLeaf("Hi")
        let root = YGNodeNew()
        defer { YGNodeFreeRecursive(root) } // frees children too

        let node = YGNodeNew()
        YGNodeSetContext(node, Unmanaged.passUnretained(leaf).toOpaque())
        YGNodeSetMeasureFunc(node, textLeafMeasure)

        // Row + align items flex-start so the leaf is not stretched to 200
        // (stretch would force Exactly width and hide measure's ideal size).
        YGNodeStyleSetWidth(root, 200)
        YGNodeStyleSetHeight(root, 100)
        YGNodeStyleSetFlexDirection(root, YGFlexDirectionRow)
        YGNodeStyleSetAlignItems(root, YGAlignFlexStart)
        YGNodeInsertChild(root, node, 0)

        YGNodeCalculateLayout(root, 200, 100, YGDirectionLTR)
        let callsAfterFirst = leaf.measureCallCount
        let w1 = YGNodeLayoutGetWidth(node)
        let h1 = YGNodeLayoutGetHeight(node)
        print("  first layout: \(w1)×\(h1), measureCalls=\(callsAfterFirst)")

        guard callsAfterFirst > 0 else {
            print("  FAIL: measure never called")
            return false
        }

        // Change content, mark dirty, recalculate — must re-measure.
        leaf.text = "MuchLongerTextForMeasure"
        // YGNodeMarkDirty asserts if the node has no measure func — we have one.
        YGNodeMarkDirty(node)
        YGNodeCalculateLayout(root, 200, 100, YGDirectionLTR)
        let callsAfterSecond = leaf.measureCallCount
        let w2 = YGNodeLayoutGetWidth(node)
        print("  second layout: \(w2)×\(YGNodeLayoutGetHeight(node)), measureCalls=\(callsAfterSecond)")

        let remeasured = callsAfterSecond > callsAfterFirst
        let grew = w2 > w1
        let ok = remeasured && grew
        if !remeasured {
            print("  FAIL: MarkDirty + recalculate did not re-invoke measure")
        }
        if !grew {
            print("  FAIL: expected wider layout after longer text (w1=\(w1) w2=\(w2))")
        }
        print(ok ? "  PASS" : "  FAIL")
        return ok
    }
}

#else

enum Spike0b {
    static func run() -> Bool {
        print("=== 0b: SKIPPED (CYoga not available) ===")
        return false
    }
}

#endif
