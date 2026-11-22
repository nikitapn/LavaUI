import Foundation
import LavaUI
#if canImport(LavaEditorExtensionAPI)
import LavaEditorExtensionAPI
import LavaClient
import NPRPC
#endif

extension EditorSession {
    var currentLineActions: [Int: [EditorLineAction]] {
        guard let snapshot = actionSnapshot, snapshot.document == active.id, snapshot.revision == revision,
              snapshot.path == (active.url?.path ?? "") else { return [:] }
        return lineActions
    }

    func scheduleLineActionDiscovery() {
        #if canImport(LavaEditorExtensionAPI)
        discoveryTimer?.cancel()
        let owner = LanguageSessionRef(self)
        let timer = DispatchWorkItem {
            MainQueue.async { owner.session?.refreshLineActions() }
        }
        discoveryTimer = timer
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25, execute: timer)
        #endif
    }

    func refreshLineActions() {
        #if canImport(LavaEditorExtensionAPI)
        let path = active.url?.path ?? ""
        let text = active.text
        if let previous = actionSnapshot, previous.document == active.id, previous.revision == revision,
           previous.path == path, previous.text == text { return }
        guard !scanningActions else { return }
        let document = active.id
        let version = revision
        actionGeneration &+= 1
        let generation = actionGeneration
        actionSnapshot = (document, version, path, text)
        lineActions = [:]
        let providers = extensions.commands.filter {
            $0.command.kind == .documentActions && $0.command.matches(language: active.language.rawValue, url: active.url)
        }
        guard !providers.isEmpty, text.utf8.count <= SelectionExtension.limit else { return }
        scanningActions = true
        let owner = LanguageSessionRef(self)
        DispatchQueue.global(qos: .utility).async {
            var discovered: [(InstalledCommand, DocumentLineAction)] = []
            for provider in providers {
                do {
                    let reply = try LineActionService.invoke(provider, path: path, text: text, action: "")
                    discovered += reply.actions.map { (provider, $0) }
                } catch {
                    FileHandle.standardError.write(Data("\(provider.extensionID): \(error)\n".utf8))
                }
            }
            let results = discovered
            MainQueue.async {
                guard let session = owner.session else { return }
                session.scanningActions = false
                guard session.actionSnapshot != nil, session.active.id == document, session.revision == version,
                      session.active.text == text, session.active.url?.path == path else {
                    session.scheduleLineActionDiscovery()
                    return
                }
                var lines: [Int: [EditorLineAction]] = [:]
                for (provider, action) in results {
                    lines[Int(action.line), default: []].append(EditorLineAction(gutterPlay: action.gutterPlay, hint: action.hint) { [weak session] in
                        guard let session, session.actionGeneration == generation, session.active.id == document,
                              session.revision == version, session.active.text == text, session.active.url?.path == path else { return }
                        session.invokeLineAction(provider, path: path, text: text, action: action)
                    })
                }
                session.lineActions = lines
            }
        }
        #endif
    }

    #if canImport(LavaEditorExtensionAPI)
    private func invokeLineAction(_ provider: InstalledCommand, path: String, text: String, action: DocumentLineAction) {
        guard !runningLineAction else { notice = "An extension action is already running."; return }
        runningLineAction = true
        notice = "\(provider.command.title): \(action.id)…"
        let owner = LanguageSessionRef(self)
        DispatchQueue.global(qos: .userInitiated).async {
            let message: String
            do {
                message = try LineActionService.invoke(provider, path: path, text: text, action: action.id).message
            } catch { message = error.localizedDescription }
            MainQueue.async {
                owner.session?.runningLineAction = false
                owner.session?.notice = message
            }
        }
    }
    #endif
}

#if canImport(LavaEditorExtensionAPI)
private final class LineActionService: DocumentActionProviderServant, @unchecked Sendable {
    struct Reply {
        var actions: [DocumentLineAction] = []
        var message = ""
    }
    private struct Request {
        let document: ActionDocument
        var reply: Reply?
    }
    private let lock = NSLock()
    private var requests: [UInt64: Request] = [:]
    private var sequence: UInt64 = 0

    private static let endpoint = Result<(LineActionService, String), Error> {
        let poa = try ClientRpcRuntime.start().createPoa(maxObjects: 1)
        let service = LineActionService()
        let id = try poa.activateObject(service, flags: .shm)
        guard let object = NPRPCObject.fromObjectId(id) else { throw SelectionExtension.Failure(message: "Invalid line action endpoint.") }
        return (service, object.toString())
    }

    static func invoke(_ provider: InstalledCommand, path: String, text: String, action: String) throws -> Reply {
        let (service, reference) = try endpoint.get()
        let invocation = service.lock.withLock {
            service.sequence &+= 1
            service.requests[service.sequence] = Request(document: ActionDocument(path: path, text: text, actionId: action))
            return service.sequence
        }
        defer { service.lock.withLock { service.requests[invocation] = nil } }
        try SelectionExtension.launch(provider, reference: reference, invocation: invocation,
                                      deadline: action.isEmpty ? "10s" : "10m")
        guard let reply = service.lock.withLock({ service.requests[invocation]?.reply }) else {
            throw SelectionExtension.Failure(message: "Extension returned without a result.")
        }
        return reply
    }

    override func readDocument(invocation: UInt64) throws -> ActionDocument {
        try lock.withLock {
            guard let request = requests[invocation] else { throw ExpiredInvocation() }
            return request.document
        }
    }

    override func setLineActions(invocation: UInt64, actions: [DocumentLineAction]) -> Bool {
        lock.withLock {
            guard let request = requests[invocation], request.document.actionId.isEmpty,
                  actions.count <= 16384 else { return false }
            if !actions.isEmpty {
                let lines = request.document.text.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
                guard actions.allSatisfy({ Int($0.line) < lines && !$0.id.isEmpty && $0.id.utf8.count <= 1024
                    && ($0.gutterPlay || !$0.hint.isEmpty) && $0.hint.utf8.count <= 256
                    && !$0.hint.contains(where: \.isNewline) }) else { return false }
            }
            requests[invocation]?.reply = Reply(actions: actions)
            return true
        }
    }

    override func reportResult(invocation: UInt64, message: String) -> Bool {
        lock.withLock {
            guard let request = requests[invocation], !request.document.actionId.isEmpty, message.utf8.count <= 8192 else { return false }
            requests[invocation]?.reply = Reply(message: message)
            return true
        }
    }
}
#endif
