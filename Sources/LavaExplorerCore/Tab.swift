import Foundation

/// One folder, with its own history. Windows Explorer's tabs are this:
/// switching does not throw away Back, and a second look at Pictures does
/// not steal the first tab's place in Downloads.
public struct ExplorerTab: Equatable, Identifiable, Sendable {
    public let id: Int
    public var history: FolderHistory
    public var listing: FolderListing
    public var selection = FileSelection()
    public var pathDraft: String
    public var showHidden: Bool
    public var sort: FileSort
    public var sortDescending: Bool

    public init(
        id: Int,
        history: FolderHistory,
        listing: FolderListing,
        selected: String? = nil,
        pathDraft: String? = nil,
        showHidden: Bool = false,
        sort: FileSort = .name,
        sortDescending: Bool = false
    ) {
        self.id = id
        self.history = history
        self.listing = listing
        if let selected { selection.select(selected) }
        self.pathDraft = pathDraft ?? listing.path
        self.showHidden = showHidden
        self.sort = sort
        self.sortDescending = sortDescending
    }

    /// The row the keyboard is on. Setting it selects that row alone, which is
    /// what every caller that thinks in one row means.
    public var selected: String? {
        get { selection.lead }
        set {
            if let newValue { selection.select(newValue) } else { selection.clear() }
        }
    }

    /// Selected entries in list order.
    public var selectedEntries: [FileEntry] {
        listing.entries.filter { selection.contains($0.path) }
    }

    public var title: String {
        let path = listing.path
        if TrashPath.isTrash(path) { return "Trash" }
        let name = (path as NSString).lastPathComponent
        if name.isEmpty || path == "/" { return "Computer" }
        return name
    }

    public mutating func reload(from source: any FileSource) {
        listing = FolderListing.load(
            path: history.path,
            source: source,
            showHidden: showHidden,
            sort: sort,
            descending: sortDescending
        )
        pathDraft = listing.path
        selection.keep(only: Set(listing.entries.map(\.path)))
    }

    /// A folder was renamed or moved: this tab follows it if it is in it, or
    /// was, or has rows selected that were. Reloads only when the folder it
    /// shows is one of those. Returns whether anything changed.
    @discardableResult
    public mutating func rebase(from old: String, to new: String, source: any FileSource) -> Bool {
        let before = history
        let selectionBefore = selection
        history.rebase(from: old, to: new)
        selection = selection.mapped { FolderHistory.rebased($0, from: old, to: new) }
        let moved = history.path != before.path
        if moved { reload(from: source) }
        return moved || history != before || selection != selectionBefore
    }

    // MARK: Moving

    /// Where the list should be scrolled after a move.
    public enum ScrollLanding: Equatable, Sendable {
        /// Exactly where it was when this folder was left.
        case offset(Float)
        /// A folder seen fresh starts at its top.
        case top
        /// Wherever shows the selected row — Up, which knows which row but
        /// not where the parent was scrolled.
        case reveal
    }

    /// Opens `path`, remembering this folder as it is — `scroll` is where its
    /// list is. Nil when `path` is where the tab already is and nothing was
    /// selected: that is a reload, and the list stays put.
    @discardableResult
    public mutating func open(
        _ path: String, select: String? = nil, scroll: Float, source: any FileSource
    ) -> ScrollLanding? {
        let leaving = FolderVisit(path: history.path, selection: selection, scrollOffset: scroll)
        if history.visit(path, leaving: leaving) || listing.path != history.path {
            selected = select
            reload(from: source)
            return select == nil ? .top : .reveal
        }
        if let select {
            selected = select
            return .reveal
        }
        reload(from: source)
        return nil
    }

    public mutating func back(scroll: Float, source: any FileSource) -> ScrollLanding? {
        let leaving = FolderVisit(path: history.path, selection: selection, scrollOffset: scroll)
        guard let visit = history.goBack(leaving: leaving) else { return nil }
        return land(on: visit, source: source)
    }

    public mutating func forward(scroll: Float, source: any FileSource) -> ScrollLanding? {
        let leaving = FolderVisit(path: history.path, selection: selection, scrollOffset: scroll)
        guard let visit = history.goForward(leaving: leaving) else { return nil }
        return land(on: visit, source: source)
    }

    /// The parent, with the folder just left selected in it.
    public mutating func up(scroll: Float, source: any FileSource) -> ScrollLanding? {
        guard history.canGoUp else { return nil }
        let child = history.path
        let leaving = FolderVisit(path: child, selection: selection, scrollOffset: scroll)
        history.goUp(leaving: leaving)
        selected = child
        reload(from: source)
        return .reveal
    }

    private mutating func land(on visit: FolderVisit, source: any FileSource) -> ScrollLanding {
        selection = visit.selection
        // The reload drops whatever has gone from the folder since.
        reload(from: source)
        return .offset(visit.scrollOffset)
    }

