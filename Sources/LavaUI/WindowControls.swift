import Foundation

/// The window's own chrome: the three controls a title bar used to own, and
/// the region a window is dragged by, drawn by the app instead of around it.
///
/// The compositor's title bar is a service — every client gets a drag handle
/// and a close button without writing one — but it is a strip of somebody
/// else's design above an app that is usually already drawing a toolbar of its
/// own. An app that asks for `WindowFrame.client` gets those pixels back, and
/// these are what it puts in them: the same three verbs, placed where the app
/// wants them, styled with the app's own colours, or left out entirely by a
/// pop-up or overlay that should have no chrome at all.
///
/// Nothing here *does* anything locally. A client cannot move or hide its own
/// window — it does not know where it is, what else is on screen, or where the
/// panel a maximize must not cover ends — so each control asks the compositor,
/// through `WindowBridge`. In a windowed (GLFW) app the window manager still
/// draws a real frame and these have no work to do; see `WindowBridge`.

/// Which control. Three, because these are the three a window manager offers,
/// and an app inventing a fourth would be inventing a window state nothing
/// else in the desktop understands.
public enum WindowControlKind: Sendable, Equatable, CaseIterable {
    case close
    case minimize
    case maximize
}

/// Where a window's chrome sends the verbs it cannot perform itself.
///
/// The same shape as `ClipboardBridge`, `DropBridge` and `ScrollBridge`, and
/// for the same reason: `LavaUI` must not know what a compositor is, so the
/// framework declares the hole and `LavaClient` fills it. Unfilled — a
/// windowed app, a unit test — every hook is nil and the controls become inert
/// rather than wrong. That is the right default: a GLFW window already has a
/// real frame with real buttons, and an app that also draws these on top of it
/// has asked for a decoration it does not need.
///
/// `close` is the exception, and it needs no hook at all: ending the window is
/// something an app can always do. A client still must drop its surface
/// (`DestroySurface`) on the way out — otherwise the window lingers until
/// NPRPC notices the process is gone — and `LavaClient.run` does that when
/// the frame loop returns.
public enum WindowBridge {
    /// "The user has grabbed the window" — starts an interactive move.
    /// Called on the *press*; everything after it belongs to the compositor.
    nonisolated(unsafe) public static var beginDrag: (@Sendable () -> Void)?
    /// Fills the work area, or restores. The desktop owns which one it is,
    /// which is why nothing here tracks a maximized flag.
    nonisolated(unsafe) public static var toggleMaximize: (@Sendable () -> Void)?
    /// Hides the window without ending it.
    nonisolated(unsafe) public static var minimize: (@Sendable () -> Void)?

    /// Whether this window has no frame but its own — set by whoever opened
    /// it, because only that call knows what it asked for.
    ///
    /// An app that runs both windowed and as a client reads this to decide
    /// whether to draw a control cluster at all: under a window manager the
    /// real frame already has one, and a second set of buttons below it is a
    /// decoration nobody asked for.
    ///
    /// ```swift
    /// if WindowBridge.drawsOwnChrome { WindowControls() }
    /// ```
    nonisolated(unsafe) public static var drawsOwnChrome = false

    /// Whether the window state verbs reach anything. False in a windowed app.
    public static var canControlWindow: Bool { beginDrag != nil }

    /// The desktop's window corner radius, in points. 0 when windows are
    /// square, and 0 in a windowed app, where the radius belongs to whatever
    /// window manager drew the frame and is not ours to know.
    ///
    /// Not needed to *be* rounded — the compositor masks a window's corners
    /// whatever the client draws. It is for matching: a menu, a dialog or a
    /// card the app draws inside its own window should carry the same radius
    /// as the window around it.
    ///
    /// ```swift
    /// content.cornerRadius(WindowBridge.desktopCornerRadius)
    /// ```
    ///
    /// Read once, when the client connected. A desktop whose config changes
    /// mid-session leaves this stale until the app restarts — see
    /// `GetAppearance` in the IDL for why that is a call and not a stream.
    nonisolated(unsafe) public static var desktopCornerRadius: Float = 0

