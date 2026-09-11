import Foundation

/// One folder, with its own history. Windows Explorer's tabs are this:
/// switching does not throw away Back, and a second look at Pictures does
/// not steal the first tab's place in Downloads.
public struct ExplorerTab: Equatable, Identifiable, Sendable {
    public let id: Int
    public var history: FolderHistory
    public var listing: FolderListing
    public var selected: String?
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
        self.selected = selected
        self.pathDraft = pathDraft ?? listing.path
        self.showHidden = showHidden
        self.sort = sort
        self.sortDescending = sortDescending
    }

    public var title: String {
        let path = listing.path
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
        if let selected, !listing.entries.contains(where: { $0.path == selected }) {
            self.selected = nil
        }
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
        let tab = ExplorerTab.open(
            id: nextID, path: path, source: source,
            showHidden: current.showHidden,
            sort: current.sort,
            sortDescending: current.sortDescending
        )
        nextID += 1
        let insert = min(activeIndex + 1, tabs.count)
        tabs.insert(tab, at: insert)
        activeIndex = insert
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
