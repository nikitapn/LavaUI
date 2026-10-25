import Foundation
import Glibc
import LavaUI

/// One explorer per session for folders asked for by path.
///
/// The panel's Go menu, and anything else that runs `LavaExplorer <path>`,
/// wants that folder *in the explorer* — a new tab in the window already
/// open, not a second window. A second window was worse than untidy: each
/// saves its tabs when it closes, so whichever closed last won, and the
/// other's tabs were gone.
///
/// So a launch with paths first offers them to a running explorer over a
/// Unix socket in `$XDG_RUNTIME_DIR` (mode 0700: nobody else can reach it),
/// one per Wayland session so a nested session's explorer is its own. If one
/// answers, the paths are its now and this process exits; if none does, this
/// one becomes the explorer that answers. A launch with no paths — a second
/// window on purpose — never asks.
enum ExplorerInstance {
    static var socketPath: String? {
        guard let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"],
              !runtime.isEmpty else { return nil }
        let session = ProcessInfo.processInfo.environment["WAYLAND_DISPLAY"] ?? "default"
        let name = session.isEmpty ? "default" : session.replacingOccurrences(of: "/", with: "_")
        return (runtime as NSString).appendingPathComponent("lava-explorer-\(name).sock")
    }

    /// Hands `paths` to a running explorer. True when one took them.
    static func handOff(_ paths: [String]) -> Bool {
        guard !paths.isEmpty, let path = socketPath else { return false }
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard connect(fd, path) else { return false }
        // Absolute, so a relative path means what it meant to the shell
        // that typed it rather than to the other explorer's directory.
        let cwd = FileManager.default.currentDirectoryPath
        let absolute = paths.map { p -> String in
            p.hasPrefix("/") || p.contains("://") ? p : (cwd as NSString).appendingPathComponent(p)
        }
        let message = absolute.joined(separator: "\n") + "\n\n"
        guard writeAll(fd, Array(message.utf8)) else { return false }
        // The answer is the other side having taken them; a socket left by
        // an explorer that crashed accepts nothing.
        var reply = [UInt8](repeating: 0, count: 2)
        return read(fd, &reply, 2) == 2 && reply == Array("ok".utf8)
    }

    /// Starts answering. `open` runs on the main queue with each request's
    /// paths. Quietly does nothing when the socket cannot be made: the
    /// explorer works, and later launches open windows of their own.
    static func listen(_ open: @escaping @Sendable ([String]) -> Void) {
        guard let path = socketPath else { return }
        // An explorer still answering keeps the job: this is a second window
        // opened on purpose, and taking the socket would leave the first one
        // deaf. Only a file nothing listens on — left by an explorer that
        // died — is taken over.
        let probe = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        if probe >= 0 {
            let live = connect(probe, path)
            close(probe)
            if live { return }
        }
        unlink(path)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return }
        guard bind(fd, path), Glibc.listen(fd, 4) == 0 else {
            close(fd)
            return
        }
        // The file goes with the process, however it ends politely.
        atexit { if let path = ExplorerInstance.socketPath { unlink(path) } }
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                let paths = readRequest(client)
                if !paths.isEmpty {
                    _ = writeAll(client, Array("ok".utf8))
                    MainQueue.async { open(paths) }
                }
                close(client)
            }
        }
    }

    // MARK: - Sockets

    private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    private static func connect(_ fd: Int32, _ path: String) -> Bool {
        guard var addr = address(path) else { return false }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    private static func bind(_ fd: Int32, _ path: String) -> Bool {
        guard var addr = address(path) else { return false }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    /// Lines up to an empty one, capped: a request is a few paths, and a
    /// peer that sends megabytes is not one of ours.
    private static func readRequest(_ fd: Int32) -> [String] {
        var data: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 64 * 1024 {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data += buffer[0..<n]
            if data.count >= 2, data[data.count - 2] == 10, data[data.count - 1] == 10 { break }
        }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}