    /// The shadow the desktop puts under a focused window: how far it reaches,
    /// how dark it is directly underneath, and how far down it is pushed.
    ///
    /// For the same reason the radius is here — matching, not doing. The
    /// compositor casts a window's shadow; an app that gives its own menu or
    /// dialog one should use these numbers rather than pick its own, or the
    /// two will disagree in the same frame. `blur` 0 means the desktop casts
    /// no shadows, and so should the app.
    nonisolated(unsafe) public static var desktopShadow:
        (blur: Float, opacity: Float, offsetY: Float) = (0, 0, 0)

    static func requestDrag() { beginDrag?() }
    static func requestMaximize() { toggleMaximize?() }
    static func requestMinimize() { minimize?() }

    /// Ends the window the caller is drawing in. Takes effect at the end of
    /// the frame, so it is safe to call from a control's own handler.
    static func requestClose() {
        LavaApp.closeWindow(WindowScope.currentOrMain.windowID)
    }
}

/// Colours and metrics for a control cluster.
///
/// The defaults are the traffic lights, because they are the arrangement users
/// already read without a legend: the colour says which button it is at a
/// glance and at any size, and the glyph is confirmation rather than the label.
/// Every field is open, so an app whose palette this fights can restate it
/// without reimplementing hit testing or the compositor calls.
public struct WindowControlsStyle: Sendable, Equatable {
    /// Diameter of one control, in points.
    public var size: Float
    /// Gap between controls.
    public var spacing: Float
    public var close: Color
    public var minimize: Color
    public var maximize: Color
    /// Fill while the pointer is down on a control. A darkened version of the
    /// control's own colour reads as "pressed" without a second palette.
    public var pressedDim: Float
    /// The glyph drawn inside a control while the cluster is hovered.
    public var glyph: Color
    /// Whether the glyphs appear only on hover. False draws them always, which
    /// suits a dense toolbar where the cluster is small.
    public var glyphOnHoverOnly: Bool

    public init(
        size: Float = 12,
        spacing: Float = 8,
        close: Color = Color(r: 1.0, g: 0.37, b: 0.34),
        minimize: Color = Color(r: 1.0, g: 0.74, b: 0.18),
        maximize: Color = Color(r: 0.16, g: 0.78, b: 0.25),
        pressedDim: Float = 0.75,
        glyph: Color = Color(r: 0.15, g: 0.12, b: 0.1, a: 0.85),
        glyphOnHoverOnly: Bool = true
    ) {
        self.size = size
        self.spacing = spacing
        self.close = close
        self.minimize = minimize
        self.maximize = maximize
        self.pressedDim = pressedDim
        self.glyph = glyph
        self.glyphOnHoverOnly = glyphOnHoverOnly
    }

    /// One flat colour for all three, for chrome that would rather not shout.
    /// The glyph still says which is which, so it is drawn unconditionally.
    public static func monochrome(
        size: Float = 12, spacing: Float = 8, color: Color? = nil
    ) -> WindowControlsStyle {
        let tint = color ?? Theme.current.textDim
        return WindowControlsStyle(
            size: size, spacing: spacing, close: tint, minimize: tint,
            maximize: tint, glyph: Theme.current.background,
            glyphOnHoverOnly: false
        )
    }

    func fill(for kind: WindowControlKind) -> Color {
        switch kind {
        case .close: return close
        case .minimize: return minimize
        case .maximize: return maximize
        }
    }
}

