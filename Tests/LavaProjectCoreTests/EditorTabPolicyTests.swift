import Foundation
import LavaProjectCore
import XCTest

final class EditorTabPolicyTests: XCTestCase {
    private struct Tab: EditorTab {
        let id: Int
        let url: URL?
        var tabState: EditorTabState
        var isModified: Bool

        init(_ id: Int, _ state: EditorTabState = .open, modified: Bool = false) {
            self.id = id
            url = URL(fileURLWithPath: "/project/\(id).swift")
            tabState = state
            isModified = modified
        }
    }

    private let newFile = URL(fileURLWithPath: "/project/new.swift")

    func testPreviewReusesItsSlotAndNormalOpenAppends() {
        let tabs = [Tab(1, .pinned), Tab(2, .preview), Tab(3)]
        XCTAssertEqual(EditorTabPolicy.opening(newFile, mode: .preview, in: tabs), .replacePreview(1))
        XCTAssertEqual(EditorTabPolicy.opening(newFile, mode: .treeClick, in: tabs), .replacePreview(1))
        XCTAssertEqual(EditorTabPolicy.opening(newFile, mode: .normal, in: tabs),
                       .append(.open, keepingPreviewAt: nil))
        XCTAssertEqual(EditorTabPolicy.opening(newFile, mode: .treeDoubleClick, in: tabs),
                       .append(.open, keepingPreviewAt: nil))
        XCTAssertEqual(EditorTabPolicy.opening(newFile, mode: .preview, in: [Tab(1)]),
                       .append(.preview, keepingPreviewAt: nil))
    }

    func testOpeningPreviewKeepsAnEditedBuffer() {
        let tabs = [Tab(1, .pinned), Tab(2, .preview, modified: true)]
        XCTAssertEqual(EditorTabPolicy.opening(newFile, mode: .preview, in: tabs),
                       .append(.preview, keepingPreviewAt: 1))
    }

    func testExistingTabsAreActivatedAndOnlyTreeClicksKeepExistingPreviewsOpen() {
        let tabs = [Tab(1, .pinned), Tab(2, .preview), Tab(3)]
        let previewURL = URL(fileURLWithPath: "/project/folder/../2.swift")
        XCTAssertEqual(EditorTabPolicy.opening(previewURL, mode: .preview, in: tabs),
                       .activate(1, keepOpen: false))
        XCTAssertEqual(EditorTabPolicy.opening(previewURL, mode: .normal, in: tabs),
                       .activate(1, keepOpen: false))
        XCTAssertEqual(EditorTabPolicy.opening(previewURL, mode: .treeClick, in: tabs),
                       .activate(1, keepOpen: true))
        XCTAssertEqual(EditorTabPolicy.opening(previewURL, mode: .treeDoubleClick, in: tabs),
                       .activate(1, keepOpen: true))
        XCTAssertEqual(EditorTabPolicy.opening(tabs[0].url!, mode: .treeClick, in: tabs),
                       .activate(0, keepOpen: false))
        XCTAssertEqual(EditorTabPolicy.opening(tabs[2].url!, mode: .preview, in: tabs),
                       .activate(2, keepOpen: false))
    }

    func testPinningUsesPinOrderAndUnpinningKeepsTheTabOpen() {
        var tabs = [Tab(1, .pinned), Tab(2), Tab(3, .preview), Tab(4)]
        EditorTabPolicy.togglePin(at: 2, in: &tabs)
        EditorTabPolicy.togglePin(at: 3, in: &tabs)
        XCTAssertEqual(tabs.map(\.id), [1, 3, 4, 2])
        XCTAssertEqual(tabs.map(\.tabState), [.pinned, .pinned, .pinned, .open])
        EditorTabPolicy.togglePin(at: 1, in: &tabs)
        XCTAssertEqual(tabs.map(\.id), [1, 4, 3, 2])
        XCTAssertEqual(tabs.map(\.tabState), [.pinned, .pinned, .open, .open])
        XCTAssertEqual(EditorTabPolicy.dragDestination(0, in: Array(tabs.dropLast())), 2)
    }

    func testBulkCloseSkipsPinnedTabsAndIncludesModifiedTabsForTheClosePrompt() {
        let tabs = [Tab(1, .pinned), Tab(2, .pinned), Tab(3), Tab(4, modified: true), Tab(5, .preview)]
        XCTAssertEqual(EditorTabPolicy.closing(.right, from: 2, in: tabs), [4, 5])
        XCTAssertEqual(EditorTabPolicy.closing(.right, from: 0, in: tabs), [3, 4, 5])
        XCTAssertEqual(EditorTabPolicy.closing(.all, from: 2, in: tabs), [3, 4, 5])
        XCTAssertEqual(EditorTabPolicy.closing(.others, from: 3, in: tabs), [3, 5])
    }

    func testRestoringPreservesPinOrderAndOneCleanPreview() {
        let tabs = [Tab(1, .preview, modified: true), Tab(2, .pinned), Tab(3, .preview),
                    Tab(4, .pinned), Tab(5, .preview), Tab(6)]
        let restored = EditorTabPolicy.restored(tabs)
        XCTAssertEqual(restored.map(\.id), [2, 4, 1, 3, 5, 6])
        XCTAssertEqual(restored.map(\.tabState), [.pinned, .pinned, .open, .preview, .open, .open])
        XCTAssertEqual(EditorTabState.preview.keptOpen, .open)
        XCTAssertEqual(EditorTabState.pinned.keptOpen, .pinned)
    }
}
