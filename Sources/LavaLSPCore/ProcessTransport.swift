import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class ProcessTransport: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let writer = DispatchQueue(label: "LavaLSP.stdin")
    private let stderr = StderrTail()

    var stderrLog: String { stderr.text }

    init(command: [String], root: URL,
         receive: @escaping @Sendable (JSON) -> Void,
         fail: @escaping @Sendable (String) -> Void,
         exited: @escaping @Sendable (ServerExit) -> Void) throws {
        guard let executable = command.first, !executable.isEmpty else { throw LSPClientError.emptyCommand }
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable, relativeTo: root).absoluteURL
            process.arguments = Array(command.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
        }
        process.currentDirectoryURL = root
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let readers = DispatchGroup()
        readers.enter()
        readers.enter()
        process.terminationHandler = { process in
            let status = ServerExit(status: process.terminationStatus,
                                    signaled: process.terminationReason == .uncaughtSignal)
            Thread.detachNewThread {
                // Deliver replies already in the pipe before failing pending requests.
                // A descendant may have inherited a pipe, so EOF gets a deadline.
                _ = readers.wait(timeout: .now() + .milliseconds(500))
                exited(status)
            }
        }
        try process.run()

        let stdout = output.fileHandleForReading
        Thread.detachNewThread {
            defer {
                try? stdout.close()
                readers.leave()
            }
            var framer = LSPFramer()
            do {
                try Self.read(stdout) { bytes in
                    try framer.append(bytes) { body in
                        receive(try JSONDecoder().decode(JSON.self, from: body))
                    }
                }
            } catch {
                fail(String(describing: error))
            }
        }

        let diagnostics = errors.fileHandleForReading
        let tail = stderr
        Thread.detachNewThread {
            defer {
                try? diagnostics.close()
                readers.leave()
            }
            try? Self.read(diagnostics) { tail.append($0) }
        }
    }

    func send(_ message: JSON, fail: @escaping @Sendable (String) -> Void) {
        let handle = input.fileHandleForWriting
        writer.async {
            // A server can exit between queuing a write and reaching the pipe.
            var blocked = sigset_t()
            var previous = sigset_t()
            sigemptyset(&blocked)
            sigaddset(&blocked, SIGPIPE)
            pthread_sigmask(SIG_BLOCK, &blocked, &previous)
            defer {
                var pending = sigset_t()
                sigpending(&pending)
                if sigismember(&pending, SIGPIPE) == 1 && sigismember(&previous, SIGPIPE) == 0 {
                    var signal: Int32 = 0
                    sigwait(&blocked, &signal)
                }
                pthread_sigmask(SIG_SETMASK, &previous, nil)
            }
            do {
                let body = try JSONEncoder().encode(message)
                try handle.write(contentsOf: LSPFramer.frame(body))
            } catch {
                fail(String(describing: error))
            }
        }
    }

    func closeInput() {
        let handle = input.fileHandleForWriting
        writer.async { try? handle.close() }
    }

    func kill() {
        if process.isRunning {
            #if os(Linux)
            _ = Glibc.kill(process.processIdentifier, SIGKILL)
            #else
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            #endif
        }
    }

    private static func read(_ handle: FileHandle, receive: (Data) throws -> Void) throws {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            #if os(Linux)
            let count = Glibc.read(handle.fileDescriptor, &buffer, buffer.count)
            #else
            let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            #endif
            if count > 0 {
                try receive(Data(buffer.prefix(count)))
            } else if count == 0 {
                return
            } else if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
}

private final class StderrTail: @unchecked Sendable {
    private static let limit = 64 * 1024
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ chunk: Data) {
        lock.withLock {
            bytes.append(chunk)
            if bytes.count > Self.limit { bytes.removeFirst(bytes.count - Self.limit) }
        }
    }

    var text: String {
        lock.withLock { String(decoding: bytes, as: UTF8.self) }
    }
}
