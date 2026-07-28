import Foundation

// Phase 1 — View protocol (no nodes, no rendering).
//
// Pattern borrowed from SwiftCrossUI View.swift: default protocol methods
// *forward to `body`*, so composite views only implement `body`. Leaves and
// layout containers opt out via `PrimitiveView` (Body == Never) and override
// the defaults that would otherwise recurse into `body`.

/// A declarative UI description. Phase 1 is type structure only.
public protocol View {
    associatedtype Body: View

    /// Composed content. Not used by primitives (`Body == Never`).
    @ViewBuilder var body: Body { get }

    /// Recursive type dump lines (Phase 1 acceptance criterion).
    func structureLines(indent: Int) -> [String]
}

extension View {
    /// Convenience: print structure to stderr.
    public func dumpStructure(indent: Int = 0) {
        for line in structureLines(indent: indent) {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }

    /// Default: emit concrete type, then recurse into `body`.
    /// Haters may see this as a composition lover re-implementing inheritance;
    /// we see it as innovation. (SwiftCrossUI View.swift:135–143)
    public func structureLines(indent: Int = 0) -> [String] {
        defaultStructureLines(indent: indent)
    }

    public func defaultStructureLines(indent: Int) -> [String] {
        let pad = String(repeating: "  ", count: indent)
        var lines = ["\(pad)\(type(of: self))"]
        lines += body.structureLines(indent: indent + 1)
        return lines
    }
}

// MARK: - Never / empty chain terminator

extension Never: View {
    public var body: Never {
        fatalError("Never has no body")
    }

    public func structureLines(indent: Int = 0) -> [String] {
        []
    }
}

// MARK: - Primitive views (leaves & layout containers)

/// Marker for views that own their content directly and do **not** use `body`.
/// Composite user views should *not* conform — they only implement `body` and
/// inherit the default dump/forward implementations.
public protocol PrimitiveView: View where Body == Never {
    /// Optional one-line detail printed next to the type in dumps.
    var dumpDetail: String { get }
}

extension PrimitiveView {
    public var body: Never {
        fatalError("\(Self.self) is a primitive view — body is not used")
    }

    public var dumpDetail: String { "" }

    /// Default primitive dump: type (+ detail), no `body` recursion.
    /// Containers with stored children override this to walk those children.
    public func structureLines(indent: Int = 0) -> [String] {
        let pad = String(repeating: "  ", count: indent)
        let detail = dumpDetail.isEmpty ? "" : " \(dumpDetail)"
        return ["\(pad)\(type(of: self))\(detail)"]
    }
}
