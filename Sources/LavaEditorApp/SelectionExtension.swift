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

    static func host(_ arguments: [String]) -> Int32 {
        guard arguments.count == 4, let invocation = UInt64(arguments[2]),
              let library = dlopen(arguments[0], RTLD_NOW | RTLD_LOCAL),
              let entry = dlsym(library, "lava_editor_activate_v1") else { return 2 }
        typealias Invoke = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt64) -> Int32
        let activate = unsafeBitCast(entry, to: Invoke.self)
        return arguments[3].withCString { command in
            arguments[1].withCString { activate(command, $0, invocation) }
        }
    }

    static func launch(_ installed: InstalledCommand, reference: String, invocation: UInt64, deadline: String) throws {
        let executable = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/timeout")
        process.arguments = ["--signal=KILL", deadline, executable, "--extension-host", installed.library.path, reference, String(invocation), installed.command.id]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(message: "Extension command failed or timed out (status \(process.terminationStatus)).")
        }
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
        try launch(installed, reference: reference, invocation: invocation, deadline: "5s")
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
    private var nextID: UInt64 = 0

    func begin(_ snapshot: SelectionSnapshot) -> UInt64 {
        lock.withLock {
            nextID += 1
            active[nextID] = Invocation(selection: snapshot)
            return nextID
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
