#if canImport(CxxCanvas)
import CYoga
import Foundation

/// Content drawn above everything, anchored to the view that presents it.
///
/// Menus, dropdowns and tooltips all need the same three things, and none of
/// them fit the normal tree walk:
///
/// - **Paint above everything.** Paint order is emission order, so a popup
///   emitted where its presenter sits would be covered by every later sibling.
///   Overlays are collected during the walk and emitted after it.
/// - **Escape the clip.** A dropdown inside a `ScrollView` must not be scissored
///   to it. Emitting after the walk gets this for free: the clip stack is back
///   to empty by then.
/// - **Take input first.** A click on a menu must not fall through to whatever
///   is underneath, and a click outside must dismiss it rather than activate
///   what it hit.
public enum OverlayAlignment: Equatable, Sendable {
    /// Below the presenter, flipping above when there is no room.
    case below
    /// Above the presenter, flipping below when there is no room.
    case above
}

/// Geometry available when placing a detached overlay.
public struct OverlayPlacementContext: Sendable {
    public var anchor: OverlayFrame
    public var viewport: OverlayFrame
    /// Natural size measured from the overlay's content before placement.
    public var idealSize: (width: Float, height: Float)
}

/// A detached overlay's resolved frame in window coordinates.
public struct OverlayFrame: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Placement policy for a detached overlay.
///
/// The callback receives the presenter, viewport, and content's natural size,
/// and returns the window-space frame the overlay should occupy. The result is
/// clamped to the viewport before layout.
public struct OverlayPlacement: @unchecked Sendable {
    let resolve: @Sendable (OverlayPlacementContext) -> OverlayFrame

    public init(
        _ resolve: @escaping @Sendable (OverlayPlacementContext) -> OverlayFrame
    ) {
        self.resolve = resolve
    }

    /// Fill the viewport while leaving an even margin around the surface.
    public static func viewport(inset: Float = 0) -> OverlayPlacement {
        OverlayPlacement { context in
            let gap = max(0, inset)
            return OverlayFrame(
                x: gap,
                y: gap,
                width: max(1, context.viewport.width - gap * 2),
                height: max(1, context.viewport.height - gap * 2)
            )
        }
    }
}

/// The detached subtree and where it ended up.
///
/// `isPresented` is a closure over the binding rather than a copied `Bool`, and
/// that is the load-bearing detail: a binding write invalidates at `.redraw`,
/// so a copy taken during reconcile would not be refreshed on the frame that
/// opens or closes the overlay. Reading it live means presentation costs a
/// redraw and nothing more.
final class OverlayAttachment {
    var root: StyleBoxNode?
    var isPresented: () -> Bool = { false }
    var dismiss: () -> Void = {}
    var alignment: OverlayAlignment = .below
    var customPlacement: OverlayPlacement?

    /// Outline drawn just outside the panel. A floating surface needs an edge:
    /// `panel` over `background` is a two-percent luminance step, which reads
    /// as a rendering artefact rather than as a thing on top of something.
    var border: Color?
    var cornerRadius: Float = 0

    /// Resolved during emit, in the same space as the anchor.
    var origin: (x: Float, y: Float) = (0, 0)
    var size: (w: Float, h: Float) = (0, 0)

    var presented: Bool { isPresented() }

    func contains(_ x: Float, _ y: Float) -> Bool {
        x >= origin.x && x < origin.x + size.w
            && y >= origin.y && y < origin.y + size.h
    }

