import Foundation
import LavaHost
import LavaPDFCore
import LavaUI
import Observation

/// Everything the window shows: which document, how far down, how big, what is
/// selected and what a search found.
///
/// The repo's usual split: the arithmetic is `LavaPDFCore` and tested there,
/// and this is the part that owns threads, textures and files. Every property
/// is written on the main thread; workers deliver through `MainQueue`.
@Observable
final class ReaderSession: @unchecked Sendable {
    enum ZoomMode: Equatable {
        case fitWidth
        case fitPage
        /// A number the user chose, by wheel or by `+`/`-`.
        case free
    }

    // MARK: - What is open

    private(set) var path: String?
    private(set) var fileName = ""
    private(set) var pageCount = 0
    private(set) var openError: String?
    /// The page under the middle of the window, for the bar. Written from
    /// paint only when it changes, so a scroll within a page rebuilds nothing.
    private(set) var currentPage = 0
    private(set) var mode: ZoomMode = .fitWidth
    private(set) var zoomPercent = 100

    /// The main thread's own copy of the document, for text. Separate from
    /// the workers', because poppler serialises everything on one document,
    /// and a press that waited behind a 200 ms render would feel broken.
    @ObservationIgnored private(set) var document: PDFDocument?
    @ObservationIgnored private(set) var layout = PageLayout(pageSizes: [])
    @ObservationIgnored let tiles: TileStore

    // MARK: - Viewport
    //
    // Not observed: a scroll writes these every notch, and nothing in the
    // bar but the page number and the zoom label is computed from them —
    // and those two are mirrored into observed fields only when they change.

    @ObservationIgnored private(set) var viewport = ReaderViewport()
    @ObservationIgnored private(set) var boxWidth: Double = 0
    @ObservationIgnored private(set) var boxHeight: Double = 0

    // MARK: - Selection

    /// From where a drag started to where it is now, across as many pages as
    /// it crossed — see `DocumentSelection`.
    @ObservationIgnored private(set) var selection: DocumentSelection?
    /// Where the pointer was on the last move of a selecting drag, in the
    /// canvas's own coordinates — outside it, while the drag is scrolling.
    @ObservationIgnored private var dragPointer: (x: Float, y: Float)?
    @ObservationIgnored private var pageText: [Int: PageText] = [:]

    // MARK: - Outline

    private(set) var outline = Outline(items: [])
    var sidebarOpen = false
    private(set) var expanded: Set<Int> = []
    /// The entry for where the top of the window is. Mirrored like the page
    /// number: written only when it changes.
    private(set) var currentSection: Int?

    // MARK: - Links

    @ObservationIgnored private var pageLinks: [Int: [PageLink]] = [:]
    /// Where each followed link was followed from, most recent last, so Back
    /// returns to the paragraph that had the link in it.
    @ObservationIgnored private var history: [ReaderViewport] = []

    // MARK: - Find

    var findOpen = false
    var query = ""
    private(set) var matches: [(page: Int, range: ClosedRange<Int>)] = []
    private(set) var matchIndex: Int?
    /// Still looking through the pages after the first matches arrived.
    private(set) var searching = false
    @ObservationIgnored private var searchGeneration = 0

    init(host: any GPUResourceHost, uploadsOffMain: Bool) {
        // Two workers: enough that a page that takes 200 ms does not hold up
        // the one next to it, few enough that each owns a parsed copy of the
        // document without that being a cost anybody notices.
        tiles = TileStore(host: host, uploadsOffMain: uploadsOffMain, workers: 2)
    }

    // MARK: - Opening

    // MARK: - Passwords

    /// A file that asked for a password and is waiting for one, while the bar
    /// that asks is up.
    private(set) var locked: String?
    /// What is typed into that bar. Cleared the moment it is tried, right or
    /// wrong, so a password never outlives the attempt in the view tree.
    var passwordEntry = ""
    /// The last attempt was wrong — the bar says so instead of just
    /// reappearing empty.
    private(set) var passwordRejected = false
    /// The password that opened the document on screen, for the copies of it
    /// that open later: each render worker's, the glib handle's, a search's.
    /// In memory only, for as long as that document is open; never written
    /// anywhere, and not handed to anything that records what was opened.
    @ObservationIgnored private var password: String?