    /// A tab on `path`, listing already loaded.
    public static func open(
        id: Int, path: String, source: any FileSource,
        showHidden: Bool = false, sort: FileSort = .name, sortDescending: Bool = false
    ) -> ExplorerTab {
        let landing = FolderHistory.landing(argument: path, source: source)
        var tab = ExplorerTab(
            id: id,
            history: FolderHistory(path: landing.directory),
            listing: FolderListing(path: landing.directory),
            selected: landing.select,
            showHidden: showHidden,
            sort: sort,
            sortDescending: sortDescending
        )
        tab.reload(from: source)
        if let select = landing.select,
           tab.listing.entries.contains(where: { $0.path == select })
        {
            tab.selected = select
        }
        return tab
    }
}

/// The strip: which tabs exist and which one is showing.
public struct ExplorerTabs: Equatable, Sendable {
    public private(set) var tabs: [ExplorerTab]
    public private(set) var activeIndex: Int
    private var nextID: Int

    public init(tab: ExplorerTab) {
        self.tabs = [tab]
        self.activeIndex = 0
        self.nextID = tab.id + 1
    }

    public var current: ExplorerTab { tabs[activeIndex] }
    public var currentID: Int { current.id }

    public mutating func updateCurrent(_ body: (inout ExplorerTab) -> Void) {
        body(&tabs[activeIndex])
    }

    public func tab(id: Int) -> ExplorerTab? {
        tabs.first { $0.id == id }
    }

    public mutating func updateTab(id: Int, _ body: (inout ExplorerTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        body(&tabs[index])
    }

    /// Every tab showing `directory`. A folder that changed on disk has to
    /// change wherever it is open, not only in the tab that changed it.
    public mutating func updateTabs(
        showing directory: String, _ body: (inout ExplorerTab) -> Void
    ) {
        for index in tabs.indices where tabs[index].listing.path == directory {
            body(&tabs[index])
        }
    }

    public mutating func select(id: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        activeIndex = index
    }

    /// Inserts after the active tab and selects it.
    public mutating func open(path: String, source: any FileSource) {
        open(path: path, source: source, id: nextID)
    }

    /// The same, under an id the caller allocated.
    ///
    /// A window with several panes numbers tabs for all of them — see
    /// `PaneLayout` — because a tab keeps its id when it moves between panes.
    public mutating func open(path: String, source: any FileSource, id: Int) {
        let base = tabs.isEmpty ? nil : current
        let tab = ExplorerTab.open(
            id: id, path: path, source: source,
            showHidden: base?.showHidden ?? false,
            sort: base?.sort ?? .name,
            sortDescending: base?.sortDescending ?? false
        )
        insert(tab)
    }

    /// Puts `tab` after the active one and selects it.
    public mutating func insert(_ tab: ExplorerTab) {
        let at = tabs.isEmpty ? 0 : min(activeIndex + 1, tabs.count)
        tabs.insert(tab, at: at)
        activeIndex = at
        nextID = max(nextID, tab.id + 1)
    }

    /// Puts `tab` at `index`, clamped to the strip, and selects it.
    public mutating func insert(_ tab: ExplorerTab, at index: Int) {
        let at = min(max(0, index), tabs.count)
        tabs.insert(tab, at: at)
        activeIndex = at
        nextID = max(nextID, tab.id + 1)
    }

    /// Moves a tab into gap `gap` of the strip **as it is now** — 0 before the
    /// first tab, `tabs.count` after the last — and selects it.
    ///
    /// Gaps rather than destination indices because that is what a pointer
    /// over a strip names: the space between two tabs. The two gaps either
    /// side of the tab itself leave it where it is, and say so with false.
    @discardableResult
    public mutating func move(id: Int, toGap gap: Int) -> Bool {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let clamped = min(max(0, gap), tabs.count)
        guard clamped != from, clamped != from + 1 else { return false }
        let tab = tabs.remove(at: from)
        let to = clamped > from ? clamped - 1 : clamped
        tabs.insert(tab, at: to)
        activeIndex = to
        return true
    }

    /// Takes a tab out. Unlike `close`, the strip may be left empty: the pane
    /// holding it decides what an empty strip means.
    public mutating func remove(id: Int) -> ExplorerTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: index)
        if tabs.isEmpty {
            activeIndex = 0
        } else if index < activeIndex {
            activeIndex -= 1
        } else if activeIndex >= tabs.count {
            activeIndex = tabs.count - 1
        }
        return tab
    }

    /// Removes the tab. Returns false when it was the last one, so the
    /// window can close — Explorer closes rather than leaving a blank strip.
    @discardableResult
    public mutating func close(id: Int) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return true }
        if tabs.count == 1 {
            tabs.removeAll()
            activeIndex = 0
            return false
        }
        tabs.remove(at: index)
        if index < activeIndex {
            activeIndex -= 1
        } else if activeIndex >= tabs.count {
            activeIndex = tabs.count - 1
        }
        return true
    }

    public mutating func cycle(by delta: Int) {
        guard !tabs.isEmpty else { return }
        let count = tabs.count
        activeIndex = ((activeIndex + delta) % count + count) % count
    }
}