    /// Lays the subtree out at its natural size and places it against the
    /// anchor, flipping to the other side when it would leave the window.
    ///
    /// Done at emit rather than in a layout phase of its own: presentation
    /// toggles at `.redraw`, and a phase that only runs on `.layout` frames
    /// would not see an overlay open. The subtree is a handful of nodes, so
    /// laying it out per frame is far cheaper than forcing a full body pass.
    func layoutAndPlace(
        anchorX: Float, anchorY: Float, anchorW: Float, anchorH: Float,
        viewportW: Float, viewportH: Float
    ) {
        guard let root, let y = root.yoga else { return }

        // Natural size, capped so a long menu cannot exceed the window.
        // A previous custom placement may have assigned an exact frame; clear
        // it before measuring the current content's ideal size again.
        YGNodeStyleSetWidthAuto(y)
        YGNodeStyleSetHeightAuto(y)
        YGNodeStyleSetMaxWidth(y, max(1, viewportW))
        YGNodeStyleSetMaxHeight(y, max(1, viewportH))
        YGNodeCalculateLayout(y, .nan, .nan, YGDirectionLTR)
        size = (YGNodeLayoutGetWidth(y), YGNodeLayoutGetHeight(y))

        if let customPlacement {
            let requested = customPlacement.resolve(
                OverlayPlacementContext(
                    anchor: OverlayFrame(
                        x: anchorX, y: anchorY, width: anchorW, height: anchorH
                    ),
                    viewport: OverlayFrame(
                        x: 0, y: 0, width: viewportW, height: viewportH
                    ),
                    idealSize: (size.w, size.h)
                )
            )
            let ox = max(0, min(requested.x, max(0, viewportW - 1)))
            let oy = max(0, min(requested.y, max(0, viewportH - 1)))
            let width = max(1, min(requested.width, viewportW - ox))
            let height = max(1, min(requested.height, viewportH - oy))
            origin = (ox, oy)
            size = (width, height)
            // Available dimensions do not force an auto-sized Yoga root to
            // fill them. The placement callback returned a frame, not merely
            // a constraint, so make its dimensions explicit.
            YGNodeStyleSetWidth(y, width)
            YGNodeStyleSetHeight(y, height)
            YGNodeCalculateLayout(y, width, height, YGDirectionLTR)
            return
        }

        let below = anchorY + anchorH
        let above = anchorY - size.h
        var oy: Float
        switch alignment {
        case .below:
            oy = below + size.h <= viewportH || above < 0 ? below : above
        case .above:
            oy = above >= 0 || below + size.h > viewportH ? above : below
        }
        oy = max(0, min(oy, max(0, viewportH - size.h)))

        // Left-aligned with the anchor, pulled back in at the right edge.
        let ox = max(0, min(anchorX, max(0, viewportW - size.w)))
        origin = (ox, oy)
    }
}

/// A presenter: one box wrapping the content, plus the detached subtree.
///
/// Always wraps, unlike `ModifiedView`, which styles the content's own node
/// where it can. Overlays are rare — a handful per app — so a box each costs
/// nothing measurable, and it buys unambiguous reconcile identity.
final class OverlayBoxNode: StyleBoxNode {
    let attachment = OverlayAttachment()
}

/// `content.overlay(isPresented:) { ... }`
public struct OverlayView<Content: View, OverlayContent: View>: PrimitiveView {
    public var content: Content
    public var overlayContent: OverlayContent
    public var isPresented: Binding<Bool>
    public var alignment: OverlayAlignment
    public var placement: OverlayPlacement?
    /// Panel styling for the floating surface itself.
    public var style: OverlayStyle

    public init(
        content: Content,
        isPresented: Binding<Bool>,
        alignment: OverlayAlignment,
        placement: OverlayPlacement? = nil,
        style: OverlayStyle,
        overlayContent: OverlayContent
    ) {
        self.content = content
        self.overlayContent = overlayContent
        self.isPresented = isPresented
        self.alignment = alignment
        self.placement = placement
        self.style = style
    }

    public var dumpDetail: String { "overlay \(alignment)" }

    public func structureLines(indent: Int = 0) -> [String] {
        Dump.structureLines(
            indent: indent, label: "Overlay \(alignment)",
            childLines: [
                content.structureLines(indent: indent + 1),
                overlayContent.structureLines(indent: indent + 1),
            ]
        )
    }