    func submitPassword() {
        guard let path = locked else { return }
        let attempt = passwordEntry
        passwordEntry = ""
        open(path: path, password: attempt)
    }

    func cancelPassword() {
        locked = nil
        passwordEntry = ""
        passwordRejected = false
    }

    func open(path: String, password: String? = nil) {
        do {
            let document = try PDFDocument(path: path, password: password)
            var workers: [PDFDocument] = []
            for _ in 0..<tiles.workerCount {
                workers.append(try PDFDocument(path: path, password: password))
            }
            self.password = password
            locked = nil
            passwordRejected = false
            self.document = document
            self.path = path
            fileName = document.title ?? (path as NSString).lastPathComponent
            pageCount = document.pageCount
            openError = nil
            layout = PageLayout(pageSizes: document.pageSizes)
            pageText.removeAll()
            pageLinks.removeAll()
            history.removeAll()
            outline = document.outline()
            expanded = outline.initiallyExpanded
            sidebarOpen = !outline.isEmpty
            currentSection = nil
            selection = nil
            clearSearch()
            tiles.reset(documents: workers)
            mode = .fitWidth
            viewport = ReaderViewport()
            applyMode()
            currentPage = 0
            LavaHost.noteOpened(path, appId: "LavaPDF")
        } catch .locked {
            // Asked for rather than reported: a locked file is one the user
            // can open, and the document already on screen, if any, stays
            // there until they do.
            locked = path
            passwordRejected = password != nil
            openError = nil
        } catch {
            openError = switch error {
            case .notFound: "\((path as NSString).lastPathComponent) does not exist"
            case .locked: "\((path as NSString).lastPathComponent) is password-protected"
            case .unreadable: "\((path as NSString).lastPathComponent) is not a PDF this can read"
            }
        }
        ViewInvalidation.markDirty()
    }

    func openDialog() {
        guard let url = FileDialog.openFile(
            title: "Open PDF", filters: [.init(name: "PDF documents", extensions: ["pdf"])]
        ) else { return }
        open(path: url.path)
    }

    var hasDocument: Bool { document != nil }

    // MARK: - The box

    /// Paint reports the canvas size first thing. A fit follows the window;
    /// a free zoom keeps its number and only its scroll is re-clamped.
    func setBox(width: Float, height: Float) {
        let w = Double(width), h = Double(height)
        guard w != boxWidth || h != boxHeight else { return }
        // Keep what was at the top of the window there: a reader resized
        // mid-chapter should not jump back to the start of it.
        let topPoint = viewport.scrollY / viewport.zoom
        boxWidth = w
        boxHeight = h
        if mode != .free {
            viewport.zoom = fittedZoom
            viewport.scrollY = topPoint * viewport.zoom
        }
        settle()
    }

    private var fittedZoom: Double {
        switch mode {
        case .fitWidth: ReaderViewport.fitWidth(layout, boxWidth: boxWidth)
        case .fitPage: ReaderViewport.fitPage(layout, boxWidth: boxWidth, boxHeight: boxHeight)
        case .free: viewport.zoom
        }
    }

    // MARK: - Moving

    /// One wheel notch scrolls this many pixels — the renderer's own detent
    /// (`kPixelsPerNotch`), so the reader scrolls at the speed every other
    /// list on the desktop does.
    static let pixelsPerNotch = 72.0

    func wheel(dx: Float, dy: Float, atX x: Float, atY y: Float) {
        guard hasDocument else { return }
        if ScrollRouter.controlHeld {
            // 10% a notch, at the pointer. Multiplicative, so a zoom feels the
            // same at 50% as at 400%.
            zoom(to: viewport.zoom * pow(1.1, Double(dy)), anchorX: Double(x), anchorY: Double(y))
            return
        }
        // A wheel has only a Y axis; Shift turns it sideways, as everywhere.
        if ScrollRouter.shiftHeld {
            scroll(dx: -Double(dy) * Self.pixelsPerNotch, dy: 0)
        } else {
            scroll(dx: -Double(dx) * Self.pixelsPerNotch, dy: -Double(dy) * Self.pixelsPerNotch)
        }
    }

