import Foundation
import LavaUI

/// A press that might become a reorder, or already has.
///
/// Same shape as the dock's `DockDrag`: neighbours slide toward a hole at
/// `dest` rather than packing into a shorter row, and a click must not
/// shuffle anything.
struct TabDrag {
    var documentID: Int
    var fromIndex: Int
    var dest: Int
    /// Pointer X minus the tab's left edge, so the tab does not jump to
    /// sit under the cursor the moment the drag starts.
    var grabOffset: Float
    var pointerX: Float
    var active: Bool
}

/// Metrics and slot arithmetic for the canvas tab row.
///
/// Tabs are a fixed stride — the name is clipped to `nameWidth`, so every
/// tab is the same width, the way dock icons share a rest size. That is
/// what lets a dest index be a division rather than a hit test against
/// every frame.
enum TabChrome {
    static let barHeight: Float = 38
    static let rowPadding: Float = 4
    static let spacing: Float = 2
    static let tabWidth: Float = 200
    static let tabHeight: Float = 30
    static let nameWidth: Float = 150
    static let closeSize: Float = 16
    /// How long neighbours take to make room. Same duration the dock uses:
    /// short enough to track the pointer, long enough to read as a slide.
    static let slideDuration: Double = 0.2
    /// Floor on the title-bar spacer so a full tab row still leaves a
    /// window-drag handle.
    static let dragGrab: Float = 48
    /// Pixels one wheel notch pans the row.
    static let scrollStep: Float = 100
    /// Viewport inset where a live drag starts panning the row.
    static let autoScrollEdge: Float = 28
    static let autoScrollSpeed: Float = 8

    static var tabY: Float { (barHeight - tabHeight) * 0.5 }

    static func contentWidth(count: Int) -> Float {
        let count = max(count, 1)
        return rowPadding * 2
            + Float(count) * tabWidth
            + Float(count - 1) * spacing
    }

    static func restX(index: Int) -> Float {
        rowPadding + Float(index) * (tabWidth + spacing)
    }

    /// Slot whose centre is nearest `centerX`, in canvas-local coordinates.
    static func slot(atCenterX centerX: Float, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let stride = tabWidth + spacing
        let first = restX(index: 0) + tabWidth * 0.5
        let idx = Int(((centerX - first) / stride).rounded())
        return min(max(0, idx), count - 1)
    }

    /// Where the row would sit if `from` were dropped at `dest`.
    ///
    /// The dragged tab stays in the list at `hole` so the plate keeps its
    /// width; paint skips that slot and draws the tab under the pointer.
    static func preview(
        documents: [EditorDocument], from: Int, dest rawDest: Int
    ) -> (items: [EditorDocument], hole: Int) {
        let count = documents.count
        guard count > 0, documents.indices.contains(from) else {
            return (documents, 0)
        }
        let dest = min(max(0, rawDest), count - 1)
        var items = documents
        let item = items.remove(at: from)
        let insert = min(dest, items.count)
        items.insert(item, at: insert)
        return (items, insert)
    }

    static func closeRect(tabX: Float) -> (x: Float, y: Float, w: Float, h: Float) {
        (
            x: tabX + tabWidth - 6 - closeSize,
            y: tabY + (tabHeight - closeSize) * 0.5,
            w: closeSize,
            h: closeSize
        )
    }

    static func contains(
        _ rect: (x: Float, y: Float, w: Float, h: Float),
        x: Float, y: Float
    ) -> Bool {
        x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h
    }
}

/// Horizontal tab row, painted the way the dock paints icons: each tab has
/// an `Animated` X, and a dest change eases rather than jumps.
struct TabStrip: View {
    @Bindable var session: EditorSession
    /// Pan of the tab row inside the laid-out box. Paint-only: a `@State`
    /// write would rebuild the strip on every wheel notch.
    @DrawState private var scrollX: Float = 0

    var body: some View {
        // Paint is emit-time and invisible to Observation. These reads are
        // what actually rebuilds the canvas when a tab is renamed, dirtied,
        // reordered, or still sliding after the pointer stops.
        let documents = session.documents
        _ = session.activeIndex
        _ = session.tabSliding
        _ = session.tabDrag?.active
        _ = session.tabRevealID
        let width = TabChrome.contentWidth(count: documents.count)
        // Yoga is told the *content* width as a point size. A canvas has no
        // measure callback — that point is the size, and `.flexShrink(1)` is
        // what lets a long row collapse to the viewport. Scrolling is then
        // ours: `frame.w` is the viewport, `scrollX` pans inside it.
        return Canvas(
            label: "tabs",
            width: .pt(width),
            height: .pt(TabChrome.barHeight),
            minWidth: TabChrome.tabWidth,
            continuousRedraw: session.tabDrag?.active == true || session.tabSliding,
            onGesture: { gesture in handle(gesture) },
            onWheel: { dx, dy, _, _ in handleWheel(dx: dx, dy: dy) },
            onHover: { _ in },
            paint: { list, frame in paint(list, frame) }
        )
        .flexShrink(1)
        .clipped()
        .cursor(.pointer)
        .agentId("tabs")
    }

