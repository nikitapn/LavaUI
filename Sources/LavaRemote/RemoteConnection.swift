import CLavaRemote
import Foundation
import LavaExplorerCore

/// Who to log in as. A nil password lets SFTP try the agent and the user's
/// keys first, and lets FTP log in anonymously when there is no user either.
public struct RemoteCredentials: Equatable, Sendable {
    public var user: String?
    public var password: String?

    public init(user: String? = nil, password: String? = nil) {
        self.user = user
        self.password = password
    }
}

/// Where a server really is, and the keys to log in with.
public struct RemoteEndpoint: Equatable, Sendable {
    public var host: String
    public var port: Int
    /// Who to log in as when the address names nobody.
    public var user: String?
    /// SFTP private keys to try, in order.
    public var identities: [String]
    public var useAgent: Bool

    public init(host: String, port: Int, user: String? = nil, identities: [String] = [], useAgent: Bool = true) {
        self.host = host
        self.port = port
        self.user = user
        self.identities = identities
        self.useAgent = useAgent
    }

    /// The address as it stands.
    public static func direct(_ server: RemoteServer) -> RemoteEndpoint {
        RemoteEndpoint(host: server.host, port: server.port ?? server.scheme.defaultPort)
    }

    /// SFTP as `ssh` would connect: `~/.ssh/config`'s `HostName`, `Port`,
    /// `User` and `IdentityFile` for the host, and OpenSSH's default key
    /// names when it names none. The address wins where it says something
    /// itself — a port, a user. Read per connection, not cached: it is a few
    /// lines, and an edit to it should not need a restart.
    public static func sshConfig(_ server: RemoteServer, home: String) -> RemoteEndpoint {
        guard server.scheme == .sftp else { return direct(server) }
        let text = (try? String(contentsOfFile: home + "/.ssh/config", encoding: .utf8)) ?? ""
        let config = SSHConfig.resolve(host: server.host, in: text, home: home)
        var keys = config.identityFiles.filter { FileManager.default.fileExists(atPath: $0) }
        if config.identityFiles.isEmpty { keys = SSHConfig.defaultIdentities(home: home) }
        return RemoteEndpoint(
            host: config.hostName ?? server.host,
            port: server.port ?? config.port ?? 22,
            user: config.user,
            identities: keys,
            useAgent: !config.identitiesOnly
        )
    }
}

/// Connections to servers, each kept open between calls.
///
/// Every call blocks and belongs on a worker thread. Calls to one server are
/// serialized on one of two lanes — browsing and transfers — each its own
/// curl handle and so its own connection: a long download must not hold up
/// opening the next folder on the same server, and two calls on one handle at
/// once is not something curl allows.
public final class RemoteConnections: @unchecked Sendable {
    public enum Lane: Sendable { case browse, transfer }

    private struct Key: Hashable {
        var server: RemoteServer
        var lane: Lane
    }

    private final class Slot {
        let lock = NSLock()
        let handle: OpaquePointer?
        init(handle: OpaquePointer?) { self.handle = handle }
        deinit { lava_remote_close(handle) }
    }

    private let lock = NSLock()
    private var slots: [Key: Slot] = [:]
    let knownHosts: String
    let caFile: String?
    let resolve: @Sendable (RemoteServer) -> RemoteEndpoint

    /// `knownHosts` is OpenSSH's file, `~/.ssh/known_hosts` for a user.
    /// `caFile` replaces the system's TLS roots — for a test server with a
    /// certificate of its own; nil otherwise. `resolve` says where a server
    /// really is and how to log into it; the default takes the address as it
    /// stands, with no keys.
    public init(
        knownHosts: String, caFile: String? = nil,
        resolve: @escaping @Sendable (RemoteServer) -> RemoteEndpoint = RemoteEndpoint.direct
    ) {
        self.knownHosts = knownHosts
        self.caFile = caFile
        self.resolve = resolve
    }