    func scroll(dx: Double, dy: Double) {
        viewport.scrollX += dx
        viewport.scrollY += dy
        settle()
    }

    /// A screenful, less a line's worth so the reader keeps their place.
    func page(_ direction: Int) {
        scroll(dx: 0, dy: Double(direction) * max(boxHeight - Self.pixelsPerNotch, boxHeight / 2))
    }

    func goTo(page: Int) {
        viewport = viewport.showing(
            page: min(max(0, page), pageCount - 1), layout, boxWidth: boxWidth, boxHeight: boxHeight
        )
        settle()
    }

    func goToStart() { viewport.scrollY = 0; settle() }
    func goToEnd() { viewport.scrollY = .infinity; settle() }

    /// Scrollbar drag: `fraction` of the way down the column.
    func scroll(toFraction fraction: Double) {
        let travel = layout.height * viewport.zoom - boxHeight
        viewport.scrollY = max(0, travel) * min(max(fraction, 0), 1)
        settle()
    }

    // MARK: - Zoom

    func setMode(_ next: ZoomMode) {
        mode = next
        applyMode()
    }

    /// `+`/`-`: the ladder, about the middle of the window.
    func stepZoom(_ direction: Int) {
        zoom(to: ReaderViewport.stepped(viewport.zoom, by: direction),
             anchorX: boxWidth / 2, anchorY: boxHeight / 2)
    }

    func actualSize() {
        zoom(to: ReaderViewport.actualSize, anchorX: boxWidth / 2, anchorY: boxHeight / 2)
    }

    private func zoom(to zoom: Double, anchorX: Double, anchorY: Double) {
        guard hasDocument else { return }
        mode = .free
        viewport = viewport.zoomed(
            to: zoom, anchorX: anchorX, anchorY: anchorY, layout,
            boxWidth: boxWidth, boxHeight: boxHeight
        )
        settle()
    }

    private func applyMode() {
        guard boxWidth > 0, mode != .free else { return settle() }
        let topPoint = viewport.scrollY / viewport.zoom
        viewport.zoom = fittedZoom
        viewport.scrollY = topPoint * viewport.zoom
        settle()
    }

    /// Clamps, and mirrors into the observed labels whatever changed. Every
    /// move ends here.
    private func settle() {
        viewport = viewport.clamped(layout, boxWidth: boxWidth, boxHeight: boxHeight)
        // On the tile grid's own steps and on whole pixels, or the tiles
        // rendered for this zoom are drawn a hair off their size, or between
        // two pixels, and resampled: the softness rendering at the exact zoom
        // exists to avoid.
        viewport.zoom = TileGrid.scale(ofKey: TileGrid.scaleKey(forScale: viewport.zoom))
        viewport.scrollX = viewport.scrollX.rounded()
        viewport.scrollY = viewport.scrollY.rounded()
        let percent = viewport.percent
        let page = viewport.currentPage(layout, boxWidth: boxWidth, boxHeight: boxHeight)
        guard percent != zoomPercent || page != currentPage || sectionChanged() else {
            ViewInvalidation.markNeedsRedraw()
            return
        }
        zoomPercent = percent
        currentPage = page
        updateSection()
        // Raised by hand, not left to observation: `setBox` gets here from
        // paint, and a write made while painting does not schedule the body
        // pass the bar needs. Raising it is not enough on its own either — the
        // loop parks once this frame is out, and a pending level is not a
        // wake — so ask for the iteration that will act on it.
        ViewInvalidation.markDirty()
        FrameScheduler.requestWake(in: 0)
    }

    // MARK: - Outline

    /// The section at the top of the window — a little below it, so a heading
    /// that has just scrolled into the first line counts as the one you are
    /// reading.
    private func section() -> Int? {
        guard !outline.isEmpty, !layout.frames.isEmpty else { return nil }
        let top = viewport.visible(layout, boxWidth: boxWidth, boxHeight: boxHeight).y + 24 / viewport.zoom
        let pages = layout.pages(intersecting: Box(x: 0, y: top, width: 1, height: 1))
        let page = pages.isEmpty ? min(layout.frames.count - 1, max(0, currentPage)) : pages.lowerBound
        return outline.current(page: page, y: top - layout.frames[page].y)
    }