    // MARK: - Gesture

    private func handle(_ gesture: CanvasGesture) {
        switch gesture.phase {
        case .began:
            guard gesture.button == PointerButton.left else { return }
            beginPress(atX: gesture.localX, y: gesture.localY)
        case .moved:
            updateDrag(atX: gesture.localX)
        case .ended:
            endPress(atX: gesture.localX, y: gesture.localY)
        }
    }

    /// Vertical wheel pans the row. A tab strip has no Y axis, same mapping
    /// `RenderWindow::scrollScene` does for an X-only container.
    private func handleWheel(dx: Float, dy: Float) {
        let notch = dx != 0 ? dx : dy
        guard notch != 0 else { return }
        scrollX = max(0, scrollX - notch * TabChrome.scrollStep)
    }

    private func beginPress(atX localX: Float, y: Float) {
        session.tabClosePress = nil
        session.tabDrag = nil
        let documents = session.documents
        let x = localX + scrollX
        guard let index = tabIndex(atX: x, y: y, documents: documents) else {
            return
        }
        let restX = TabChrome.restX(index: index)
        if TabChrome.contains(TabChrome.closeRect(tabX: restX), x: x, y: y) {
            session.tabClosePress = documents[index].id
            return
        }
        // Viewport offset so the dragged tab stays under the pointer even
        // if auto-scroll pans the row underneath.
        session.tabDrag = TabDrag(
            documentID: documents[index].id,
            fromIndex: index,
            dest: index,
            grabOffset: localX - (restX - scrollX),
            pointerX: localX,
            active: false
        )
    }

    private func updateDrag(atX localX: Float) {
        guard var drag = session.tabDrag else { return }
        drag.pointerX = localX
        let contentLeft = localX - drag.grabOffset + scrollX
        let dest = TabChrome.slot(
            atCenterX: contentLeft + TabChrome.tabWidth * 0.5,
            count: session.documents.count
        )
        if !drag.active, dest != drag.fromIndex {
            drag.active = true
            session.tabSliding = true
        }
        if drag.active { drag.dest = dest }
        session.tabDrag = drag
        ViewInvalidation.markNeedsRedraw()
    }

    private func endPress(atX localX: Float, y: Float) {
        let closeID = session.tabClosePress
        let drag = session.tabDrag
        session.tabClosePress = nil
        session.tabDrag = nil

        if let closeID {
            if let index = session.documents.firstIndex(where: { $0.id == closeID }) {
                let restX = TabChrome.restX(index: index)
                let x = localX + scrollX
                if TabChrome.contains(TabChrome.closeRect(tabX: restX), x: x, y: y) {
                    session.requestClose(index)
                }
            }
            ViewInvalidation.markNeedsRedraw()
            return
        }

        guard let drag else { return }
        // Park the tab where the pointer left it so the ease toward rest
        // starts from the pixels on screen, not from the slot it was
        // dragged out of.
        let visualX = localX - drag.grabOffset + scrollX
        var anim = session.tabSlide[drag.documentID] ?? Animated(visualX)
        anim.snap(to: visualX)
        session.tabSlide[drag.documentID] = anim

        if !drag.active {
            if let index = session.documents.firstIndex(
                where: { $0.id == drag.documentID }
            ) {
                session.activate(index)
            }
        } else {
            session.reorderTab(id: drag.documentID, to: drag.dest)
        }
        session.tabSliding = true
        ViewInvalidation.markNeedsRedraw()
    }

    /// Resting slots, not the in-flight positions: a tab that is still
    /// sliding into a hole should activate as the slot the user aimed at.
    private func tabIndex(
        atX x: Float, y: Float, documents: [EditorDocument]
    ) -> Int? {
        let tabY = TabChrome.tabY
        guard y >= tabY, y < tabY + TabChrome.tabHeight else { return nil }
        for index in documents.indices {
            let restX = TabChrome.restX(index: index)
            if x >= restX, x < restX + TabChrome.tabWidth { return index }
        }
        return nil
    }

    // MARK: - Paint

