import Foundation
import NPRPC

// Older binaries lack this marker and keep their one-invocation lifetime.
@_cdecl("lava_editor_reusable_host_v1")
public func lavaEditorReusableHostV1() {}

private struct HostRuntime: @unchecked Sendable {
    let rpc: Rpc
    init() throws {
        rpc = try RpcBuilder().setLogLevel(.warn).build()
        try rpc.startThreadPool(2)
    }
}
private let hostRuntime = Result { try HostRuntime() }

/// Bridges a dynamic library activation to its generated Swift editor proxy.
public func runEditorCommand(_ reference: UnsafePointer<CChar>,
                             body: @escaping @Sendable (SelectionCommand) async throws -> Void) -> Int32 {
    runExtension(reference, as: SelectionCommand.self, body: body)
}

/// A general command (`"kind": "command"` in the manifest): reads the tab in
/// front with `readContext`, and may propose edits, open files and show a
/// message — all done by the editor after `body` returns.
public func runCommand(_ reference: UnsafePointer<CChar>,
                       body: @escaping @Sendable (CommandHost) async throws -> Void) -> Int32 {
    runExtension(reference, as: CommandHost.self, body: body)
}

public func runDocumentActionProvider(_ reference: UnsafePointer<CChar>,
    body: @escaping @Sendable (DocumentActionProvider) async throws -> Void) -> Int32 {
    runExtension(reference, as: DocumentActionProvider.self, body: body)
}

public func runMarkdownPreviewProvider(_ reference: UnsafePointer<CChar>,
    body: @escaping @Sendable (MarkdownPreviewProvider) async throws -> Void) -> Int32 {
    runExtension(reference, as: MarkdownPreviewProvider.self, body: body)
}

private func runExtension<T: NPRPCObject & Sendable>(_ reference: UnsafePointer<CChar>, as type: T.Type,
    body: @escaping @Sendable (T) async throws -> Void) -> Int32 {
    do {
        let rpc = try hostRuntime.get().rpc
        guard let object = NPRPCObject.fromString(String(cString: reference)), object.selectEndpoint(),
              let command = narrow(object, to: type) else { return 2 }
        command.timeout = 5_000
        return withExtendedLifetime(rpc) {
            let finished = DispatchSemaphore(value: 0)
            let status = CommandStatus()
            Task.detached {
                do {
                    try await body(command)
                    status.code = 0
                } catch {
                    FileHandle.standardError.write(Data("Extension: \(error)\n".utf8))
                }
                finished.signal()
            }
            finished.wait()
            return status.code
        }
    } catch {
        return 2
    }
}

// The worker publishes this value once before signalling the waiting thread.
private final class CommandStatus: @unchecked Sendable {
    var code: Int32 = 1
}

public func runEmbeddedSurfaceProvider(_ reference: UnsafePointer<CChar>,
    body: @escaping @Sendable (EmbeddedSurfaceProvider) async throws -> Void) -> Int32 {
    runExtension(reference, as: EmbeddedSurfaceProvider.self, body: body)
}