    private func sectionChanged() -> Bool { section() != currentSection }

    private func updateSection() {
        let next = section()
        if next != currentSection { currentSection = next }
    }

    func toggleSidebar() {
        sidebarOpen.toggle()
    }

    func toggleExpanded(_ index: Int) {
        if expanded.contains(index) { expanded.remove(index) } else { expanded.insert(index) }
    }

    /// The rows the sidebar shows — with the current section's parents opened,
    /// so where you are is always somewhere you can see.
    var visibleOutlineRows: [Int] {
        var open = expanded
        if let currentSection { open.formUnion(outline.ancestors(of: currentSection)) }
        return outline.visible(expanded: open)
    }

    func choose(outlineItem index: Int) {
        guard outline.items.indices.contains(index), let target = outline.items[index].target
        else { return }
        follow(target, remember: false)
    }

    // MARK: - Links

    func links(page: Int) -> [PageLink] {
        if let known = pageLinks[page] { return known }
        guard let document else { return [] }
        let links = document.links(page: page)
        pageLinks[page] = links
        return links
    }

    /// The link under a window position, if any.
    func link(atX x: Float, y: Float) -> PageLink? {
        guard let hit = pagePoint(x: x, y: y) else { return nil }
        return links(page: hit.page).link(atX: hit.x, y: hit.y)
    }

    /// Goes where `target` says: somewhere in this document, scrolled so the
    /// place is near the top; or a web address, handed to the desktop.
    func follow(_ target: PDFTarget, remember: Bool = true) {
        switch target {
        case .page(let page, let x, let y):
            guard layout.frames.indices.contains(page) else { return }
            if remember {
                history.append(viewport)
                if history.count > 64 { history.removeFirst() }
            }
            let frame = layout.frames[page]
            // A little room above the place, as a heading is meant to be read.
            viewport.scrollY = (frame.y + (y ?? 0)) * viewport.zoom - (y == nil ? 12 : 24)
            if let x, mode == .free {
                viewport.scrollX = (frame.x + x) * viewport.zoom - 24
            }
            settle()
        case .uri(let uri):
            open(uri: uri)
        }
    }

    /// Back to where the last followed link was followed from.
    func goBack() {
        guard let previous = history.popLast() else { return }
        viewport.scrollX = previous.scrollX
        viewport.scrollY = previous.scrollY * viewport.zoom / previous.zoom
        settle()
    }

