import Foundation
import LavaPDFCore
import LavaUI

/// The window: a bar along the top, the find bar under it when open, and the
/// pages.
///
/// The pages are one `Canvas` rather than a `ScrollView` of page views, and
/// that is deliberate. A page is not a view with a size of its own — it is a
/// set of tiles at whatever scale the zoom asks for, plus a selection and
/// search highlights in the page's own coordinates — and every one of those
/// is cheaper to place from one viewport than to keep in step with a layout
/// tree. The cost is that scrolling is the client's, not the renderer's, so a
/// notch lands in one frame instead of easing; `ReaderSession.wheel` is where
/// to change that.
struct ReaderView: View {
    @Bindable var session: ReaderSession

    private let keyTarget = NodeID.generate()

    var body: some View {
        FocusManager.setDefault(
            keyTarget,
            onKey: { [session] event in ReaderKeys.handle(event, session: session) },
            onChar: { _ in false }
        )
        return VStack(flexGrow: 1, spacing: 0) {
            ReaderBar(session: session)
            if session.findOpen { FindBar(session: session) }
            HStack(flexGrow: 1, spacing: 0) {
                if session.sidebarOpen, !session.outline.isEmpty {
                    OutlineSidebar(session: session)
                }
                pages
            }
        }
        .background(Theme.current.background)
        .onDrop { urls in
            if let pdf = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) ?? urls.first {
                session.open(path: pdf.path)
            }
        }
    }

    private var pages: some View {
        Canvas(
            label: "pages",
            flexGrow: 1,
            minHeight: 80,
            onGesture: handleGesture,
            onWheel: { dx, dy, x, y in session.wheel(dx: dx, dy: dy, atX: x, atY: y) },
            paint: paint
        )
        .flexGrow(1)
        .cursor(session.hasDocument ? .text : .arrow)
        .agentId("pages")
    }

    // MARK: - Pointer

    /// What the press that is in progress is doing.
    private enum Drag {
        /// Pressed on a link: followed on release, unless the pointer moves
        /// far enough first to make it a selection instead.
        case link(PageLink, x: Float, y: Float)
        case selecting
        /// Holding the scrollbar thumb, `grab` pixels below its top.
        case scrollbar(grab: Float)
    }

    @DrawState private var drag: Drag?

    private func handleGesture(_ gesture: CanvasGesture) {
        let frame = gesture.frame
        switch gesture.phase {
        case .began:
            guard gesture.button == PointerButton.left else { return }
            FocusManager.clear()
            if let bar = scrollbar(in: frame), gesture.localX >= frame.w - Scrollbar.hitWidth {
                // On the thumb: hold it where it was taken. Off it: jump so the
                // thumb is centred on the pointer, then hold it there.
                let grab = gesture.localY >= bar.thumbY && gesture.localY <= bar.thumbY + bar.thumbH
                    ? gesture.localY - bar.thumbY : bar.thumbH / 2
                drag = .scrollbar(grab: grab)
                dragScrollbar(to: gesture.localY - grab, frame: frame)
                return
            }
            if gesture.clickCount == 1, let link = session.link(atX: gesture.localX, y: gesture.localY) {
                drag = .link(link, x: gesture.localX, y: gesture.localY)
                return
            }
            drag = .selecting
            session.beginSelection(x: gesture.localX, y: gesture.localY, clickCount: gesture.clickCount)
        case .moved:
            switch drag {
            case .link(_, let x, let y):
                // Selecting text that happens to be a link — a reference, a
                // URL printed in the text — is a drag that starts on it.
                guard abs(gesture.localX - x) + abs(gesture.localY - y) > 4 else { return }
                drag = .selecting
                session.beginSelection(x: x, y: y, clickCount: 1)
                session.extendSelection(x: gesture.localX, y: gesture.localY)
            case .selecting: session.extendSelection(x: gesture.localX, y: gesture.localY)
            case .scrollbar(let grab): dragScrollbar(to: gesture.localY - grab, frame: frame)
            case nil: break
            }
        case .ended:
            switch drag {
            case .selecting: session.endSelection()
            case .link(let link, _, _):
                session.clearSelection()
                session.follow(link.target)
            default: break
            }
            drag = nil
        }
    }

    private func dragScrollbar(to thumbTop: Float, frame: CanvasFrame) {
        guard let bar = scrollbar(in: frame) else { return }
        let travel = frame.h - bar.thumbH
        session.scroll(toFraction: travel > 0 ? Double(thumbTop / travel) : 0)
    }

    // MARK: - Paint

    private func paint(_ list: DrawList, _ frame: CanvasFrame) {
        session.setBox(width: frame.w, height: frame.h)
        list.rect(x: frame.x, y: frame.y, w: frame.w, h: frame.h, color: Palette.mat)
        guard session.hasDocument else {
            centred(list, frame, text: session.openError ?? "No document — drop a PDF here, or press Ctrl+O")
            return
        }

        let viewport = session.viewport
        let layout = session.layout
        let sizes = session.document?.pageSizes ?? []
        let tiles = session.tiles
        tiles.beginFrame()

        let boxW = Double(frame.w), boxH = Double(frame.h)
        let originX = Double(frame.x) + viewport.originX(layout, boxWidth: boxW)
        let originY = Double(frame.y) + viewport.originY(layout)
        let zoom = viewport.zoom
        let visible = viewport.visible(layout, boxWidth: boxW, boxHeight: boxH)
        let scaleKey = TileGrid.scaleKey(forScale: zoom)
        // Snapped per edge rather than per size, so two tiles that share an
        // edge in the page share it on screen too and no hairline of mat shows
        // between them.
        func screenX(_ x: Double) -> Float { Float((originX + x * zoom).rounded()) }
        func screenY(_ y: Double) -> Float { Float((originY + y * zoom).rounded()) }

        var wanted: [TileKey] = []
        var sharp: [TileKey] = []
        list.pushClip(x: frame.x, y: frame.y, w: frame.w, h: frame.h)
        for page in layout.pages(intersecting: visible) {
            let pageFrame = layout.frames[page]
            let size = sizes[page]
            // The page's corner on a whole pixel, and its size the size of
            // its render, so a tile at this zoom covers exactly the pixels it
            // was rendered for and nothing is resampled.
            let x0 = screenX(pageFrame.x), y0 = screenY(pageFrame.y)
            let pixels = TileGrid.pixelSize(of: size, scaleKey: scaleKey)
            let x1 = x0 + Float(pixels.width), y1 = y0 + Float(pixels.height)
            list.rect(x: x0 + 2, y: y0 + 3, w: x1 - x0, h: y1 - y0, color: Palette.shadow)
            list.rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0, color: Palette.paper)

            let resident = tiles.tiles(ofPage: page, nearest: scaleKey)
            // A page seen for the first time gets a quarter-scale picture of
            // the whole of it first: one cheap render that turns a blank page
            // into a soft one while the sharp tiles come in.
            if resident.isEmpty {
                let preview = TileGrid.previewKey(for: scaleKey)
                wanted += TileGrid.tiles(
                    page: page, size: size, scaleKey: preview,
                    visible: Box(x: 0, y: 0, width: size.width, height: size.height)
                )
            }
            let onPage = Box(
                x: visible.x - pageFrame.x, y: visible.y - pageFrame.y,
                width: visible.width, height: visible.height
            )
            let needed = TileGrid.tiles(page: page, size: size, scaleKey: scaleKey, visible: onPage)
            sharp += needed

            for (key, image) in resident {
                guard TileGrid.pointRect(of: key, size: size).intersects(onPage) else { continue }
                // From the page's snapped corner in the tile's own pixels,
                // scaled by how far its scale is from the zoom: exactly 1 for
                // the tiles being read, so they land on the pixel grid.
                let factor = Float(zoom / TileGrid.scale(ofKey: key.scaleKey))
                let rect = TileGrid.pixelRect(of: key, size: size)
                let tx0 = x0 + (Float(rect.x) * factor).rounded()
                let ty0 = y0 + (Float(rect.y) * factor).rounded()
                let tx1 = x0 + (Float(rect.x + rect.width) * factor).rounded()
                let ty1 = y0 + (Float(rect.y + rect.height) * factor).rounded()
                list.image(image, x: tx0, y: ty0, w: tx1 - tx0, h: ty1 - ty0)
            }

            highlights(list, page: page, pageFrame: pageFrame, screenX: screenX, screenY: screenY)
        }
        wanted += sharp

        // The next screenful down, after everything on screen: reading is
        // mostly forwards, and a page that is already rendered when it scrolls
        // in is the difference between a reader and a slideshow.
        let ahead = Box(x: visible.x, y: visible.maxY, width: visible.width, height: visible.height)
        for page in layout.pages(intersecting: ahead) {
            let pageFrame = layout.frames[page]
            wanted += TileGrid.tiles(
                page: page, size: sizes[page], scaleKey: scaleKey,
                visible: Box(x: ahead.x - pageFrame.x, y: ahead.y - pageFrame.y,
                             width: ahead.width, height: ahead.height)
            )
        }
        list.popClip()

        drawScrollbar(list, frame)
        tiles.want(wanted, sizes: sizes)
    }

    /// Search matches under the selection, the current match brightest.
    private func highlights(
        _ list: DrawList, page: Int, pageFrame: Box,
        screenX: (Double) -> Float, screenY: (Double) -> Float
    ) {
        let matches = session.matches(onPage: page)
        let selection = session.selection?.page == page ? session.selection : nil
        guard !matches.isEmpty || selection != nil, let text = session.text(page: page) else { return }

        func fill(_ boxes: [Box], _ color: Color) {
            for box in boxes {
                let x0 = screenX(pageFrame.x + box.x), y0 = screenY(pageFrame.y + box.y)
                let x1 = screenX(pageFrame.x + box.maxX), y1 = screenY(pageFrame.y + box.maxY)
                list.rect(x: x0, y: y0, w: max(1, x1 - x0), h: max(1, y1 - y0), color: color)
            }
        }
        for match in matches {
            fill(text.boxes(for: match.range), match.current ? Palette.currentMatch : Palette.match)
        }
        if let selection { fill(text.boxes(for: selection.range), Palette.selection) }
    }

    // MARK: - Scrollbar

    private enum Scrollbar {
        static let width: Float = 6
        /// Wider than it is drawn, so it can be hit without aiming.
        static let hitWidth: Float = 14
        static let minThumb: Float = 32
    }

    private func scrollbar(in frame: CanvasFrame) -> (thumbY: Float, thumbH: Float)? {
        let content = session.layout.height * session.viewport.zoom
        guard content > Double(frame.h), content > 0 else { return nil }
        let share = Float(Double(frame.h) / content)
        let thumbH = max(Scrollbar.minThumb, frame.h * share)
        let travel = frame.h - thumbH
        let fraction = Float(session.viewport.scrollY / (content - Double(frame.h)))
        return (travel * min(max(fraction, 0), 1), thumbH)
    }

    private func drawScrollbar(_ list: DrawList, _ frame: CanvasFrame) {
        guard let bar = scrollbar(in: frame) else { return }
        list.roundedRect(
            x: frame.x + frame.w - Scrollbar.width - 3, y: frame.y + bar.thumbY + 2,
            w: Scrollbar.width, h: bar.thumbH - 4,
            color: Palette.scrollThumb, radius: Scrollbar.width / 2
        )
    }

    private func centred(_ list: DrawList, _ frame: CanvasFrame, text: String) {
        guard let font = Environment.current.font ?? FontStore.default else { return }
        let size = font.measure(text)
        list.text(
            text,
            x: frame.x + (frame.w - size.width) / 2 - 4,
            y: frame.y + (frame.h - font.lineHeight) / 2,
            w: size.width + 8, h: font.lineHeight,
            color: Theme.current.textDim, font: font
        )
    }
}

/// Colours that are the reader's rather than the theme's.
enum Palette {
    /// Behind the pages. Dark under every theme: a page is judged against
    /// what surrounds it, and white paper on a light grey reads as no edge.
    static let mat = Color(r: 0.16, g: 0.16, b: 0.18)
    static let paper = Color(r: 1, g: 1, b: 1)
    static let shadow = Color(r: 0, g: 0, b: 0, a: 0.35)
    /// Over black text on white, so translucent and saturated: the words
    /// must still be readable through it.
    static let selection = Color(r: 0.25, g: 0.5, b: 1.0, a: 0.35)
    static let match = Color(r: 1.0, g: 0.85, b: 0.1, a: 0.40)
    static let currentMatch = Color(r: 1.0, g: 0.55, b: 0.0, a: 0.55)
    static let scrollThumb = Color(r: 1, g: 1, b: 1, a: 0.35)
}
