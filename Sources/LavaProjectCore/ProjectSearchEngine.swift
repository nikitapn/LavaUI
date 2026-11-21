import Foundation
import Glibc

public enum ProjectSearchError: LocalizedError {
    case missingRipgrep
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .missingRipgrep: return "Install ripgrep (rg) to search files."
        case .failed(let message): return message
        }
    }
}

/// One token per request. The child may be blocked reading a file while the
/// worker is blocked on stdout, so cancellation also terminates the child.
public final class ProjectSearchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    public init() {}

    public func cancel() {
        lock.withLock {
            cancelled = true
            if let process { Self.stop(process) }
        }
    }

    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }

    func attach(_ process: Process) {
        lock.withLock {
            self.process = process
            // Cancellation can arrive between run() and attach().
            if cancelled { Self.stop(process) }
        }
    }

    fileprivate static func stop(_ process: Process) {
        // A dispatch worker can launch rg with SIGTERM blocked. There is no
        // output to flush on cancellation, and SIGKILL always wakes the pipe.
        if process.isRunning { _ = Glibc.kill(process.processIdentifier, SIGKILL) }
    }

    func detach() {
        lock.withLock { process = nil }
    }
}

public enum ProjectSearchEngine {
    public static let matchLimit = 10_000

    /// Blocking. Call on a worker, and hand the result back to the UI thread.
    ///
    /// `paths` limits the search to those files, relative to `root` — how one
    /// file is read again after its unsaved edits were saved or thrown away.
    /// Nil walks the whole root.
    public static func search(
        root: URL, options: ProjectSearchOptions,
        cancellation: ProjectSearchCancellation, limit: Int = matchLimit,
        paths: [String]? = nil
    ) throws -> ProjectSearchResult {
        try cancellation.check()
        guard !options.query.isEmpty, paths?.isEmpty != true else { return ProjectSearchResult() }
        guard let executable = findRipgrep() else { throw ProjectSearchError.missingRipgrep }
        return try search(root: root, options: options, cancellation: cancellation,
                          limit: limit, executable: executable, paths: paths)
    }

    static func findRipgrep(path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> URL? {
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent("rg")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func search(
        root: URL, options: ProjectSearchOptions, cancellation: ProjectSearchCancellation,
        limit: Int, executable: URL, paths: [String]? = nil
    ) throws -> ProjectSearchResult {
        try cancellation.check()
        let process = Process()
        let output = Pipe()
        let diagnostics = Pipe()
        process.executableURL = executable
        process.currentDirectoryURL = root
        process.arguments = options.arguments(paths: paths ?? ["."])
        process.standardOutput = output
        process.standardError = diagnostics

        // stderr must drain even if stdout is quiet, or a full error pipe
        // can prevent rg from closing stdout and waking the worker.
        let errors = DiagnosticReader()
        try process.run()
        cancellation.attach(process)
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            errors.drain(diagnostics.fileHandleForReading)
            drained.leave()
        }
        defer {
            ProjectSearchCancellation.stop(process)
            process.waitUntilExit()
            cancellation.detach()
            drained.wait()
        }

        var parser = ProjectSearchOutput(options: options, limit: limit)
        var record = Data()
        let reader = output.fileHandleForReading
        while !parser.result.capped {
            try cancellation.check()
            let chunk = reader.availableData
            guard !chunk.isEmpty else { break }
            var start = chunk.startIndex
            while let end = chunk[start...].firstIndex(of: 0x0a) {
                try cancellation.check()
                record.append(contentsOf: chunk[start..<end])
                try parser.consume(record)
                record.removeAll(keepingCapacity: true)
                start = end + 1
                if parser.result.capped { break }
            }
            record.append(contentsOf: chunk[start...])
        }
        try cancellation.check()
        if parser.result.capped { return parser.finish() }
        if !record.isEmpty { try parser.consume(record) }
        process.waitUntilExit()
        drained.wait()
        try cancellation.check()
        guard process.terminationReason == .exit, process.terminationStatus <= 1 else {
            throw ProjectSearchError.failed(errors.message)
        }
        return parser.finish()
    }
}

private final class DiagnosticReader: @unchecked Sendable {
    // Written by the drain worker and read only after its DispatchGroup ends.
    private var firstLine = Data()
    private var complete = false

    func drain(_ reader: FileHandle) {
        while true {
            let chunk = reader.availableData
            guard !chunk.isEmpty else { return }
            guard !complete else { continue }
            let end = chunk.firstIndex(of: 0x0a) ?? chunk.endIndex
            firstLine.append(contentsOf: chunk[..<end].prefix(512 - firstLine.count))
            complete = end < chunk.endIndex || firstLine.count == 512
        }
    }

    var message: String {
        let text = String(decoding: firstLine, as: UTF8.self)
        return text.isEmpty ? "Search could not be completed." : text
    }
}
