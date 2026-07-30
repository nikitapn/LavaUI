/// Values that flow down the view tree, defaulting to `Theme.current` /
/// `FontStore.default` at the root and overridable for a subtree via
/// `.theme(_:)` / `.font(_:)` — those globals are the environment's
/// defaults now, not the only way to set a value.
public struct EnvironmentValues {
    public var theme: Theme
    public var font: UIFont?
}

/// Scope stack for `EnvironmentValues`.
///
/// `ViewGraph.mount`/`.reconcile` recurse synchronously and depth-first —
/// a composite's `body` is evaluated, and everything that construction
/// produces (down to every default-argument read of `Theme.current`-alikes)
/// happens nested inside that same call — so a plain stack sees the right
/// frame at every nesting level: push before descending into an overridden
/// subtree, pop right after `ViewGraph.mount`/`.reconcile` returns.
///
/// Measure callbacks and the draw-list emit walk run later, as separate
/// passes over the retained node tree with an empty stack — they read
/// whatever a node captured from `current` at mount/reconcile time, not
/// `current` itself.
public enum Environment {
    nonisolated(unsafe) private static var overrides: [EnvironmentValues] = []

    /// Falls through to the live globals wherever nothing pushed an
    /// override, so a `Theme.current` toggle keeps reaching every subtree
    /// that never opted out of the default.
    public static var current: EnvironmentValues {
        overrides.last ?? EnvironmentValues(theme: Theme.current, font: FontStore.default)
    }

    static func push(theme: Theme?, font: UIFont?) {
        var v = current
        if let theme { v.theme = theme }
        if let font { v.font = font }
        overrides.append(v)
    }

    static func pop() { overrides.removeLast() }
}

/// Wraps `content` with an environment override active for its own
/// mount/reconcile call — i.e. for its whole subtree, not just its own
/// node. Delegates entirely to `content`'s node; this adds no Yoga node.
public struct EnvironmentModifiedView<Content: View>: PrimitiveView {
    public var content: Content
    var overrideTheme: Theme?
    var overrideFont: UIFont?

    public func structureLines(indent: Int = 0) -> [String] {
        content.structureLines(indent: indent)
    }

    public func mountPrimitive() -> any AnyViewNode {
        Environment.push(theme: overrideTheme, font: overrideFont)
        defer { Environment.pop() }
        return ViewGraph.mount(content)
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        Environment.push(theme: overrideTheme, font: overrideFont)
        defer { Environment.pop() }
        return ViewGraph.reconcile(node, with: content)
    }
}

extension View {
    /// Overrides the theme for this subtree only; `Theme.current` (and every
    /// other subtree) is unaffected.
    public func theme(_ value: Theme) -> EnvironmentModifiedView<Self> {
        EnvironmentModifiedView(content: self, overrideTheme: value, overrideFont: nil)
    }

    /// Overrides the font for this subtree only.
    public func font(_ value: UIFont) -> EnvironmentModifiedView<Self> {
        EnvironmentModifiedView(content: self, overrideTheme: nil, overrideFont: value)
    }
}
