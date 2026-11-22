import CExtensionHost
import Foundation
import Glibc

/// Generate and reserve the token under the invocation table's lock.
func invocationToken<Value>(excluding active: [UInt64: Value]) -> UInt64 {
    var token: UInt64
    repeat { token = .random(in: 1 ... UInt64.max) } while active[token] != nil
    return token
}

enum ExtensionHost {
    private static let registry = NSLock()
    nonisolated(unsafe) private static var discovery: [String: Worker] = [:]

    static func entryPoint(_ args: [String]) -> Int32? {
        guard let mode = args.first, ["--extension-worker", "--extension-supervisor"].contains(mode) else { return nil }
        guard args.count == 2 else { return 2 }
        return mode == "--extension-worker" ? lava_extension_worker(args[1]) : lava_extension_supervise(args[1])
    }

    static func reload() {
        let retired = registry.withLock {
            let old = discovery
            discovery.removeAll()
            return old
        }
        DispatchQueue.global(qos: .utility).async { for worker in retired.values { worker.retire() } }
    }

    static func invoke(_ installed: InstalledCommand, reference: String, invocation: UInt64,
                       timeoutMS: Int32, reuse: Bool = false) throws {
        let worker: Worker
        if reuse {
            worker = registry.withLock {
                if let existing = discovery[installed.extensionID] { return existing }
                let new = Worker()
                discovery[installed.extensionID] = new
                return new
            }
        } else { worker = Worker() }
        try worker.call(installed, reference: reference, token: invocation, timeoutMS: timeoutMS, reuse: reuse)
    }

    private final class Worker: @unchecked Sendable {
        private let lock = NSLock()
        private var process: LavaExtensionProcess?
        private var library: URL?
        private var identity: stat?

        deinit { close() }
        func retire() { lock.withLock { close() } }

        private func close() {
            if let process { lava_extension_close(process) }
            process = nil
        }

        private func start(_ url: URL) throws -> LavaExtensionProcess {
            var info = stat()
            guard stat(url.path, &info) == 0 else {
                let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
                close()
                throw failure
            }
            if let process, lava_extension_connected(process) != 0, library == url, let identity,
               identity.st_dev == info.st_dev, identity.st_ino == info.st_ino,
               identity.st_size == info.st_size, identity.st_mtim.tv_sec == info.st_mtim.tv_sec,
               identity.st_mtim.tv_nsec == info.st_mtim.tv_nsec { return process }
            close()
            var handle = LavaExtensionProcess()
            let error = lava_extension_start(url.path, &handle)
            guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
            process = handle
            identity = info
            library = url
            return handle
        }

        func call(_ installed: InstalledCommand, reference: String, token: UInt64,
                  timeoutMS: Int32, reuse: Bool) throws {
            try lock.withLock {
                let process = try start(installed.library)
                var status: Int32 = 0
                var reusable: Int32 = 0
                let error = lava_extension_invoke(process, installed.command.id, reference, token, timeoutMS,
                                                  reuse ? 1 : 0, &status, &reusable)
                if reusable == 0 || error != 0 || status != 0 { close() }
                if error == ETIMEDOUT { throw SelectionExtension.Failure(message: "Extension timed out.") }
                guard error == 0 else { throw SelectionExtension.Failure(message: "Extension host disconnected: " + String(cString: strerror(error))) }
                guard status == 0 else { throw SelectionExtension.Failure(message: "Extension command failed (status \(status)).") }
            }
        }
    }
}
