import Foundation
import Glibc

/// Owns only children handed to it by DesktopEntry.launch. Other subprocess
/// users (including Foundation.Process) keep their own exit statuses.
final class ChildProcessMonitor: @unchecked Sendable {
    static let shared = ChildProcessMonitor()

    private typealias OpenPIDFD = @convention(c) (pid_t, UInt32) -> Int32
    // Swift's Glibc overlay does not expose pidfd_open. Resolve it at runtime
    // so an older libc or kernel can still use the timed waitpid fallback.
    private let openPIDFD: OpenPIDFD? = {
        guard let symbol = dlsym(nil, "pidfd_open") else { return nil }
        return unsafeBitCast(symbol, to: OpenPIDFD.self)
    }()
    private struct Child {
        let pid: pid_t
        let fd: Int32
    }
    private let lock = NSLock()
    private var pending: [Child] = []
    private let wakeReader: Int32
    private let wakeWriter: Int32

    private init() {
        var ends: [Int32] = [-1, -1]
        if pipe(&ends) == 0 {
            let configured = ends.allSatisfy {
                fcntl($0, F_SETFD, FD_CLOEXEC) == 0
                    && fcntl($0, F_SETFL, O_NONBLOCK) == 0
            }
            if !configured {
                for fd in ends { close(fd) }
                ends = [-1, -1]
            }
        }
        wakeReader = ends[0]
        wakeWriter = ends[1]
        let thread = Thread { [self] in run() }
        thread.name = "LavaChildMonitor"
        thread.start()
    }

    func track(_ pid: pid_t) {
        let child = Child(pid: pid, fd: openPIDFD?(pid, 0) ?? -1)
        lock.lock()
        pending.append(child)
        lock.unlock()
        // A full pipe already guarantees a wake. Retry only interruption;
        // the nonblocking writer must never hold up the UI.
        var byte: UInt8 = 1
        while write(wakeWriter, &byte, 1) == -1 && errno == EINTR {}
    }

    private func run() {
        var children: [Child] = []
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            lock.lock()
            children.append(contentsOf: pending)
            pending.removeAll(keepingCapacity: true)
            lock.unlock()

            var fds = [pollfd(fd: wakeReader, events: Int16(POLLIN), revents: 0)]
            fds += children.filter { $0.fd >= 0 }.map {
                pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0)
            }
            // Usually sleep until a launch or exit. If pidfds or the wake
            // pipe are unavailable, the same thread checks owned PIDs.
            let timeout: Int32 = wakeReader < 0 || children.contains { $0.fd < 0 }
                ? 100 : -1
            let ready = poll(&fds, nfds_t(fds.count), timeout)
            if ready < 0 {
                if errno == EINTR { continue }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if fds[0].revents & Int16(POLLIN) != 0 {
                while true {
                    let count = read(wakeReader, &buffer, buffer.count)
                    if count > 0 { continue }
                    if count < 0 && errno == EINTR { continue }
                    break
                }
            }
            children.removeAll { child in
                var result: pid_t
                repeat {
                    result = waitpid(child.pid, nil, WNOHANG)
                } while result == -1 && errno == EINTR
                // ECHILD also handles a host explicitly enabling auto-reap.
                guard result == child.pid || (result == -1 && errno == ECHILD) else {
                    return false
                }
                if child.fd >= 0 { close(child.fd) }
                return true
            }
        }
    }
}
