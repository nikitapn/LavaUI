import Foundation

/// A scrolling row of tabs with an adjacent new-tab button and a window-drag
/// area. Supply `TabStripItem`s and attach app-specific drag/drop handlers to
/// them; the strip owns only layout and chrome.
public struct TabStrip<Content: View>: View {
    public static var height: Float { 36 }
    public static var tabHeight: Float { 30 }
    private let content: Content
    private let showsBaseline: Bool
    private let position: ScrollPosition?
    private let newButtonID: String
    private let onViewport: (CanvasFrame) -> Void
    private let onNew: () -> Void

    public init(
        showsBaseline: Bool = true, position: ScrollPosition? = nil,
        newButtonID: String = "new-tab",
        onViewport: @escaping (CanvasFrame) -> Void = { _ in },
        onNew: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.showsBaseline = showsBaseline
        self.position = position
        self.newButtonID = newButtonID
        self.onViewport = onViewport
        self.onNew = onNew
        self.content = content()
    }

    public var body: some View {
        let theme = Theme.current
        HStack(height: .pt(Self.height), padding: 0, alignment: .end, spacing: 4) {
            ScrollView(.horizontal, showsIndicator: false, position: position) {
                HStack(height: .pt(Self.height), padding: 0, alignment: .end, spacing: 4) {
                    Spacer(flexGrow: 0).frame(width: .pt(4), height: .pt(Self.height))
                    content
                }
            }
            .flexGrow(0)
            .flexShrink(1)
            .onFrame(perform: onViewport)
            HStack(padding: 6, alignment: .center, onClick: onNew) {
                Mark(.plus, size: 10, color: theme.textSecondary)
            }
            .hoverBackground(theme.hover)
            .cornerRadius(11)
            .cursor(.pointer)
            .tooltip("New Tab")
            .agentId(newButtonID)
            .frame(height: .pt(Self.tabHeight), alignment: .center)
            .flexShrink(0)
            Spacer()
                .frame(height: .pt(Self.height), minWidth: 48)
                .windowDrag()
        }
        .underlay {
            Canvas(label: "tab-strip", width: .pct(100), height: .pct(100)) { list, frame in
                list.rect(x: frame.x, y: frame.y, w: frame.w, h: frame.h, color: theme.background)
                if showsBaseline {
                    list.rect(x: frame.x, y: frame.y + frame.h - 1,
                              w: frame.w, h: 1, color: theme.border)
                }
            }
        }
    }
}

/// A tab whose title, dirty indicator and close target share one layout.
/// The close target is separate from the title and remains visible for long names.
public struct TabStripItem: View {
    private let title: String
    private let selected: Bool
    private let emphasized: Bool
    private let modified: Bool
    private let outlined: Bool
    private let fill: Color?
    private let closeID: String
    private let onSelect: () -> Void
    private let onClose: () -> Void

    public init(
        _ title: String, selected: Bool, emphasized: Bool = true,
        modified: Bool = false, outlined: Bool = true, fill: Color? = nil,
        closeID: String = "close-tab",
        onSelect: @escaping () -> Void, onClose: @escaping () -> Void
    ) {
        self.title = title
        self.selected = selected
        self.emphasized = emphasized
        self.modified = modified
        self.outlined = outlined
        self.fill = fill
        self.closeID = closeID
        self.onSelect = onSelect
        self.onClose = onClose
    }

