import Foundation
import LavaPDFCore
import LavaUI

/// The window: a bar along the top and pages with a floating find panel.
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
            if session.locked != nil { PasswordBar(session: session) }
            HStack(flexGrow: 1, spacing: 0) {
                if session.sidebarOpen, !session.outline.isEmpty {
                    OutlineSidebar(session: session)
                }
                pages
                    // Search belongs over the document: changing its viewport
                    // would refit the pages and move the reader's place.
                    .overlay(
                        alignment: .topTrailing, insets: EdgeInsets(top: 12, trailing: 32),
                        style: session.findOpen ? OverlayStyle(cornerRadius: 8, padding: 0) : nil
                    ) {
                        if session.findOpen {
                            // As wide as its contents; on a narrow window the
                            // panel shrinks to the pages and the field gives.
                            FindBar(session: session)
                        }
                    }
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
            // A hand over a link, and the canvas's text cursor everywhere else.
            onPointerMove: { x, y in session.link(atX: x, y: y) != nil ? .pointer : nil },
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
        /// Holding a scrollbar thumb, `grab` pixels past its start.
        case scrollbar(Axis, grab: Float)
    }

    @DrawState private var drag: Drag?

    private func handleGesture(_ gesture: CanvasGesture) {
        let frame = gesture.frame
        switch gesture.phase {
        case .began:
            guard gesture.button == PointerButton.left else { return }
            FocusManager.clear()
            for axis in [Axis.vertical, .horizontal] {
                guard let bar = scrollbar(axis, in: frame) else { continue }
                let across = axis == .vertical ? gesture.localX : gesture.localY
                let extent = axis == .vertical ? frame.w : frame.h
                guard across >= extent - Scrollbar.hitWidth else { continue }
                // On the thumb: hold it where it was taken. Off it: jump so the
                // thumb is centred on the pointer, then hold it there.
                let along = axis == .vertical ? gesture.localY : gesture.localX
                let grab = along >= bar.start && along <= bar.start + bar.length
                    ? along - bar.start : bar.length / 2
                drag = .scrollbar(axis, grab: grab)
                dragScrollbar(axis, to: along - grab, frame: frame)
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
            case .scrollbar(let axis, let grab):
                let along = axis == .vertical ? gesture.localY : gesture.localX
                dragScrollbar(axis, to: along - grab, frame: frame)
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

    private func dragScrollbar(_ axis: Axis, to thumbStart: Float, frame: CanvasFrame) {
        guard let bar = scrollbar(axis, in: frame) else { return }
        let travel = bar.track - bar.length
        let fraction = travel > 0 ? Double(thumbStart / travel) : 0
        if axis == .vertical {
            session.scroll(toFraction: fraction)
        } else {
            session.scroll(toFractionX: fraction)
        }
    }

    // MARK: - Paint

    private func paint(_ list: DrawList, _ frame: CanvasFrame) {
        session.setBox(width: frame.w, height: frame.h)
        list.rect(x: frame.x, y: frame.y, w: frame.w, h: frame.h, color: Palette.mat)
        guard session.hasDocument else {
            centred(list, frame, text: session.locked != nil
                ? "Enter the password above to open it"
                : session.openError ?? "No document — drop a PDF here, or press Ctrl+O")
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
        var drawn: [TileKey] = []
        var previews: Set<Int> = []
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

            let onPage = Box(
                x: visible.x - pageFrame.x, y: visible.y - pageFrame.y,
                width: visible.width, height: visible.height
            )
            let needed = TileGrid.tiles(page: page, size: size, scaleKey: scaleKey, visible: onPage)
            sharp += needed
            let preview = TileGrid.previewKey(for: scaleKey)
            previews.insert(preview)

            // What to draw: the tiles at this zoom, and only where one of them
            // has not arrived, something to stand in for it — the nearest
            // other scale that has that spot, over the page's preview.
            // Everything else resident is left undrawn, which is what lets it
            // go: drawing every scale a page had ever been rendered at kept
            // all of them alive and put 279 textures in each frame after a
            // minute of resizing.
            let resident = tiles.resident(ofPage: page)
            let current = Set(resident.lazy.filter { $0.key.scaleKey == scaleKey }.map(\.key))
            let holes = needed.filter { !current.contains($0) }
                .map { TileGrid.pointRect(of: $0, size: size) }
            var layers: [(key: TileKey, image: UIImage)] = []
            if !holes.isEmpty {
                func covers(_ key: TileKey) -> Bool {
                    let rect = TileGrid.pointRect(of: key, size: size)
                    return holes.contains { $0.intersects(rect) }
                }
                let ratio = { (key: Int) in abs(log(Double(key) / Double(scaleKey))) }
                let others = resident.filter { $0.key.scaleKey != scaleKey && covers($0.key) }
                let nearest = others.filter { $0.key.scaleKey != preview }
                    .min { ratio($0.key.scaleKey) < ratio($1.key.scaleKey) }?.key.scaleKey
                layers += others.filter { $0.key.scaleKey == preview }
                if let nearest { layers += others.filter { $0.key.scaleKey == nearest } }
                // A page seen for the first time gets a quarter-scale picture of
                // the whole of it first: one cheap render that turns a blank
                // page into a soft one while the sharp tiles come in.
                if !resident.contains(where: { $0.key.scaleKey == preview }) {
                    wanted += TileGrid.tiles(
                        page: page, size: size, scaleKey: preview,
                        visible: Box(x: 0, y: 0, width: size.width, height: size.height)
                    )
                }
            }
            layers += resident.filter { current.contains($0.key) }

            for (key, image) in layers {
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
                drawn.append(key)
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

        drawScrollbar(.vertical, list, frame)
        drawScrollbar(.horizontal, list, frame)
        tiles.want(wanted, sizes: sizes)
        let now = FrameScheduler.now()
        tiles.markDrawn(drawn, at: now)
        // The zoom on screen and its previews stay however long they go
        // undrawn — scrolling back should find them — and everything else
        // goes after a few seconds of not being looked at.
        if tiles.sweep(now: now, keep: { key in
            key.scaleKey == scaleKey || previews.contains(key.scaleKey)
        }) {
            FrameScheduler.requestRedraw(in: 3.5)
        }

        // A drag resting past the window's edge sends nothing, so the frame
        // that scrolls it asks for the next one itself.
        if session.autoScroll(now: FrameScheduler.now()) {
            FrameScheduler.requestRedraw(in: 1.0 / 60)
        }
    }

    /// Search matches under the selection, the current match brightest.
    private func highlights(
        _ list: DrawList, page: Int, pageFrame: Box,
        screenX: (Double) -> Float, screenY: (Double) -> Float
    ) {
        let matches = session.matches(onPage: page)
        let selected = session.selectedRange(onPage: page)
        guard !matches.isEmpty || selected != nil, let text = session.text(page: page) else { return }

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
        if let selected { fill(text.boxes(for: selected), Palette.selection) }
    }

    // MARK: - Scrollbar

    private enum Scrollbar {
        static let width: Float = 6
        /// Wider than it is drawn, so it can be hit without aiming.
        static let hitWidth: Float = 14
        static let minThumb: Float = 32
        /// Space the edges keep from each other, and the corner the vertical
        /// bar leaves the horizontal one.
        static let inset: Float = 3
    }

    enum Axis { case vertical, horizontal }

    /// Where a thumb is along its track, in canvas-local pixels, or nil when
    /// that axis does not scroll. Both tracks stop short of the corner while
    /// the other bar is showing, so the two thumbs never overlap.
    private func scrollbar(
        _ axis: Axis, in frame: CanvasFrame
    ) -> (start: Float, length: Float, track: Float)? {
        let zoom = session.viewport.zoom
        let contentH = session.layout.height * zoom
        let contentW = session.layout.width * zoom
        let scrollsY = contentH > Double(frame.h)
        let scrollsX = contentW > Double(frame.w)
        let content = axis == .vertical ? contentH : contentW
        let window = axis == .vertical ? frame.h : frame.w
        let offset = axis == .vertical ? session.viewport.scrollY : session.viewport.scrollX
        guard content > Double(window), content > 0 else { return nil }
        let other = axis == .vertical ? scrollsX : scrollsY
        let track = window - (other ? Scrollbar.hitWidth : 0)
        let share = Float(Double(window) / content)
        let length = max(Scrollbar.minThumb, track * share)
        let fraction = Float(offset / (content - Double(window)))
        return ((track - length) * min(max(fraction, 0), 1), length, track)
    }

    /// Dark with a light rim: the thumb sits over white paper as often as
    /// over the mat once a page is wider than the window, and a light thumb
    /// vanished on the paper.
    private func drawScrollbar(_ axis: Axis, _ list: DrawList, _ frame: CanvasFrame) {
        guard let bar = scrollbar(axis, in: frame) else { return }
        let w = Scrollbar.width, i = Scrollbar.inset
        let rect: (x: Float, y: Float, w: Float, h: Float) = axis == .vertical
            ? (frame.x + frame.w - w - i, frame.y + bar.start + 2, w, bar.length - 4)
            : (frame.x + bar.start + 2, frame.y + frame.h - w - i, bar.length - 4, w)
        list.roundedRect(
            x: rect.x - 1, y: rect.y - 1, w: rect.w + 2, h: rect.h + 2,
            color: Palette.scrollRim, radius: w / 2 + 1
        )
        list.roundedRect(
            x: rect.x, y: rect.y, w: rect.w, h: rect.h,
            color: Palette.scrollThumb, radius: w / 2
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
    static let scrollThumb = Color(r: 0.12, g: 0.12, b: 0.14, a: 0.6)
    static let scrollRim = Color(r: 1, g: 1, b: 1, a: 0.45)
    static let warning = Color(r: 0.95, g: 0.55, b: 0.35)
}
