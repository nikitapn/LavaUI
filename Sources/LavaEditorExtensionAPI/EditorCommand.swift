import Foundation
import NPRPC

/// Bridges the dynamic library entry point to the generated Swift editor proxy.
/// Called once, in a fresh extension host process.
public func runEditorCommand(_ reference: UnsafePointer<CChar>,
                             body: @escaping @Sendable (SelectionCommand) async throws -> Void) -> Int32 {
    runExtension(reference, as: SelectionCommand.self, body: body)
}

public func runDocumentActionProvider(_ reference: UnsafePointer<CChar>,
    body: @escaping @Sendable (DocumentActionProvider) async throws -> Void) -> Int32 {
    runExtension(reference, as: DocumentActionProvider.self, body: body)
}

private func runExtension<T: NPRPCObject & Sendable>(_ reference: UnsafePointer<CChar>, as type: T.Type,
    body: @escaping @Sendable (T) async throws -> Void) -> Int32 {
    do {
        let rpc = try RpcBuilder().setLogLevel(.warn).build()
        try rpc.startThreadPool(2)
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
