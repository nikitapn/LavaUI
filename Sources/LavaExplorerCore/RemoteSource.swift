import Foundation

/// Why a server said no, in the terms the explorer answers differently.
public struct RemoteError: Error, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Wrong or missing name and password: ask for them.
        case login
        case notFound
        /// An SSH server whose key changed since it was last seen.
        case hostKey
        case tls
        case connect
        case cancelled
        case failed
    }

    public var kind: Kind
    public var message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    /// For the status line, about `server`.
    public func describe(_ server: RemoteServer) -> String {
        switch kind {
        case .login: return "\(server.title) wants a password"
        case .notFound: return "Not found on \(server.host)"
        case .hostKey:
            return "\(server.host)'s key is not the one known_hosts has for it — refusing to connect"
        case .tls: return "Could not connect securely to \(server.host): \(message)"
        case .connect: return "Could not reach \(server.host): \(message)"
        case .cancelled: return "Cancelled"
        case .failed: return message
        }
    }
}

/// Remote folders through the same synchronous seam as the disk.
///
/// `FileSource` answers at once, on the frame loop, and that is right for a
/// disk: a listing is microseconds. A server is a round trip at best and a
/// login at worst, and the window cannot stop for either. So this answers a
/// remote folder from what it last fetched, and when it has nothing it says
/// "Connecting…" as the folder's error — which the list already knows how to
/// show — starts the fetch, and calls `onChange` when the fetch lands. The
/// owner reloads the tabs on that folder then, the way it does when inotify
/// says a local folder changed.
///
/// A listing older than `staleAfter` is still shown, and fetched again behind
/// it: a folder gone back into should open at once, and catch up.
public final class RemoteListingSource: FileSource, @unchecked Sendable {
    /// Lists `folder` and calls back, from any thread, exactly once.
    public typealias Fetch = @Sendable (
        _ folder: RemoteURL, _ done: @escaping @Sendable (Result<[FileEntry], RemoteError>) -> Void
    ) -> Void

    let base: any FileSource
    let fetch: Fetch
    let staleAfter: TimeInterval
    let clock: @Sendable () -> Date
    /// Called with the folder's path when a fetch for it finished, from the
    /// fetch's thread.
    public var onChange: @Sendable (String) -> Void = { _ in }

    private enum State {
        case loading(previous: [FileEntry]?)
        case loaded([FileEntry], at: Date)
        case failed(RemoteError)
    }

    private let lock = NSLock()
    private var states: [String: State] = [:]

    public init(
        base: any FileSource,
        staleAfter: TimeInterval = 10,
        clock: @escaping @Sendable () -> Date = { Date() },
        fetch: @escaping Fetch
    ) {
        self.base = base
        self.fetch = fetch
        self.staleAfter = staleAfter
        self.clock = clock
    }

    public func entries(in directory: String) throws -> [FileEntry] {
        guard let url = RemoteURL(directory) else { return try base.entries(in: directory) }
        let key = url.string
        lock.lock()
        let state = states[key]
        var start = false
        var answer: Result<[FileEntry], FileAccessError>
        switch state {
        case .loaded(let entries, let at)?:
            if clock().timeIntervalSince(at) > staleAfter {
                states[key] = .loading(previous: entries)
                start = true
            }
            answer = .success(entries)
        case .loading(let previous)?:
            answer = previous.map { .success($0) } ?? .failure(connecting(url))
        case .failed(let error)?:
            answer = .failure(FileAccessError(path: key, message: error.describe(url.server)))
        case nil:
            states[key] = .loading(previous: nil)
            start = true
            answer = .failure(connecting(url))
        }
        lock.unlock()
        if start { begin(url) }
        return try answer.get()
    }

    /// A remote address is taken to be a folder: whether it is one costs a
    /// round trip, and the listing will say so soon enough if not.
    public func entry(at path: String) throws -> FileEntry {
        guard let url = RemoteURL(path) else { return try base.entry(at: path) }
        return FileEntry(path: url.string, name: url.name, isDirectory: true)
    }

    public func exists(_ path: String) -> Bool {
        RemoteURL.isRemote(path) || base.exists(path)
    }

    /// Forgets `path` (or, with `server`, everything on that server), so the
    /// next look fetches. Ctrl+R; a login; an upload into it.
    public func invalidate(_ path: String) {
        guard let url = RemoteURL(path) else { return }
        lock.lock()
        if case .loaded(let entries, _)? = states[url.string] {
            // Shown while the new listing comes, rather than "Connecting…".
            states[url.string] = .loaded(entries, at: .distantPast)
        } else {
            states[url.string] = nil
        }
        lock.unlock()
    }

    public func invalidate(server: RemoteServer) {
        lock.lock()
        for key in states.keys where RemoteURL(key)?.server == server {
            states[key] = nil
        }
        lock.unlock()
    }

    /// The error the last fetch of `path` ended with, if it failed.
    public func failure(_ path: String) -> RemoteError? {
        lock.lock()
        defer { lock.unlock() }
        if case .failed(let error)? = states[path] { return error }
        return nil
    }

    /// The rows last fetched for `path`, without starting anything. Used to
    /// check a drop's names against what is there.
    public func cached(_ path: String) -> [FileEntry]? {
        lock.lock()
        defer { lock.unlock() }
        switch states[path] {
        case .loaded(let entries, _)?: return entries
        case .loading(let previous)?: return previous
        default: return nil
        }
    }

    private func connecting(_ url: RemoteURL) -> FileAccessError {
        FileAccessError(path: url.string, message: "Connecting to \(url.server.title)…")
    }

    private func begin(_ url: RemoteURL) {
        let key = url.string
        fetch(url) { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            switch result {
            case .success(let entries):
                self.states[key] = .loaded(entries, at: self.clock())
            case .failure(let error):
                self.states[key] = .failed(error)
            }
            self.lock.unlock()
            self.onChange(key)
        }
    }
}