    /// The user's own: `~/.ssh/known_hosts`, the folder made if it is missing
    /// (as `ssh` makes it), and `LAVA_REMOTE_CA_FILE` for the roots. Home is
    /// `$HOME` when it is set, as it is for curl: a session started with a
    /// different home means that one.
    public static func standard() -> RemoteConnections {
        let ssh = RemoteCache.home + "/.ssh"
        if !FileManager.default.fileExists(atPath: ssh) {
            try? FileManager.default.createDirectory(
                atPath: ssh, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let ca = ProcessInfo.processInfo.environment["LAVA_REMOTE_CA_FILE"]
        let home = RemoteCache.home
        return RemoteConnections(knownHosts: ssh + "/known_hosts", caFile: ca) { server in
            RemoteEndpoint.sshConfig(server, home: home)
        }
    }

    // MARK: - Calls

    /// The folder's rows.
    public func list(
        _ folder: RemoteURL, as credentials: RemoteCredentials
    ) throws(RemoteError) -> [FileEntry] {
        let text: String = try run(folder.server, .browse, credentials) { handle, call, result in
            var out: UnsafeMutablePointer<CChar>?
            var length = 0
            let mlsd: Int32 = folder.server.scheme == .sftp ? 0 : 1
            let code = lava_remote_list(
                handle, call.url(folder, true), call.user,
                call.password, mlsd, &out, &length, &result
            )
            defer { lava_remote_free(out) }
            guard code == 0, let out else { return nil }
            return String(decoding: UnsafeRawBufferPointer(start: out, count: length), as: UTF8.self)
        }
        return RemoteListing.parse(text, in: folder)
    }

    /// The file at `remote`, written to `local`. `progress` is told bytes so
    /// far and the total (0 when unknown); false from it cancels.
    public func download(
        _ remote: RemoteURL, to local: String, as credentials: RemoteCredentials,
        progress: @escaping (Int64, Int64) -> Bool = { _, _ in true }
    ) throws(RemoteError) {
        let relay = ProgressRelay(progress)
        let _: Bool = try run(remote.server, .transfer, credentials) { handle, call, result in
            withExtendedLifetime(relay) {
                lava_remote_download(
                    handle, call.url(remote, false), call.user,
                    call.password, local, ProgressRelay.callback,
                    Unmanaged.passUnretained(relay).toOpaque(), &result
                ) == 0 ? true : nil
            }
        }
    }

    /// `local` written to `remote`, making any missing folders on the way.
    public func upload(
        _ local: String, to remote: RemoteURL, as credentials: RemoteCredentials,
        progress: @escaping (Int64, Int64) -> Bool = { _, _ in true }
    ) throws(RemoteError) {
        let relay = ProgressRelay(progress)
        let _: Bool = try run(remote.server, .transfer, credentials) { handle, call, result in
            withExtendedLifetime(relay) {
                lava_remote_upload(
                    handle, call.url(remote, false), call.user,
                    call.password, local, ProgressRelay.callback,
                    Unmanaged.passUnretained(relay).toOpaque(), &result
                ) == 0 ? true : nil
            }
        }
    }

    /// Makes the folder `remote`. Its parent has to exist.
    public func makeFolder(
        _ remote: RemoteURL, as credentials: RemoteCredentials
    ) throws(RemoteError) {
        guard let parent = remote.parent else { return }
        try command(Self.mkdir(remote), in: parent, as: credentials)
    }

    /// Removes the file `remote`. Used to take back a half-written upload.
    public func removeFile(
        _ remote: RemoteURL, as credentials: RemoteCredentials
    ) throws(RemoteError) {
        guard let parent = remote.parent else { return }
        let text = remote.server.scheme == .sftp
            ? "rm \(Self.quoted(remote.path))" : "DELE \(remote.name)"
        try command(text, in: parent, as: credentials)
    }

    /// The command runs in the parent folder, so FTP names the item there —
    /// the rest of the line, spaces and all, with no quoting understood. SFTP
    /// takes whole paths, quoted.
    static func mkdir(_ remote: RemoteURL) -> String {
        remote.server.scheme == .sftp ? "mkdir \(quoted(remote.path))" : "MKD \(remote.name)"
    }

    /// SFTP's `~` is curl's to expand in a URL, not in a command.
    static func quoted(_ path: String) -> String {
        var path = path
        if path == "/~" || path.hasPrefix("/~/") { path.removeFirst(2); path = "~" + path }
        return "\"" + path.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func command(
        _ text: String, in folder: RemoteURL, as credentials: RemoteCredentials
    ) throws(RemoteError) {
        let _: Bool = try run(folder.server, .transfer, credentials) { handle, call, result in
            lava_remote_command(
                handle, call.url(folder, true), call.user,
                call.password, text, &result
            ) == 0 ? true : nil
        }
    }

    // MARK: - Plumbing

    private func slot(_ server: RemoteServer, _ lane: Lane, _ endpoint: RemoteEndpoint) -> Slot {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(server: server, lane: lane)
        if let slot = slots[key] { return slot }
        let slot = Slot(handle: lava_remote_open(
            endpoint.host, Int32(endpoint.port), knownHosts, caFile,
            server.scheme == .ftps ? 1 : 0
        ))
        slots[key] = slot
        return slot
    }

    /// What one call needs besides the handle: who it logs in as, and the
    /// address curl is given — the real host and port, which `~/.ssh/config`
    /// may say differ from the ones in the explorer's address.
    struct Call {
        var user: String?
        var password: String?
        var endpoint: RemoteEndpoint

        func url(_ remote: RemoteURL, _ directory: Bool) -> String {
            remote.curlURL(directory: directory, host: endpoint.host, port: endpoint.port)
        }
    }

    /// The key that last worked for each server, so the next call starts
    /// there rather than walking the list again.
    private var workingKey: [RemoteServer: Int] = [:]

    /// Runs `body` on the server's lane, one at a time. A nil from it is a
    /// failure, described by the result it filled in.
    ///
    /// SFTP is tried with each of the endpoint's keys in turn while the server
    /// refuses the login — `ssh` does the same with its identities — and the
    /// one that works is remembered. A refusal after the last key is the
    /// login error the window asks for a password on.
    private func run<T>(
        _ server: RemoteServer, _ lane: Lane, _ credentials: RemoteCredentials,
        _ body: (OpaquePointer, Call, inout lava_remote_result) -> T?
    ) throws(RemoteError) -> T {
        let endpoint = resolve(server)
        let slot = slot(server, lane, endpoint)
        guard let handle = slot.handle else {
            throw RemoteError(.failed, "Could not start a connection")
        }
        var user = credentials.user ?? endpoint.user
        if user == nil, server.scheme == .sftp { user = NSUserName() }
        let call = Call(user: user, password: credentials.password, endpoint: endpoint)
        let keys: [String?] = server.scheme == .sftp && !endpoint.identities.isEmpty
            ? endpoint.identities : [nil]
        lock.lock()
        let first = min(workingKey[server] ?? 0, keys.count - 1)
        lock.unlock()
        let order = Array(keys.indices[first...]) + Array(keys.indices[..<first])

        slot.lock.lock()
        defer { slot.lock.unlock() }
        var last = lava_remote_result()
        for index in order {
            lava_remote_set_identity(handle, keys[index], endpoint.useAgent ? 1 : 0)
            var result = lava_remote_result()
            if let value = body(handle, call, &result) {
                lock.lock()
                workingKey[server] = index
                lock.unlock()
                return value
            }
            last = result
            guard Self.error(result).kind == .login else { break }
        }
        throw Self.error(last)
    }

    static func error(_ result: lava_remote_result) -> RemoteError {
        let message = withUnsafeBytes(of: result.message) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let kind: RemoteError.Kind
        switch Int(result.code) {
        case 1: kind = .login
        case 2: kind = .notFound
        case 3: kind = .hostKey
        case 4: kind = .tls
        case 5: kind = .connect
        case 6: kind = .cancelled
        default: kind = .failed
        }
        return RemoteError(kind, message)
    }
}

/// Carries a Swift closure through curl's progress callback.
private final class ProgressRelay {
    let body: (Int64, Int64) -> Bool
    init(_ body: @escaping (Int64, Int64) -> Bool) { self.body = body }

    static let callback: lava_remote_progress_fn = { context, done, total in
        guard let context else { return 0 }
        let relay = Unmanaged<ProgressRelay>.fromOpaque(context).takeUnretainedValue()
        return relay.body(done, total) ? 0 : 1
    }
}

/// Passwords, in the desktop's keyring.
///
/// Under the network-password schema GNOME Files and gvfs use, keyed by
/// protocol, host, port and user — so a server whose password was saved
/// there opens here without asking. Every call is a D-Bus round trip, so not
/// on the frame loop.
public enum RemoteKeyring {
    public static func password(for server: RemoteServer) -> String? {
        guard let user = server.user else { return nil }
        guard let found = lava_secret_lookup(
            server.scheme.rawValue, server.host, Int32(server.port ?? 0), user
        ) else { return nil }
        defer { lava_remote_free(found) }
        return String(cString: found)
    }

    @discardableResult
    public static func store(_ password: String, for server: RemoteServer) -> Bool {
        guard let user = server.user else { return false }
        return lava_secret_store(
            server.scheme.rawValue, server.host, Int32(server.port ?? 0), user,
            password, "\(server.scheme.rawValue.uppercased()) password for \(server.title)"
        ) != 0
    }

    @discardableResult
    public static func forget(_ server: RemoteServer) -> Bool {
        guard let user = server.user else { return false }
        return lava_secret_clear(
            server.scheme.rawValue, server.host, Int32(server.port ?? 0), user
        ) != 0
    }
}
