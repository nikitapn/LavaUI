import Foundation
import LavaDiffCore
import LavaUI
#if canImport(LavaEditorExtensionAPI)
import LavaEditorExtensionAPI
import LavaClient
import NPRPC
#endif

extension EditorSession {
    /// The actions to draw. The last answer for this document, moved to
    /// where its lines are now while a new answer is on its way.
    ///
    /// Showing nothing in between is what it used to do, and a hint takes a
    /// row of its own: every keystroke in a test file took every hint away,
    /// moving the code under them up, and a process start later put them
    /// back. Stale actions are drawn but not run — their handlers check the
    /// revision — and an action whose line was deleted is dropped.
    var currentLineActions: [Int: [EditorLineAction]] {
        guard let snapshot = actionSnapshot, snapshot.document == active.id,
              snapshot.path == (active.url?.path ?? "") else { return [:] }
        if snapshot.revision == revision || lineActions.isEmpty { return lineActions }
        if let shifted = shiftedLineActions, shifted.revision == revision { return shifted.actions }
        let diff = TextDiff(old: snapshot.text, new: active.text)
        var moved: [Int: [EditorLineAction]] = [:]
        for (line, actions) in lineActions {
            guard let now = diff.newLine(forOld: line) else { continue }
            moved[now, default: []] += actions
        }
        shiftedLineActions = (revision, moved)
        return moved
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
        let providers = active.preview == nil ? extensions.commands.filter {
            $0.command.kind == .documentActions && $0.command.matches(language: active.language.rawValue, url: active.url)
        } : []
        guard !providers.isEmpty, text.utf8.count <= SelectionExtension.limit else {
            // Nothing to ask: nothing to show, rather than an old answer.
            actionSnapshot = (document, version, path, text)
            lineActions = [:]
            return
        }
        // The snapshot and the actions change together, when the answer
        // arrives — until then the last answer goes on being drawn, moved
        // (see `currentLineActions`).
        scanningActions = true
        let owner = LanguageSessionRef(self)
        DispatchQueue.global(qos: .utility).async {
            var discovered: [(InstalledCommand, DocumentLineAction)] = []
            var reported: [(InstalledCommand, [ExtensionDiagnostic])] = []
            for provider in providers {
                do {
                    let reply = try LineActionService.invoke(provider, path: path, text: text, action: "")
                    discovered += reply.actions.map { (provider, $0) }
                    if let diagnostics = reply.diagnostics { reported.append((provider, diagnostics)) }
                } catch {
                    FileHandle.standardError.write(Data("\(provider.extensionID): \(error)\n".utf8))
                }
            }
            let results = discovered
            let problems = reported
            MainQueue.async {
                guard let session = owner.session else { return }
                session.scanningActions = false
                // Problems belong to the file, not to the tab in front, so
                // they are kept even when the answer for the tab is stale:
                // they were found in the text it had, and the next pass
                // replaces them.
                if !path.isEmpty {
                    let file = URL(fileURLWithPath: path).standardizedFileURL.path
                    for (provider, diagnostics) in problems {
                        session.problems.publish(
                            Self.problems(diagnostics, path: file, source: provider.command.title),
                            path: file, by: "\(provider.extensionID)/\(provider.command.id)")
                    }
                }
                guard session.active.id == document, session.revision == version,
                      session.active.text == text, session.active.url?.path == path else {
                    session.scheduleLineActionDiscovery()
                    return
                }
                session.actionGeneration &+= 1
                let generation = session.actionGeneration
                var lines: [Int: [EditorLineAction]] = [:]
                for (provider, action) in results {
                    lines[Int(action.line), default: []].append(EditorLineAction(gutterPlay: action.gutterPlay, hint: action.hint) { [weak session] in
                        guard let session, session.actionGeneration == generation, session.active.id == document,
                              session.revision == version, session.active.text == text, session.active.url?.path == path else { return }
                        session.invokeLineAction(provider, path: path, text: text, action: action)
                    })
                }
                session.actionSnapshot = (document, version, path, text)
                session.lineActions = lines
                session.shiftedLineActions = nil
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
        /// Nil when the provider said nothing about problems this time,
        /// which leaves what it said before.
        var diagnostics: [ExtensionDiagnostic]?
    }
    private struct Request {
        let document: ActionDocument
        var reply: Reply?
    }
    private let lock = NSLock()
    private var requests: [UInt64: Request] = [:]

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
            let token = invocationToken(excluding: service.requests)
            service.requests[token] = Request(document: ActionDocument(path: path, text: text, actionId: action))
            return token
        }
        defer { service.lock.withLock { service.requests[invocation] = nil } }
        try ExtensionHost.invoke(provider, reference: reference, invocation: invocation,
                                 timeoutMS: action.isEmpty ? 10_000 : 600_000, reuse: action.isEmpty)
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
            var reply = requests[invocation]?.reply ?? Reply()
            reply.actions = actions
            requests[invocation]?.reply = reply
            return true
        }
    }

    override func setDiagnostics(invocation: UInt64, diagnostics: [ExtensionDiagnostic]) -> Bool {
        lock.withLock {
            guard let request = requests[invocation], request.document.actionId.isEmpty,
                  diagnostics.count <= 10_000 else { return false }
            var reply = request.reply ?? Reply()
            reply.diagnostics = diagnostics
            requests[invocation]?.reply = reply
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
