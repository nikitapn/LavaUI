import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// Says which of a set of folders changed on disk, through inotify.
///
/// What the explorer shows is whatever the disk says, without anyone pressing
/// Ctrl+R: a download finishing in the folder on screen, a file another
/// program saved, a terminal's `rm`. One inotify instance watches every
/// folder any tab is on, a thread of its own reads it, and `onChange` hears
/// the set of folders that changed — never per event.
///
/// **Bursts are one report.** A copy of a thousand files is a thousand
/// events, and a reload per event would be a thousand directory listings. So
/// a report waits for `quiet` without a new event, and never longer than
/// `patience` from the first one: a folder that changes continuously — a
/// build writing into it — still refreshes, about once a second.
///
/// **What is watched is names, not sizes.** Creation, deletion, renames in
/// and out, attributes, and a file closed after writing: everything that
/// changes a row. Not `IN_MODIFY`, which fires per `write(2)` and would turn a
/// download into a reload per buffer. A file being written shows its final
/// size when it is closed.
///
/// Watching a folder costs one inotify watch, against a per-user limit
/// (`fs.inotify.max_user_watches`, 8192 by default and far more on most
/// distributions). A watch that cannot be added is skipped silently: the
/// folder simply does not refresh by itself, and Ctrl+R still works.
public final class FolderWatcher: @unchecked Sendable {
    /// Folders that changed. Called on the watcher's own thread.
    public typealias Handler = @Sendable (Set<String>) -> Void

    private let fd: Int32
    /// A pipe whose write end wakes the reading thread out of `poll` to stop
    /// it. A pipe rather than an eventfd, which Glibc does not export.
    private let wake: Int32
    private let wakeWriter: Int32
    private let lock = NSLock()
    private var byPath: [String: Int32] = [:]
    /// One inode watched under two names — a folder and a symlink to it —
    /// is one watch descriptor, so a descriptor maps to every name it was
    /// added under.
    private var byWatch: [Int32: Set<String>] = [:]
    private let onChange: Handler
    private let quiet: TimeInterval
    private let patience: TimeInterval
    private var stopped = false

    private static let mask: UInt32 = UInt32(IN_CREATE) | UInt32(IN_DELETE)
        | UInt32(IN_MOVED_FROM) | UInt32(IN_MOVED_TO) | UInt32(IN_ATTRIB)
        | UInt32(IN_CLOSE_WRITE) | UInt32(IN_DELETE_SELF) | UInt32(IN_MOVE_SELF)
        | UInt32(IN_ONLYDIR)

    /// Nil when inotify is not available — a kernel without it, or the
    /// per-user instance limit reached.
    public init?(
        quiet: TimeInterval = 0.15, patience: TimeInterval = 1.0,
        onChange: @escaping Handler
    ) {
        let fd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard fd >= 0 else { return nil }
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else {
            close(fd)
            return nil
        }
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        self.fd = fd
        self.wake = ends[0]
        self.wakeWriter = ends[1]
        self.quiet = quiet
        self.patience = patience
        self.onChange = onChange
        let thread = Thread { [self] in run() }
        thread.name = "FolderWatcher"
        thread.start()
    }

    deinit { stop() }

    /// Watches exactly `paths` from now on: new ones are added, ones no
    /// longer wanted are dropped. Cheap when nothing changed, which is most
    /// calls — a set comparison.
    public func watch(_ paths: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        for gone in Set(byPath.keys).subtracting(paths) {
            guard let wd = byPath.removeValue(forKey: gone) else { continue }
            byWatch[wd]?.remove(gone)
            if byWatch[wd]?.isEmpty ?? true {
                byWatch[wd] = nil
                inotify_rm_watch(fd, wd)
            }
        }
        for path in paths where byPath[path] == nil {
            let wd = inotify_add_watch(fd, path, Self.mask)
            guard wd >= 0 else { continue }
            byPath[path] = wd
            byWatch[wd, default: []].insert(path)
        }
    }

    /// What is being watched now. For tests.
    public var watched: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(byPath.keys)
    }

    /// Stops the thread and closes the descriptors. Also what `deinit` does;
    /// explicit because the thread holds the watcher until it ends.
    public func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        lock.unlock()
        guard !already else { return }
        var one: UInt8 = 1
        _ = write(wakeWriter, &one, 1)
    }

    // MARK: The reading thread

    private func run() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pending = Set<String>()
        var firstAt: Date?
        var lastAt = Date()
        defer {
            close(fd)
            close(wake)
            close(wakeWriter)
        }
        while true {
            // Forever while idle; while a report is pending, until whichever
            // of the two deadlines comes first.
            var timeout: Int32 = -1
            if let first = firstAt {
                let due = min(lastAt.addingTimeInterval(quiet), first.addingTimeInterval(patience))
                timeout = Int32(max(0, due.timeIntervalSinceNow * 1000).rounded(.up))
            }
            var fds = [
                pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wake, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&fds, 2, timeout)
            if ready < 0, errno == EINTR { continue }
            if fds[1].revents != 0 { return }
            if ready > 0, fds[0].revents & Int16(POLLIN) != 0 {
                let changed = drain(&buffer)
                if !changed.isEmpty {
                    pending.formUnion(changed)
                    lastAt = Date()
                    if firstAt == nil { firstAt = lastAt }
                }
                continue
            }
            // Timed out: the burst is over, or has gone on long enough.
            if !pending.isEmpty {
                let report = pending
                pending = []
                firstAt = nil
                onChange(report)
            }
        }
    }

    /// Reads every event waiting and returns the folders they were in.
    private func drain(_ buffer: inout [UInt8]) -> Set<String> {
        var changed = Set<String>()
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            lock.lock()
            buffer.withUnsafeBytes { raw in
                var offset = 0
                let header = MemoryLayout<inotify_event>.size
                while offset + header <= count {
                    let wd = raw.loadUnaligned(fromByteOffset: offset, as: Int32.self)
                    let mask = raw.loadUnaligned(
                        fromByteOffset: offset + MemoryLayout<Int32>.size, as: UInt32.self
                    )
                    let length = Int(raw.loadUnaligned(
                        fromByteOffset: offset + header - MemoryLayout<UInt32>.size,
                        as: UInt32.self
                    ))
                    offset += header + length
                    if mask & UInt32(IN_Q_OVERFLOW) != 0 {
                        // Events were lost; which folders they were in is
                        // unknown, so every folder is.
                        changed.formUnion(byPath.keys)
                        continue
                    }
                    if let paths = byWatch[wd] { changed.formUnion(paths) }
                    if mask & UInt32(IN_IGNORED) != 0, let paths = byWatch.removeValue(forKey: wd) {
                        // The folder went away and took its watch with it. A
                        // folder made again under that name is a new inode,
                        // so it is forgotten here and re-added by the next
                        // `watch` that still wants it.
                        for path in paths { byPath[path] = nil }
                    }
                }
            }
            lock.unlock()
        }
        return changed
    }
}
