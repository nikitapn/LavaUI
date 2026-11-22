import Foundation
import Glibc
#if canImport(LavaEditorExtensionAPI)
import LavaEditorExtensionAPI
import LavaClient
import NPRPC
#endif

enum SelectionExtension {
    static let limit = 8 * 1024 * 1024

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    #if canImport(LavaEditorExtensionAPI)
    private static let commands = Result<(FormatterCommands, String), Error> {
        let rpc = try ClientRpcRuntime.start {
            $0.shmChannelSizes(ringBytes: 12 << 20, maxMessageBytes: 9 << 20)
        }
        let poa = try rpc.createPoa(maxObjects: 1)
        let service = FormatterCommands()
        let id = try poa.activateObject(service, flags: .shm)
        guard let object = NPRPCObject.fromObjectId(id) else { throw Failure(message: "Invalid command reference.") }
        return (service, object.toString())
    }
    #endif

    static func start() {
        #if canImport(LavaEditorExtensionAPI)
        // The first runtime builder sets the size for every accepted connection.
        _ = commands
        #endif
    }

    static func run(_ installed: InstalledCommand, text: String, document: Int, revision: Int,
                    startByte: Int) throws -> String {
        #if canImport(LavaEditorExtensionAPI)
        guard text.utf8.count <= limit else { throw Failure(message: "Selection exceeds 8 MiB.") }
        let (service, reference) = try commands.get()
        let snapshot = SelectionSnapshot(documentId: UInt64(document), revision: UInt64(revision),
                                         startByte: UInt64(startByte), endByte: UInt64(startByte + text.utf8.count),
                                         text: text)
        let invocation = service.begin(snapshot)
        defer { service.finish(invocation) }
        try ExtensionHost.invoke(installed, reference: reference, invocation: invocation, timeoutMS: 5_000)
        guard let edit = service.result(for: invocation) else { throw Failure(message: "Formatter submitted no edit.") }
        return edit
        #else
        throw Failure(message: "Editor extensions require an NPRPC-enabled build.")
        #endif
    }
}

#if canImport(LavaEditorExtensionAPI)
private final class FormatterCommands: SelectionCommandServant, @unchecked Sendable {
    private struct Invocation {
        let selection: SelectionSnapshot
        var replacement: String?
    }

    private let lock = NSLock()
    private var active: [UInt64: Invocation] = [:]

    func begin(_ snapshot: SelectionSnapshot) -> UInt64 {
        lock.withLock {
            let token = invocationToken(excluding: active)
            active[token] = Invocation(selection: snapshot)
            return token
        }
    }

    func finish(_ invocation: UInt64) {
        lock.withLock { active[invocation] = nil }
    }

    func result(for invocation: UInt64) -> String? {
        lock.withLock { active[invocation]?.replacement }
    }

    override func readSelection(invocation: UInt64) throws -> SelectionSnapshot {
        try lock.withLock {
            guard let item = active[invocation] else { throw ExpiredInvocation() }
            return item.selection
        }
    }

    override func proposeEdits(invocation: UInt64, documentId: UInt64, revision: UInt64,
                               edits: [SelectionEdit]) -> EditStatus {
        lock.withLock {
            guard let item = active[invocation], item.selection.documentId == documentId,
                  item.selection.revision == revision else { return .invalid }
            guard item.replacement == nil else { return .alreadySubmitted }
            guard let replacement = item.selection.applying(edits, limit: SelectionExtension.limit) else { return .invalid }
            active[invocation]?.replacement = replacement
            return .accepted
        }
    }
}
#endif