    private func paint(_ list: DrawList, _ frame: CanvasFrame) {
        let documents = session.documents
        let contentW = TabChrome.contentWidth(count: documents.count)
        let maxScroll = max(0, contentW - frame.w)
        if let id = session.tabRevealID,
           let index = documents.firstIndex(where: { $0.id == id })
        {
            // Until Yoga shrinks us, `frame.w` equals content width and
            // every tab "fits". Keep the request until there is a viewport.
            if maxScroll > 0 {
                let left = TabChrome.restX(index: index)
                let right = left + TabChrome.tabWidth
                if left < scrollX {
                    scrollX = left
                } else if right > scrollX + frame.w {
                    scrollX = right - frame.w
                }
                session.tabRevealID = nil
            } else if contentW <= frame.w {
                session.tabRevealID = nil
            }
        }
        if scrollX > maxScroll { scrollX = maxScroll }
        if scrollX < 0 { scrollX = 0 }

        var drag = session.tabDrag
        let dragging = drag?.active == true
        let pointer = PointerState.window
        let local = (x: pointer.x - frame.x, y: pointer.y - frame.y)

        if dragging, let live = drag {
            var next = live
            if local.x < TabChrome.autoScrollEdge {
                scrollX = max(0, scrollX - TabChrome.autoScrollSpeed)
            } else if local.x > frame.w - TabChrome.autoScrollEdge {
                scrollX = min(maxScroll, scrollX + TabChrome.autoScrollSpeed)
            }
            let contentLeft = local.x - live.grabOffset + scrollX
            next.pointerX = local.x
            next.dest = TabChrome.slot(
                atCenterX: contentLeft + TabChrome.tabWidth * 0.5,
                count: documents.count
            )
            if next.dest != live.dest { session.tabDrag = next }
            drag = next
        }

        let leftEdges = rowLayout(documents: documents, drag: drag)
        let theme = Theme.current
        let font = FontStore.default
        let now = FrameScheduler.now()

        var live: [Int: Animated<Float>] = [:]
        var anySliding = false

        for doc in documents {
            guard let target = leftEdges[doc.id] else { continue }
            var anim = session.tabSlide[doc.id] ?? Animated(target)
            if abs(anim.target - target) > 0.25 {
                anim.animate(
                    to: target,
                    duration: TabChrome.slideDuration,
                    curve: .easeOut
                )
            }
            if anim.step(now) { anySliding = true }
            live[doc.id] = anim
            paintTab(
                list, document: doc,
                x: frame.x + anim.current - scrollX,
                y: frame.y + TabChrome.tabY,
                theme: theme, font: font,
                pointer: local,
                originX: frame.x
            )
        }
        session.tabSlide = live

        if dragging, let drag,
           let doc = documents.first(where: { $0.id == drag.documentID })
        {
            paintTab(
                list, document: doc,
                x: frame.x + local.x - drag.grabOffset,
                y: frame.y + TabChrome.tabY,
                theme: theme, font: font,
                pointer: local,
                originX: frame.x
            )
        }

        if anySliding || dragging { FrameScheduler.requestWake(in: 1.0 / 60.0) }
        if session.tabSliding != anySliding { session.tabSliding = anySliding }
    }

    /// Resting left edges for every tab that stays in the row.
    ///
    /// A live drag keeps the row at full width and leaves a hole at the
    /// preview dest so neighbours have somewhere to slide into.
    private func rowLayout(
        documents: [EditorDocument], drag: TabDrag?
    ) -> [Int: Float] {
        let items: [EditorDocument]
        let hole: Int?
        if drag?.active == true, let drag,
           let from = documents.firstIndex(where: { $0.id == drag.documentID })
        {
            let preview = TabChrome.preview(
                documents: documents, from: from, dest: drag.dest
            )
            items = preview.items
            hole = preview.hole
        } else {
            items = documents
            hole = nil
        }
        var left: [Int: Float] = [:]
        for (index, doc) in items.enumerated() {
            if hole == index { continue }
            left[doc.id] = TabChrome.restX(index: index)
        }
        return left
    }

    private func paintTab(
        _ list: DrawList, document: EditorDocument,
        x: Float, y: Float,
        theme: Theme, font: UIFont?,
        pointer: (x: Float, y: Float),
        originX: Float
    ) {
        let w = TabChrome.tabWidth
        let h = TabChrome.tabHeight
        let isActive = document.id == session.active.id
        let localX = pointer.x
        let localY = pointer.y
        let hovered = session.tabDrag == nil
            && localX >= x - originX && localX < x - originX + w
            && localY >= TabChrome.tabY && localY < TabChrome.tabY + h

        let fill: Color = {
            if isActive { return theme.background }
            if hovered { return theme.hover }
            return theme.panel
        }()
        list.roundedRect(x: x, y: y, w: w, h: h, color: fill, radius: 4)

        if document.isModified {
            list.circle(
                cx: x + 14, cy: y + h * 0.5, radius: 3.5,
                color: theme.accent
            )
        }

        let nameX = x + 24
        let nameY = y + (h - (font?.lineHeight ?? 16)) * 0.5
        list.pushClip(x: nameX, y: y, w: TabChrome.nameWidth, h: h)
        list.text(
            document.name, x: nameX, y: nameY,
            w: TabChrome.nameWidth, h: font?.lineHeight ?? h,
            color: isActive ? theme.textPrimary : theme.textMuted,
            font: font
        )
        list.popClip()

        let close = TabChrome.closeRect(tabX: x - originX)
        let closeHovered = hovered
            && TabChrome.contains(close, x: localX, y: localY)
        if closeHovered {
            list.roundedRect(
                x: originX + close.x + 2, y: y + (h - close.h) * 0.5,
                w: close.w, h: close.h,
                color: theme.selectionFill, radius: 3
            )
        }
        list.text(
            "×",
            x: originX + close.x + 1,
            y: y + (h - (font?.lineHeight ?? 16)) * 0.5,
            w: close.w, h: font?.lineHeight ?? h,
            color: theme.textDim,
            font: font
        )
    }
}
