import Foundation
import LavaTermCore

#if os(Linux)
import Glibc
#endif

/// Pseudo-terminal session: fork a shell, pump output, accept keystrokes.
///
/// Reader thread posts bytes to the main thread via a callback; the UI owns
/// the `TerminalScreen` and applies them under MainQueue.
public final class PtySession: @unchecked Sendable {
    public private(set) var masterFd: Int32 = -1
    public private(set) var childPid: pid_t = -1
    public private(set) var isRunning = false

    private var readerThread: Thread?
    private let onData: @Sendable (Data) -> Void
    private let onExit: @Sendable (Int32) -> Void
    private let lock = NSLock()

    public init(
        onData: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void = { _ in }
    ) {
        self.onData = onData
        self.onExit = onExit
    }

    deinit {
        stop()
    }

    /// Start `$SHELL` (or `/bin/bash`) in a new session attached to a PTY.
    @discardableResult
    public func start(cols: Int = 80, rows: Int = 24) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return true }

        #if os(Linux)
        var master: Int32 = -1
        var slave: Int32 = -1
        var win = winsize(
            ws_row: UInt16(clamping: rows),
            ws_col: UInt16(clamping: cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        // openpty(3) from libutil — linked via Package.swift linkerSettings
        // when available; fall back to posix_openpt.
        if openpty(&master, &slave, nil, nil, &win) != 0 {
            master = posix_openpt(O_RDWR | O_NOCTTY)
            guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0 else {
                if master >= 0 { close(master) }
                return false
            }
            guard let name = ptsname(master) else {
                close(master)
                return false
            }
            slave = open(name, O_RDWR | O_NOCTTY)
            guard slave >= 0 else {
                close(master)
                return false
            }
            _ = ioctl(master, UInt(TIOCSWINSZ), &win)
        }

        let pid = fork()
        if pid < 0 {
            close(master)
            close(slave)
            return false
        }

        if pid == 0 {
            // Child
            close(master)
            _ = setsid()
            _ = ioctl(slave, UInt(TIOCSCTTY), 0 as Int32)
            _ = dup2(slave, STDIN_FILENO)
            _ = dup2(slave, STDOUT_FILENO)
            _ = dup2(slave, STDERR_FILENO)
            if slave > STDERR_FILENO { close(slave) }

            setenv("TERM", "xterm-256color", 1)
            setenv("COLORTERM", "truecolor", 1)

            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/bash"
            let name = (shell as NSString).lastPathComponent
            // Login shell (-bash) so profiles load
            let argv0 = "-\(name)"
            shell.withCString { sh in
                argv0.withCString { a0 in
                    var args: [UnsafeMutablePointer<CChar>?] = [
                        UnsafeMutablePointer(mutating: a0),
                        nil,
                    ]
                    execvp(sh, &args)
                }
            }
            _exit(127)
        }

        // Parent
        close(slave)
        // Non-blocking master for clean shutdown
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        masterFd = master
        childPid = pid
        isRunning = true

        let thread = Thread { [weak self] in
            self?.readerLoop()
        }
        thread.name = "LavaTerm.pty"
        thread.start()
        readerThread = thread
        return true
        #else
        return false
        #endif
    }

    public func write(_ data: Data) {
        #if os(Linux)
        guard isRunning, masterFd >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var written = 0
            let total = data.count
            while written < total {
                let n = Glibc.write(masterFd, base.advanced(by: written), total - written)
                if n < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    break
                }
                written += Int(n)
            }
        }
        #endif
    }

    public func write(_ string: String) {
        write(Data(string.utf8))
    }

    public func resize(cols: Int, rows: Int) {
        #if os(Linux)
        guard masterFd >= 0 else { return }
        var win = winsize(
            ws_row: UInt16(clamping: rows),
            ws_col: UInt16(clamping: cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterFd, UInt(TIOCSWINSZ), &win)
        #endif
    }

    public func stop() {
        #if os(Linux)
        lock.lock()
        let fd = masterFd
        let pid = childPid
        masterFd = -1
        childPid = -1
        isRunning = false
        lock.unlock()

        if fd >= 0 {
            close(fd)
        }
        if pid > 0 {
            kill(pid, SIGTERM)
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
        }
        #else
        isRunning = false
        #endif
    }

    #if os(Linux)
    private func readerLoop() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            lock.lock()
            let fd = masterFd
            let running = isRunning
            lock.unlock()
            guard running, fd >= 0 else { break }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 200)
            if pr < 0 {
                if errno == EINTR { continue }
                break
            }
            if pr == 0 { continue }

            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                onData(Data(buffer[0..<n]))
            } else if n == 0 {
                break
            } else {
                if errno == EAGAIN || errno == EINTR { continue }
                break
            }
        }

        var status: Int32 = 0
        lock.lock()
        let pid = childPid
        isRunning = false
        lock.unlock()
        if pid > 0 {
            _ = waitpid(pid, &status, WNOHANG)
        }
        let code = (status & 0xff00) >> 8
        onExit(Int32(code))
    }
    #endif
}

// openpty lives in libutil; declare it so we can try it.
#if os(Linux)
@_silgen_name("openpty")
func openpty(
    _ amaster: UnsafeMutablePointer<Int32>,
    _ aslave: UnsafeMutablePointer<Int32>,
    _ name: UnsafeMutablePointer<CChar>?,
    _ termp: UnsafeMutableRawPointer?,
    _ winp: UnsafeMutablePointer<winsize>?
) -> Int32
#endif
