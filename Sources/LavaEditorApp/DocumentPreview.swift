import Foundation
import Observation
import LavaUI
#if canImport(LavaEditorExtensionAPI)
import LavaEditorExtensionAPI
import LavaClient
import NPRPC
#endif

enum PreviewOption {
    case markdown
    case command(InstalledCommand)

    var id: String {
        switch self {
        case .markdown: "preview.markdown"
        case .command(let command): command.menuID
        }
    }

    var title: String {
        switch self {
        case .markdown: "Markdown"
        case .command(let command): command.command.title
        }
    }
}

@Observable
final class DocumentPreview {
    enum Content {
        case markdown(String), message(String)
        #if canImport(LavaEditorExtensionAPI)
        case surface(EmbeddedPreview)
        #endif
    }

    let sourceID: Int
    let optionID: String
    let title: String
    var sourceName: String
    var tabTitle: String { title + " · " + sourceName }
    var content: Content = .message("Loading preview…")
    @ObservationIgnored private var snapshot: (URL?, String)?
    @ObservationIgnored private var generation = 0

    init(source: EditorDocument, option: PreviewOption) {
        sourceID = source.id
        sourceName = source.name
        optionID = option.id
        if case .command(let provider) = option, provider.command.kind == .embeddedSurface {
            title = provider.command.title
        } else { title = "Preview" }
    }

    func invalidate() {
        generation &+= 1
        snapshot = nil
    }

    func refresh(source: EditorDocument, option: PreviewOption?) {
        if sourceName != source.name { sourceName = source.name }
        guard let option else {
            invalidate()
            content = .message("This preview is unavailable for the current file.")
            return
        }
        if let snapshot, snapshot.0 == source.url, snapshot.1 == source.text { return }
        snapshot = (source.url, source.text)
        generation &+= 1
        switch option {
        case .markdown:
            content = .markdown(source.text)
        case .command(let provider):
            #if canImport(LavaEditorExtensionAPI)
            guard source.text.utf8.count <= SelectionExtension.limit else {
                content = .message("Extension previews support documents up to 8 MiB.")
                return
            }
            if provider.command.kind == .embeddedSurface {
                content = .surface(EmbeddedPreview(provider: provider, source: PreviewDocument(
                    path: source.url?.path ?? "", text: source.text)))
                return
            }
            content = .message("Loading preview…")
            let expected = generation
            let input = PreviewDocument(path: source.url?.path ?? "", text: source.text)
            let owner = PreviewRef(self)
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try PreviewService.render(input, using: provider) }
                MainQueue.async {
                    guard let preview = owner.preview, preview.generation == expected else { return }
                    switch result {
                    case .success(let markdown): preview.content = .markdown(markdown)
                    case .failure(let error): preview.content = .message("Preview failed: " + error.localizedDescription)
                    }
                }
            }
            #endif
        }
    }
}

extension EditorSession {
    func previewOptions(for source: EditorDocument) -> [PreviewOption] {
        guard source.preview == nil else { return [] }
        var options: [PreviewOption] = source.language == .markdown ? [.markdown] : []
        #if canImport(LavaEditorExtensionAPI)
        for provider in extensions.commands where [.markdownPreview, .embeddedSurface].contains(provider.command.kind)
            && provider.command.matches(language: source.language.rawValue, url: source.url) {
            options.append(.command(provider))
        }
        #endif
        return options
    }

    func openPreview(of index: Int, using option: PreviewOption) {
        loadIfNeeded(index)
        let source = documents[index]
        guard source.isLoaded else { notice = source.loadError; return }
        keepTabOpen(index)
        if let existing = documents.firstIndex(where: {
            $0.preview?.sourceID == source.id && $0.preview?.optionID == option.id
        }) {
            documents[existing].preview?.invalidate()
            activate(existing)
            refreshActivePreview()
        } else {
            let preview = DocumentPreview(source: source, option: option)
            documents.append(EditorDocument(id: takeID(), url: nil, text: "", preview: preview))
            activate(documents.count - 1)
        }
    }

    func refreshActivePreview() {
        #if canImport(LavaEditorExtensionAPI)
        defer {
            var next: EmbeddedPreview?
            if documents.indices.contains(activeIndex), case .surface(let surface) = documents[activeIndex].preview?.content {
                next = surface
            }
            if next !== visibleSurface {
                visibleSurface?.hide()
                visibleSurface = next
            }
        }
        #endif
        guard documents.indices.contains(activeIndex), let preview = documents[activeIndex].preview,
              let source = documents.first(where: { $0.id == preview.sourceID }) else { return }
        let option = previewOptions(for: source).first { $0.id == preview.optionID }
        preview.refresh(source: source, option: option)
    }
}

#if canImport(LavaEditorExtensionAPI)
private final class PreviewRef: @unchecked Sendable {
    weak var preview: DocumentPreview?
    init(_ preview: DocumentPreview) { self.preview = preview }
}

private final class PreviewService: MarkdownPreviewProviderServant, @unchecked Sendable {
    private struct Request {
        let input: PreviewDocument
        var markdown: String?
    }
    private let lock = NSLock()
    private var requests: [UInt64: Request] = [:]

    private static let endpoint = Result<(PreviewService, String), Error> {
        let poa = try ClientRpcRuntime.start().createPoa(maxObjects: 1)
        let service = PreviewService()
        let id = try poa.activateObject(service, flags: .shm)
        guard let object = NPRPCObject.fromObjectId(id) else {
            throw SelectionExtension.Failure(message: "Invalid preview endpoint.")
        }
        return (service, object.toString())
    }

    static func render(_ input: PreviewDocument, using command: InstalledCommand) throws -> String {
        let (service, reference) = try endpoint.get()
        let token = service.lock.withLock {
            let token = invocationToken(excluding: service.requests)
            service.requests[token] = Request(input: input)
            return token
        }
        defer { service.lock.withLock { service.requests[token] = nil } }
        try ExtensionHost.invoke(command, reference: reference, invocation: token, timeoutMS: 10_000, reuse: true)
        guard let markdown = service.lock.withLock({ service.requests[token]?.markdown }) else {
            throw SelectionExtension.Failure(message: "The extension returned without submitting Markdown.")
        }
        return markdown
    }

    override func readDocument(invocation: UInt64) throws -> PreviewDocument {
        try lock.withLock {
            guard let request = requests[invocation] else { throw ExpiredInvocation() }
            return request.input
        }
    }

    override func setMarkdown(invocation: UInt64, markdown: String) -> Bool {
        lock.withLock {
            guard let request = requests[invocation], request.markdown == nil,
                  markdown.utf8.count <= SelectionExtension.limit else { return false }
            requests[invocation]?.markdown = markdown
            return true
        }
    }
}
#endif