    /// Web and mail addresses only. A PDF is somebody else's file, and
    /// `xdg-open` on whatever scheme it names — `file:`, `smb:`, a custom
    /// handler — is a document deciding what to run.
    private func open(uri: String) {
        guard let url = URL(string: uri), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme)
        else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xdg-open", url.absoluteString]
        try? process.run()
    }

    // MARK: - Text

    /// The text of `page`, read once and kept. A few milliseconds a page, on
    /// the main thread's own document, so it never waits behind a render.
    func text(page: Int) -> PageText? {
        if let known = pageText[page] { return known }
        guard let document else { return nil }
        let text = document.text(page: page)
        pageText[page] = text
        return text
    }

    /// Where a window position lands: the page and the point on it.
    func pagePoint(x: Float, y: Float) -> (page: Int, x: Double, y: Double)? {
        let point = viewport.documentPoint(layout, boxWidth: boxWidth, x: Double(x), y: Double(y))
        guard let page = layout.page(atX: point.x, y: point.y) else { return nil }
        let frame = layout.frames[page]
        return (page, point.x - frame.x, point.y - frame.y)
    }

    /// The character a drag at a window position means: on the page under
    /// it, or — in a gap, a margin, or past the window's edge while the drag
    /// scrolls — the nearest page, with the point clamped onto it. Nil only
    /// when that page has no text.
    private func position(x: Float, y: Float) -> TextPosition? {
        let point = viewport.documentPoint(layout, boxWidth: boxWidth, x: Double(x), y: Double(y))
        guard let page = layout.nearestPage(toY: point.y),
              let text = text(page: page), !text.isEmpty
        else { return nil }
        let frame = layout.frames[page]
        let px = min(max(point.x - frame.x, 0), frame.width)
        // Above a page is its start and below it is its end, whatever the
        // nearest line says — a drag that has left the bottom of a page has
        // selected all of it, not just as far as the nearest word.
        if point.y < frame.y { return TextPosition(page: page, index: 0) }
        if point.y > frame.maxY { return TextPosition(page: page, index: text.characters.count - 1) }
        guard let index = text.index(nearestX: px, y: point.y - frame.y) else { return nil }
        return TextPosition(page: page, index: index)
    }

    func beginSelection(x: Float, y: Float, clickCount: Int) {
        guard let hit = pagePoint(x: x, y: y),
              let text = text(page: hit.page),
              let index = text.index(nearestX: hit.x, y: hit.y)
        else {
            clearSelection()
            return
        }
        if clickCount >= 2, let word = text.word(containing: index) {
            selection = DocumentSelection(
                anchor: TextPosition(page: hit.page, index: word.lowerBound),
                head: TextPosition(page: hit.page, index: word.upperBound)
            )
        } else {
            let at = TextPosition(page: hit.page, index: index)
            selection = DocumentSelection(anchor: at, head: at)
            // Nothing selected until the pointer moves: a plain click is a
            // click, not a one-character selection.
            pressOnly = true
        }
        dragPointer = (x, y)
        ViewInvalidation.markNeedsRedraw()
    }

    @ObservationIgnored private var pressOnly = false

    func extendSelection(x: Float, y: Float) {
        guard var current = selection else { return }
        dragPointer = (x, y)
        // A page with no text — a scan, a full-page figure — holds the head
        // where it was rather than losing the selection.
        guard let head = position(x: x, y: y) else { return }
        pressOnly = false
        current.head = head
        selection = current
        ViewInvalidation.markNeedsRedraw()
    }

    func endSelection() {
        if pressOnly { selection = nil }
        pressOnly = false
        dragPointer = nil
        // The primary selection, as every X and Wayland reader does: select,
        // then middle-click into a terminal.
        if let text = selectedText { ClipboardBridge.primaryWriter?(text) }
        ViewInvalidation.markNeedsRedraw()
    }

    func clearSelection() {
        selection = nil
        pressOnly = false
        dragPointer = nil
        ViewInvalidation.markNeedsRedraw()
    }

    /// A selecting drag held past the top or bottom of the window scrolls,
    /// faster the further out it is, and keeps going while the pointer rests
    /// there — which sends no events, so paint drives it: this is called once
    /// a frame, and says whether to ask for the next.
    ///
    /// Without it a selection could never be longer than a window, and a page
    /// is usually taller than one.
    func autoScroll(now: Double) -> Bool {
        // Plain storage, not `@DrawState`: written every frame of a scroll,
        // and a draw-state write from paint asks for the frame being painted.
        let elapsed = lastAutoScroll.map { now - $0 } ?? 1.0 / 60
        lastAutoScroll = nil
        guard let pointer = dragPointer, selection != nil, !pressOnly else { return false }
        let past: Double
        if pointer.y < 0 { past = Double(pointer.y) }
        else if Double(pointer.y) > boxHeight { past = Double(pointer.y) - boxHeight }
        else { return false }
        // Pixels a second: a crawl just past the edge, a page a second at
        // a couple of hundred pixels out.
        let speed = past.sign == .minus ? -min(4000, 120 + 10 * -past) : min(4000, 120 + 10 * past)
        let before = viewport.scrollY
        viewport.scrollY += speed * min(elapsed, 0.05)
        settle()
        // At either end of the document there is nowhere to go, and asking
        // for another frame would spin.
        guard viewport.scrollY != before else { return false }
        lastAutoScroll = now
        extendSelection(x: pointer.x, y: pointer.y)
        return true
    }

    @ObservationIgnored private var lastAutoScroll: Double?

    /// The text on `page` that is selected, if any.
    func selectedRange(onPage page: Int) -> ClosedRange<Int>? {
        guard let selection, selection.pages.contains(page), let text = text(page: page)
        else { return nil }
        return selection.range(onPage: page, count: text.characters.count)
    }

    /// What a copy puts on the clipboard: each page's part, a line break
    /// between pages. Reads the text of every page the selection covers, so a
    /// select-all of a long document pays for that here, once.
    var selectedText: String? {
        guard let selection else { return nil }
        var parts: [String] = []
        for page in selection.pages {
            guard let text = text(page: page),
                  let range = selection.range(onPage: page, count: text.characters.count)
            else { continue }
            parts.append(text.text(in: range))
        }
        let copied = parts.joined(separator: "\n")
        return copied.isEmpty ? nil : copied
    }

    func copySelection() {
        guard let text = selectedText else { return }
        ClipboardBridge.writer?(text)
    }

    /// Ctrl+A: the whole document, stated without reading any of it — the
    /// text is read when it is drawn or copied.
    func selectAll() {
        guard pageCount > 0 else { return }
        selection = .all(pageCount: pageCount)
        ViewInvalidation.markNeedsRedraw()
    }

    // MARK: - Find

    func openFind() {
        findOpen = true
    }

    func closeFind() {
        findOpen = false
        clearSearch()
        ViewInvalidation.markNeedsRedraw()
    }

    private func clearSearch() {
        searchGeneration += 1
        matches = []
        matchIndex = nil
        searching = false
    }

    /// Enter in the find field: search afresh for a new query, otherwise step
    /// to the next match.
    func findNext(_ direction: Int = 1) {
        guard hasDocument, !query.isEmpty else { return }
        if query != searchedQuery {
            search(query)
            return
        }
        guard !matches.isEmpty else { return }
        let count = matches.count
        matchIndex = ((matchIndex ?? (direction > 0 ? -1 : 0)) + direction + count) % count
        reveal(matchIndex!)
    }

    @ObservationIgnored private var searchedQuery = ""

    /// Every page, on a worker with a document of its own, matches arriving
    /// a page at a time so the first is shown before the last page is read.
    private func search(_ needle: String) {
        guard let path else { return }
        let password = password
        clearSearch()
        searchedQuery = needle
        searching = true
        let generation = searchGeneration
        let pages = pageCount
        // Strong: the session lives as long as the window, and a weak
        // capture cannot cross into the posts below in Swift 6.
        Thread.detachNewThread { [self] in
            guard let document = try? PDFDocument(path: path, password: password) else {
                MainQueue.async { [self] in searching = false }
                return
            }
            for page in 0..<pages {
                let found = document.text(page: page).find(needle)
                guard !found.isEmpty else { continue }
                MainQueue.async { [self] in
                    guard searchGeneration == generation else { return }
                    let first = self.matches.isEmpty
                    self.matches.append(contentsOf: found.map { (page, $0) })
                    if first {
                        self.matchIndex = 0
                        self.reveal(0)
                    }
                    ViewInvalidation.markNeedsRedraw()
                }
            }
            MainQueue.async { [self] in
                guard searchGeneration == generation else { return }
                searching = false
            }
        }
    }

    private func reveal(_ index: Int) {
        let match = matches[index]
        guard let text = text(page: match.page),
              let box = text.boxes(for: match.range).first
        else { return }
        let frame = layout.frames[match.page]
        let documentBox = Box(x: frame.x + box.x, y: frame.y + box.y, width: box.width, height: box.height)
        viewport = viewport.revealing(documentBox, layout, boxWidth: boxWidth, boxHeight: boxHeight)
        settle()
    }

    /// Matches on `page`, and which of them — if any — is the current one.
    func matches(onPage page: Int) -> [(range: ClosedRange<Int>, current: Bool)] {
        guard !matches.isEmpty else { return [] }
        var result: [(range: ClosedRange<Int>, current: Bool)] = []
        for (index, match) in matches.enumerated() where match.page == page {
            result.append((match.range, index == matchIndex))
        }
        return result
    }

    var findStatus: String {
        if query.isEmpty || query != searchedQuery { return "" }
        if matches.isEmpty { return searching ? "Searching…" : "No matches" }
        let position = (matchIndex ?? 0) + 1
        return searching ? "\(position) of \(matches.count)…" : "\(position) of \(matches.count)"
    }
}
