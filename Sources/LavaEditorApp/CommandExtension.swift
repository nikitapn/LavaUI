import Foundation
#if canImport(LavaEditorExtensionAPI)
import LavaEditorExtensionAPI
import LavaClient
import NPRPC
#endif

/// `"kind": "command"`: an extension command that is not tied to a selection
/// or a preview. It reads the tab in front (`CommandHost.ReadContext`) and
/// asks for things — edits, files opened, a message — which are collected
/// while it runs and done by the editor after it returns, on the main
/// thread, where the editor is.
enum CommandExtension {
    /// What the command asked for.
    struct Outcome {
        /// The whole document after its edits, with the snapshot it was
        /// computed against.
        var edited: (documentID: Int, revision: Int, text: String)?
        var opens: [(path: String, line: Int)] = []
        var message: String?
    }

    /// The tab in front, as the command will see it.
    struct Context {
        var documentID: Int
        var revision: Int
        var path: String
        var language: String
        var projectRoot: String
        /// Nil for a tab with nothing to act on, or one over the limit.
        var text: String?
        var selection: Range<Int>
        var caret: Int
    }

    #if canImport(LavaEditorExtensionAPI)
    private static let host = Result<(Host, String), Error> {
        let poa = try ClientRpcRuntime.start().createPoa(maxObjects: 1)
        let service = Host()
        let id = try poa.activateObject(service, flags: .shm)
        guard let object = NPRPCObject.fromObjectId(id) else {
            throw SelectionExtension.Failure(message: "Invalid command reference.")
        }
        return (service, object.toString())
    }
    #endif

    /// Runs `installed` against `context`. Blocking: call it off the main
    /// thread. A command may take longer than a formatter — it may run a
    /// tool — so it gets 30 seconds rather than 5.
    static func run(_ installed: InstalledCommand, context: Context) throws -> Outcome {
        #if canImport(LavaEditorExtensionAPI)
        let (service, reference) = try host.get()
        let invocation = service.begin(context)
        defer { service.finish(invocation) }
        try ExtensionHost.invoke(installed, reference: reference, invocation: invocation, timeoutMS: 30_000)
        return service.outcome(for: invocation) ?? Outcome()
        #else
        throw SelectionExtension.Failure(message: "Editor extensions require an NPRPC-enabled build.")
        #endif
    }
}

#if canImport(LavaEditorExtensionAPI)
private final class Host: CommandHostServant, @unchecked Sendable {
    private struct Invocation {
        let context: CommandContext
        var outcome = CommandExtension.Outcome()
    }

    private let lock = NSLock()
    private var active: [UInt64: Invocation] = [:]

    func begin(_ context: CommandExtension.Context) -> UInt64 {
        let text = context.text ?? ""
        // Offsets go out as UTF-8 bytes, which is what an extension can
        // slice without walking characters.
        func byte(_ character: Int) -> UInt64 {
            guard context.text != nil else { return 0 }
            let index = text.index(text.startIndex, offsetBy: max(0, character), limitedBy: text.endIndex) ?? text.endIndex
            return UInt64(text.utf8.distance(from: text.startIndex, to: index))
        }
        let wire = CommandContext(
            hasDocument: context.text != nil, documentId: UInt64(context.documentID),
            revision: UInt64(context.revision), path: context.path, language: context.language,
            projectRoot: context.projectRoot, text: text,
            selectionStartByte: byte(context.selection.lowerBound),
            selectionEndByte: byte(context.selection.upperBound), caretByte: byte(context.caret)
        )
        return lock.withLock {
            let token = invocationToken(excluding: active)
            active[token] = Invocation(context: wire)
            return token
        }
    }

    func finish(_ invocation: UInt64) {
        lock.withLock { active[invocation] = nil }
    }

    func outcome(for invocation: UInt64) -> CommandExtension.Outcome? {
        lock.withLock { active[invocation]?.outcome }
    }

    override func readContext(invocation: UInt64) throws -> CommandContext {
        try lock.withLock {
            guard let item = active[invocation] else { throw ExpiredInvocation() }
            return item.context
        }
    }

    override func proposeEdits(invocation: UInt64, documentId: UInt64, revision: UInt64,
                               edits: [SelectionEdit]) -> EditStatus {
        lock.withLock {
            guard let item = active[invocation], item.context.hasDocument,
                  item.context.documentId == documentId, item.context.revision == revision else { return .invalid }
            guard item.outcome.edited == nil else { return .alreadySubmitted }
            guard let text = item.context.applying(edits, limit: SelectionExtension.limit) else { return .invalid }
            active[invocation]?.outcome.edited = (Int(documentId), Int(revision), text)
            return .accepted
        }
    }

    override func openFile(invocation: UInt64, path: String, line: UInt32) -> Bool {
        lock.withLock {
            guard active[invocation] != nil, !path.isEmpty,
                  (active[invocation]?.outcome.opens.count ?? 0) < 16 else { return false }
            active[invocation]?.outcome.opens.append((path, Int(line)))
            return true
        }
    }

    override func showMessage(invocation: UInt64, message: String) -> Bool {
        lock.withLock {
            guard active[invocation] != nil else { return false }
            // One line of a notice bar, not a log.
            active[invocation]?.outcome.message = String(message.prefix(2_000))
            return true
        }
    }
}
#endif