/// Draws one control. Shared by the cluster and the standalone button so the
/// two can never drift into looking like different desktops.
enum WindowControlPainter {
    static func paint(
        _ list: DrawList, _ frame: CanvasFrame, kind: WindowControlKind,
        hovered: Bool, pressed: Bool, style: WindowControlsStyle
    ) {
        let radius = min(frame.w, frame.h) * 0.5
        let cx = frame.x + frame.w * 0.5
        let cy = frame.y + frame.h * 0.5
        var fill = style.fill(for: kind)
        if pressed {
            fill = Color(
                r: fill.r * style.pressedDim, g: fill.g * style.pressedDim,
                b: fill.b * style.pressedDim, a: fill.a
            )
        }
        list.circle(cx: cx, cy: cy, radius: radius, color: fill)

        guard hovered || !style.glyphOnHoverOnly else { return }
        // Lines rather than glyphs: a symbol face would mean an atlas entry per
        // state and a font id the compositor has to agree about, for three
        // marks that are two strokes each at this size.
        let arm = radius * 0.42
        let ink = style.glyph
        switch kind {
        case .close:
            list.line(x1: cx - arm, y1: cy - arm, x2: cx + arm, y2: cy + arm,
                      color: ink, width: 1.2)
            list.line(x1: cx - arm, y1: cy + arm, x2: cx + arm, y2: cy - arm,
                      color: ink, width: 1.2)
        case .minimize:
            list.line(x1: cx - arm, y1: cy, x2: cx + arm, y2: cy,
                      color: ink, width: 1.2)
        case .maximize:
            // A box, which reads as "fill the screen" where a plus reads as
            // "add something".
            list.line(x1: cx - arm, y1: cy - arm, x2: cx + arm, y2: cy - arm,
                      color: ink, width: 1.2)
            list.line(x1: cx + arm, y1: cy - arm, x2: cx + arm, y2: cy + arm,
                      color: ink, width: 1.2)
            list.line(x1: cx + arm, y1: cy + arm, x2: cx - arm, y2: cy + arm,
                      color: ink, width: 1.2)
            list.line(x1: cx - arm, y1: cy + arm, x2: cx - arm, y2: cy - arm,
                      color: ink, width: 1.2)
        }
    }

    /// What a control does when it is clicked.
    static func perform(_ kind: WindowControlKind) {
        switch kind {
        case .close: WindowBridge.requestClose()
        case .minimize: WindowBridge.requestMinimize()
        case .maximize: WindowBridge.requestMaximize()
        }
    }
}

/// One window control, for chrome that places them apart — a close button in
/// one corner of an overlay and nothing else at all.
///
/// Fires on release, and only if the pointer is still on it: dragging off a
/// close button is how a user changes their mind, and a window that closed on
/// the press would not let them.
public struct WindowControlButton: View {
    public var kind: WindowControlKind
    public var style: WindowControlsStyle

    @DrawState private var hovered = false
    @DrawState private var pressed = false

    public init(_ kind: WindowControlKind, style: WindowControlsStyle = WindowControlsStyle()) {
        self.kind = kind
        self.style = style
    }

    public var body: some View {
        control(kind, style: style, hovered: { hovered }, pressed: { pressed },
                setHovered: { hovered = $0 }, setPressed: { pressed = $0 })
    }
}

/// The three controls as one cluster, in the order this desktop puts them.
///
/// Hover is shared: pointing at any one of them reveals all three glyphs, the
/// way a group of controls behaves when it is read as a group. Which controls
/// appear — and in what order — is the app's, so a window that cannot be
/// resized simply does not list `.maximize` rather than showing a button that
/// lies.
public struct WindowControls: View {
    public var kinds: [WindowControlKind]
    public var style: WindowControlsStyle

    @DrawState private var hovered = false
    @DrawState private var pressed: WindowControlKind?

    public init(
        _ kinds: [WindowControlKind] = [.close, .minimize, .maximize],
        style: WindowControlsStyle = WindowControlsStyle()
    ) {
        self.kinds = kinds
        self.style = style
    }

    public var body: some View {
        HStack(alignment: .center, spacing: style.spacing) {
            ForEach(kinds, id: \.self) { kind in
                control(
                    kind, style: style,
                    hovered: { hovered }, pressed: { pressed == kind },
                    setHovered: { hovered = $0 },
                    setPressed: { pressed = $0 ? kind : nil }
                )
            }
        }
    }
}

/// The control itself, built the same way for both of the above.
///
/// State is read and written through closures rather than passed by value: the
/// paint closure is retained by the leaf and runs long after this function
/// returned, so it has to look the values up when it draws instead of
/// capturing what they were when the body ran.
private func control(
    _ kind: WindowControlKind,
    style: WindowControlsStyle,
    hovered: @escaping () -> Bool,
    pressed: @escaping () -> Bool,
    setHovered: @escaping (Bool) -> Void,
    setPressed: @escaping (Bool) -> Void
) -> some View {
    Canvas(
        label: "WindowControl",
        width: .pt(style.size),
        height: .pt(style.size),
        onGesture: { gesture in
            switch gesture.phase {
            case .began:
                setPressed(true)
            case .moved:
                break
            case .ended:
                setPressed(false)
                let inside = gesture.localX >= 0 && gesture.localY >= 0
                    && gesture.localX <= gesture.frame.w
                    && gesture.localY <= gesture.frame.h
                if inside { WindowControlPainter.perform(kind) }
            }
        },
        onHover: { setHovered($0) },
        paint: { list, frame in
            WindowControlPainter.paint(
                list, frame, kind: kind, hovered: hovered(),
                pressed: pressed(), style: style
            )
        }
    )
    .agentId("window-control-\(kind)")
}