    public func mountPrimitive() -> any AnyViewNode {
        let node = OverlayBoxNode(content: ViewGraph.mount(content))
        let root = StyleBoxNode(content: ViewGraph.mount(overlayContent))
        node.attachment.root = root
        configure(node, root: root)
        return node
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        guard let box = node as? OverlayBoxNode else { return mountPrimitive() }
        box.updateContent(ViewGraph.reconcile(box.contentNode, with: content))

        // The subtree is kept mounted whether or not it is showing. Mounting it
        // lazily would make the first present a structural change, and a
        // structural change needs a body pass — which is exactly what reading
        // the binding live is designed to avoid. The cost is that a hidden
        // overlay's body still runs; for menu-sized content that is nothing.
        let root: StyleBoxNode
        if let existing = box.attachment.root {
            existing.updateContent(
                ViewGraph.reconcile(existing.contentNode, with: overlayContent)
            )
            root = existing
        } else {
            root = StyleBoxNode(content: ViewGraph.mount(overlayContent))
            box.attachment.root = root
        }
        configure(box, root: root)
        return box
    }

    private func configure(_ box: OverlayBoxNode, root: StyleBoxNode) {
        let att = box.attachment
        att.alignment = alignment
        att.customPlacement = placement
        let binding = isPresented
        att.isPresented = { binding.wrappedValue }
        att.dismiss = {
            guard binding.wrappedValue else { return }
            binding.wrappedValue = false
        }

        att.border = style.border
        att.cornerRadius = style.cornerRadius
        root.fillColor = style.background
        root.cornerRadius = style.cornerRadius
        root.backdropBlurRadius = style.backdropBlurRadius
        root.padding = style.padding
        // A floating panel sizes to its content; growing would be meaningless
        // with no parent to grow inside, and `inheritFlex` copies it from the
        // content, so it has to be cleared after every update.
        root.flexGrow = 0
        root.flexShrink = 0
        root.width = .auto
        root.height = .auto
        root.minWidth = style.minWidth
        root.applyStyle()
    }
}

/// Styling for the floating surface an overlay draws on.
public struct OverlayStyle {
    public var background: Color
    /// nil draws no outline.
    public var border: Color?
    public var cornerRadius: Float
    public var padding: Float
    public var minWidth: Float
    /// Blur applied to everything behind the complete resolved popup frame.
    public var backdropBlurRadius: Float?

    public init(
        background: Color? = nil,
        border: Color? = nil,
        cornerRadius: Float? = nil,
        padding: Float = 4,
        minWidth: Float = 0,
        backdropBlurRadius: Float? = nil
    ) {
        let theme = Environment.current.theme
        self.background = background ?? theme.panel
        self.border = border ?? theme.border
        self.cornerRadius = cornerRadius ?? theme.cornerRadius
        self.padding = padding
        self.minWidth = minWidth
        self.backdropBlurRadius = backdropBlurRadius
    }
}

extension View {
    /// Presents `content` above everything, anchored to this view.
    public func overlay<OverlayContent: View>(
        isPresented: Binding<Bool>,
        alignment: OverlayAlignment = .below,
        style: OverlayStyle = OverlayStyle(),
        @ViewBuilder content: () -> OverlayContent
    ) -> OverlayView<Self, OverlayContent> {
        OverlayView(
            content: self,
            isPresented: isPresented,
            alignment: alignment,
            placement: nil,
            style: style,
            overlayContent: content()
        )
    }

    /// Presents `content` above everything using a caller-defined frame.
    public func overlay<OverlayContent: View>(
        isPresented: Binding<Bool>,
        placement: OverlayPlacement,
        style: OverlayStyle = OverlayStyle(),
        @ViewBuilder content: () -> OverlayContent
    ) -> OverlayView<Self, OverlayContent> {
        OverlayView(
            content: self,
            isPresented: isPresented,
            alignment: .below,
            placement: placement,
            style: style,
            overlayContent: content()
        )
    }
}

// MARK: - Finding what is presented

enum OverlayScan {
    /// Presented attachments in tree order, so the last is topmost.
    static func presented(in node: any AnyViewNode) -> [OverlayAttachment] {
        var out: [OverlayAttachment] = []
        collect(node, into: &out)
        return out
    }

    private static func collect(
        _ node: any AnyViewNode, into out: inout [OverlayAttachment]
    ) {
        if let box = node as? OverlayBoxNode, box.attachment.presented {
            out.append(box.attachment)
        }
        for child in node.childNodes {
            collect(child, into: &out)
        }
    }
}

#endif
