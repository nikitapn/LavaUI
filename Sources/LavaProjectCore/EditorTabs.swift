import Foundation

public enum EditorTabState: String, Codable, Sendable {
    case open, preview, pinned

    public var keptOpen: Self { self == .preview ? .open : self }
}

public protocol EditorTab: Identifiable {
    var url: URL? { get }
    var isModified: Bool { get }
    var tabState: EditorTabState { get set }
}

public enum EditorTabPolicy {
    public enum OpenMode: Equatable {
        case normal, preview, treeClick, treeDoubleClick
    }

    public enum Opening: Equatable {
        case activate(Int, keepOpen: Bool)
        case append(EditorTabState, keepingPreviewAt: Int?)
        case replacePreview(Int)
    }

    public static func opening<T: EditorTab>(
        _ url: URL, mode: OpenMode, in tabs: [T]
    ) -> Opening {
        if let existing = tabs.firstIndex(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) {
            let fromTree = mode == .treeClick || mode == .treeDoubleClick
            return .activate(existing, keepOpen: fromTree && tabs[existing].tabState == .preview)
        }
        guard mode == .preview || mode == .treeClick else {
            return .append(.open, keepingPreviewAt: nil)
        }
        if let preview = tabs.firstIndex(where: { $0.tabState == .preview }) {
            if tabs[preview].isModified {
                return .append(.preview, keepingPreviewAt: preview)
            }
            return .replacePreview(preview)
        }
        return .append(.preview, keepingPreviewAt: nil)
    }

    /// Restore pin order and keep at most one preview, even in hand-edited snapshots.
    public static func restored<T: EditorTab>(_ tabs: [T]) -> [T] {
        var sawPreview = false
        let normalized = tabs.map { original in
            var tab = original
            if tab.tabState == .preview {
                if sawPreview || tab.isModified { tab.tabState = .open }
                sawPreview = sawPreview || tab.tabState == .preview
            }
            return tab
        }
        return normalized.filter { $0.tabState == .pinned } + normalized.filter { $0.tabState != .pinned }
    }

    public static func togglePin<T: EditorTab>(at index: Int, in tabs: inout [T]) {
        var tab = tabs.remove(at: index)
        tab.tabState = tab.tabState == .pinned ? .open : .pinned
        tabs.insert(tab, at: pinnedCount(in: tabs))
    }

    /// Pinned tabs stay in pin order. Drags of other tabs stop at their edge.
    public static func dragDestination<T: EditorTab>(_ destination: Int, in remaining: [T]) -> Int {
        min(max(pinnedCount(in: remaining), destination), remaining.count)
    }

    public enum BulkClose {
        case right, all, others
    }

    public static func closing<T: EditorTab>(_ action: BulkClose, from index: Int, in tabs: [T]) -> [T.ID] {
        tabs.enumerated().compactMap { offset, tab in
            guard tab.tabState != .pinned else { return nil }
            switch action {
            case .right: return offset > index ? tab.id : nil
            case .all: return tab.id
            case .others: return offset != index ? tab.id : nil
            }
        }
    }

    private static func pinnedCount<T: EditorTab>(in tabs: [T]) -> Int {
        tabs.prefix { $0.tabState == .pinned }.count
    }
}