// ─── Drag regions ──────────────────────────────────────────────────────────

/// Makes a view's empty space a place the window can be dragged by.
///
/// The other half of client-side decoration, and the half that is easy to
/// forget: without it a window with no title bar can be closed and maximized
/// but never moved. Put it on the toolbar, the header, or whatever row the
/// controls sit in — anything interactive inside still wins, because the hit
/// test reaches children first.
///
/// The press is *all* it takes. From the moment the compositor is told, the
/// pointer is the compositor's: the motion never reaches this process, the
/// window follows the cursor, and the drag ends when the button comes up
/// somewhere this app will never hear about. That is why nothing here tracks a
/// drag — there is none to track on this side.
public struct WindowDragArea<Content: View>: PrimitiveView {
    public var content: Content
    /// Whether a double-click toggles maximize, the way a title bar does.
    public var doubleClickMaximizes: Bool

    /// Two presses closer together than this are a double-click. The interval
    /// every toolkit has settled on; not configurable because a window's
    /// chrome should not have its own idea of what a double-click is.
    private static var doubleClickInterval: Double { 0.4 }

    public init(content: Content, doubleClickMaximizes: Bool = true) {
        self.content = content
        self.doubleClickMaximizes = doubleClickMaximizes
    }

    public var dumpDetail: String { "windowDrag" }

    public func structureLines(indent: Int = 0) -> [String] {
        Dump.structureLines(
            indent: indent, label: "WindowDrag",
            childLines: [content.structureLines(indent: indent + 1)]
        )
    }

    public func mountPrimitive() -> any AnyViewNode {
        stamp(ViewGraph.mount(content))
    }

    public func reconcilePrimitive(_ node: any AnyViewNode) -> any AnyViewNode {
        if let box = node as? StyleBoxNode, box.label == "WindowDrag" {
            box.updateContent(ViewGraph.reconcile(box.contentNode, with: content))
            attach(to: box)
            return box
        }
        return stamp(ViewGraph.reconcile(node, with: content))
    }

    /// Puts the handler on the content's own box, or on one wrapper if the
    /// content is a fragment with no single box to carry it — the same shape
    /// `.onDrop()` uses.
    private func stamp(_ node: any AnyViewNode) -> any AnyViewNode {
        let box: YogaBoxNode
        if let existing = node as? YogaBoxNode {
            box = existing
        } else {
            let wrapper = StyleBoxNode(content: node)
            wrapper.label = "WindowDrag"
            box = wrapper
        }
        attach(to: box)
        return box
    }

    private func attach(to box: YogaBoxNode) {
        let wantsMaximize = doubleClickMaximizes
        box.onBoxPress = { _, _, _ in
            let now = Date().timeIntervalSinceReferenceDate
            let isDouble = now - lastDragPress < Self.doubleClickInterval
            // Reset rather than keep counting, so a triple-click is a double
            // followed by a single instead of two maximize toggles.
            lastDragPress = isDouble ? 0 : now
            if isDouble, wantsMaximize {
                WindowBridge.requestMaximize()
                return
            }
            WindowBridge.requestDrag()
        }
    }
}

/// When the last drag-region press happened. Process-wide, like `HoverState`:
/// there is one pointer, and a double-click that started on one region and
/// finished on another is a user who missed, not two gestures.
nonisolated(unsafe) private var lastDragPress: Double = 0

extension View {
    /// Lets the window be dragged by this view's own empty space, and
    /// maximized by double-clicking it — what a title bar did, minus the bar.
    ///
    /// A no-op in a windowed app, where the window manager's frame is still
    /// the thing that moves the window.
    public func windowDrag(doubleClickMaximizes: Bool = true) -> WindowDragArea<Self> {
        WindowDragArea(content: self, doubleClickMaximizes: doubleClickMaximizes)
    }
}
