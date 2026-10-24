import Foundation
import LavaExplorerCore

/// Who each server is logged into as, for this run, with the keyring behind.
///
/// Read from workers (every fetch asks), written from the frame loop (the
/// login bar), so locked. The keyring is asked once per server and the answer
/// kept: it is a D-Bus round trip, and a folder of folders asks per folder.
public final class RemoteLogins: @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [RemoteServer: String] = [:]
    private var lookedUp = Set<RemoteServer>()
    /// Typed into the login bar and not yet known to work. Saved to the
    /// keyring on the first success, never before: a mistyped password is
    /// not something to keep.
    private var unsaved = Set<RemoteServer>()
    /// Refused with a password, as opposed to refused for having none.
    private var refusedWithPassword = Set<RemoteServer>()
    let keyring: Bool

    /// `keyring: false` keeps everything in memory — a test, or a session
    /// with no Secret Service.
    public init(keyring: Bool = true) {
        self.keyring = keyring
    }

    /// What to log into `server` with. Blocks on the keyring the first time.
    public func credentials(for server: RemoteServer) -> RemoteCredentials {
        lock.lock()
        let known = passwords[server]
        let ask = known == nil && keyring && !lookedUp.contains(server)
        if ask { lookedUp.insert(server) }
        lock.unlock()
        var password = known
        if ask, let found = RemoteKeyring.password(for: server) {
            password = found
            lock.lock()
            if passwords[server] == nil { passwords[server] = found }
            lock.unlock()
        }
        return RemoteCredentials(user: Self.user(for: server), password: password)
    }

    /// Whether the last refusal was of a password, rather than of none — the
    /// login bar says "wrong" then, instead of just asking.
    public func refusedAPassword(_ server: RemoteServer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return refusedWithPassword.contains(server)
    }

    /// Typed into the login bar: used from now on, saved once it works.
    public func remember(_ password: String, for server: RemoteServer) {
        lock.lock()
        passwords[server] = password
        unsaved.insert(server)
        lock.unlock()
    }

    /// The server took it. A password from the login bar goes into the
    /// keyring now, on the worker that heard the answer.
    public func succeeded(_ server: RemoteServer) {
        lock.lock()
        let save = unsaved.remove(server) != nil ? passwords[server] : nil
        lock.unlock()
        if let save, keyring { RemoteKeyring.store(save, for: server) }
    }

    /// The server refused it: forgotten, so the next attempt asks.
    public func refused(_ server: RemoteServer) {
        lock.lock()
        if passwords[server] != nil {
            refusedWithPassword.insert(server)
        } else {
            refusedWithPassword.remove(server)
        }
        passwords[server] = nil
        unsaved.remove(server)
        lock.unlock()
    }

    /// The address's user. With none, `RemoteConnections` decides: SFTP as
    /// `~/.ssh/config` or `ssh` would, FTP anonymously.
    static func user(for server: RemoteServer) -> String? {
        server.user
    }
}
