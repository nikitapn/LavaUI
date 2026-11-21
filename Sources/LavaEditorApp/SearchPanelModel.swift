import Foundation
import LavaProjectCore
import LavaUI
import Observation

@Observable
final class SearchPanelModel {
    enum Row {
        case file(Int)
        case line(file: Int, index: Int)
    }

    private(set) var root: URL?
    private(set) var options = ProjectSearchOptions()
    private(set) var result: ProjectSearchResult?
    private(set) var rows: [Row] = []
    private(set) var collapsed: Set<String> = []
    private var searching = false
    private var failure: String?
    var queryFocused = false

    @ObservationIgnored let scroll = ScrollPosition()
    @ObservationIgnored private var request: ProjectSearchCancellation?

    deinit { request?.cancel() }

    func options(for root: URL) -> ProjectSearchOptions {
        self.root == root ? options : ProjectSearchOptions()
    }

    func summary(for root: URL) -> String {
        guard self.root == root, !options.query.isEmpty else { return "Search in project files" }
        if searching { return "Searching…" }
        if let failure { return failure }
        guard let result, result.count > 0 else { return "No results found" }
        let matches = result.count == 1 ? "result" : "results"
        let files = result.files.count == 1 ? "file" : "files"
        let count = "\(result.count.formatted()) \(matches) in \(result.files.count.formatted()) \(files)"
        return result.capped ? "\(count)\nSearch limit reached" : count
    }

    func search(root: URL, options: ProjectSearchOptions, immediate: Bool = false) {
        request?.cancel()
        if self.root != root {
            self.root = root
            collapsed = []
        }
        self.options = options
        result = nil
        rows = []
        failure = nil
        searching = !options.query.isEmpty
        scroll.scroll(to: 0)
        guard searching else {
            request = nil
            return
        }

        let token = ProjectSearchCancellation()
        request = token
        let owner = SearchPanelRef(self)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (immediate ? 0 : 0.25)) {
            let outcome = Result {
                try ProjectSearchEngine.search(root: root, options: options, cancellation: token)
            }
            MainQueue.async {
                guard let model = owner.model, model.request === token else { return }
                model.searching = false
                model.request = nil
                switch outcome {
                case .success(let result):
                    model.result = result
                    model.rebuildRows()
                case .failure(let error):
                    model.failure = error.localizedDescription
                }
            }
        }
    }

    func toggle(_ path: String) {
        if collapsed.remove(path) == nil { collapsed.insert(path) }
        rebuildRows()
    }

    private func rebuildRows() {
        guard let result else { return }
        var next: [Row] = []
        for (index, file) in result.files.enumerated() {
            next.append(.file(index))
            if !collapsed.contains(file.path) {
                next.append(contentsOf: file.lines.indices.map { .line(file: index, index: $0) })
            }
        }
        rows = next
    }
}

/// Only dereferenced in MainQueue.async. A worker must not keep the window
/// alive, or its pending search could never cancel on teardown.
private final class SearchPanelRef: @unchecked Sendable {
    weak var model: SearchPanelModel?
    init(_ model: SearchPanelModel) { self.model = model }
}