    public var body: some View {
        let theme = Theme.current
        HStack(padding: 0, alignment: .center, spacing: 6, onPointer: { _, button in
            if button == PointerButton.middle { onClose() }
            else if button == PointerButton.left { onSelect() }
        }) {
            if modified {
                Canvas(label: "modified", width: .pt(6), height: .pt(6)) { list, frame in
                    list.roundedRect(x: frame.x, y: frame.y, w: 6, h: 6,
                                     color: theme.accent, radius: 3)
                }
            }
            Text(title, color: selected && emphasized ? theme.textPrimary : theme.textSecondary,
                 lineLimit: 1)
                .frame(width: .pt(min(200, max(60,
                    (Environment.current.font ?? FontStore.default)?.measure(title).width ?? 120
                ))))
                .clipped()
            TabCloseButton(action: onClose)
            .hoverBackground(theme.hover)
            .cornerRadius(4)
            .cursor(.pointer)
            .tooltip("Close Tab")
            .agentId(closeID)
        }
        .padding(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 4))
        .frame(height: .pt(30))
        .underlay {
            Canvas(label: "tab-shape", width: .pct(100), height: .pct(100)) { list, frame in
                guard selected else { return }
                TabOutline.paint(list, frame: frame, fill: fill ?? theme.panel,
                                 line: outlined ? theme.border : .clear)
            }
        }
        .hoverBackground(selected ? .clear : theme.hover)
        .cornerRadius(6)
        .cursor(.pointer)
        .flexShrink(0)
        .scrollIntoView(when: selected)
        .tooltip(title)
    }
}

private enum TabOutline {
    static let radius: Float = 7

    static func paint(_ list: DrawList, frame: CanvasFrame, fill: Color, line: Color) {
        let r = min(radius, frame.w * 0.5, frame.h)
        // Rounded on top only: the plate runs a radius past the bottom and the
        // clip cuts its lower corners off square, flush with the toolbar.
        list.pushClip(x: frame.x, y: frame.y, w: frame.w, h: frame.h)
        list.roundedRect(
            x: frame.x, y: frame.y, w: frame.w, h: frame.h + r, color: fill, radius: r
        )
        list.popClip()
        list.polyline(points(frame: frame, radius: r), color: line)
    }

    /// Up the left side, round the top, down the right side, ending on the
    /// strip's bottom edge where its rule takes over. Half-pixel centres, so a
    /// one-pixel line lands on one row of pixels rather than across two.
    static func points(frame: CanvasFrame, radius r: Float) -> [(x: Float, y: Float)] {
        let left = frame.x + 0.5
        let right = frame.x + frame.w - 0.5
        let top = frame.y + 0.5
        let bottom = frame.y + frame.h
        var out: [(x: Float, y: Float)] = [(left, bottom)]
        arc(into: &out, cx: left + r, cy: top + r, r: r, from: .pi, to: .pi * 1.5)
        arc(into: &out, cx: right - r, cy: top + r, r: r, from: .pi * 1.5, to: .pi * 2)
        out.append((right, bottom))
        return out
    }

    private static func arc(
        into out: inout [(x: Float, y: Float)],
        cx: Float, cy: Float, r: Float, from start: Float, to end: Float
    ) {
        let steps = 6
        for step in 0...steps {
            let t = start + (end - start) * Float(step) / Float(steps)
            out.append((cx + r * cos(t), cy + r * sin(t)))
        }
    }
}


/// Keep the drawn mark, but use the same captured-release contract as Button.
private struct TabCloseButton: PrimitiveView {
    let action: () -> Void
    var dumpDetail: String { "Close Tab" }
    private var content: some PrimitiveView {
        HStack(padding: 6, alignment: .center) {
            Mark(.cross, size: 8, color: Theme.current.textDim)
        }
    }
    func mountPrimitive() -> any AnyViewNode {
        let node = content.mountPrimitive()
        configure(node)
        return node
    }
    func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        let node = content.reconcilePrimitive(node)
        configure(node)
        return node
    }
    private func configure(_ node: any AnyViewNode) {
        guard let stack = node as? StackNode else { return }
        stack.onPointer = { [weak stack] _, button in
            guard let stack, button == PointerButton.left || button == PointerButton.middle else { return }
            PointerCapture.capture(stack.id, onMove: { _, _ in }, onUp: { [weak stack] in
                guard let stack, HoverState.isHovered(stack.id) else { return }
                action()
            })
        }
    }
}
