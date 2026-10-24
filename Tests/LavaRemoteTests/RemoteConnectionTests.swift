import Foundation
import LavaExplorerCore
import Testing

@testable import LavaRemote

/// Against real servers, so only when there are some.
///
/// `LAVA_REMOTE_TEST_ROOT` names a folder served as user `alice`, password
/// `secret`, over FTP on 2121, explicit FTPS on 2122 and SFTP on 2222, all on
/// 127.0.0.1; `LAVA_REMOTE_TEST_CA` is the FTPS server's certificate. Without
/// them every test here is skipped — nothing on a build machine listens on
/// those ports. `tools/remote_test_servers.py` starts pyftpdlib and asyncssh
/// that way.
private enum Servers {
    static let env = ProcessInfo.processInfo.environment
    static let root = env["LAVA_REMOTE_TEST_ROOT"]
    static let ca = env["LAVA_REMOTE_TEST_CA"]
    static var available: Bool { root != nil }

    static let alice = RemoteCredentials(user: "alice", password: "secret")

    static func url(_ scheme: RemoteServer.Scheme, _ path: String) -> RemoteURL {
        let port = [RemoteServer.Scheme.ftp: 2121, .ftps: 2122, .sftp: 2222][scheme]!
        return RemoteURL(server: RemoteServer(scheme: scheme, user: "alice", host: "127.0.0.1", port: port), path: path)
    }

    /// A known_hosts of the test's own, so the user's is never written.
    static func connections() -> (RemoteConnections, String) {
        let hosts = NSTemporaryDirectory() + "lava-known-hosts-\(UUID().uuidString)"
        return (RemoteConnections(knownHosts: hosts, caFile: ca), hosts)
    }

    static func scratch() -> String {
        let dir = NSTemporaryDirectory() + "lava-remote-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}

@Suite(.enabled(if: Servers.available, "no test servers — see LAVA_REMOTE_TEST_ROOT"))
struct RemoteConnectionTests {
    @Test(arguments: [RemoteServer.Scheme.ftp, .ftps, .sftp])
    func listsTheRootInEveryProtocol(_ scheme: RemoteServer.Scheme) throws {
        let (connections, _) = Servers.connections()
        let rows = try connections.list(Servers.url(scheme, "/"), as: Servers.alice)
        let names = Set(rows.map(\.name))
        #expect(names.isSuperset(of: ["docs", "My Folder", "big.bin"]))
        #expect(rows.first { $0.name == "docs" }?.isDirectory == true)
        #expect(rows.first { $0.name == "big.bin" }?.size == 300_000)
    }

    @Test(arguments: [RemoteServer.Scheme.ftp, .ftps, .sftp])
    func downloadsUploadsAndCleansUp(_ scheme: RemoteServer.Scheme) throws {
        let (connections, _) = Servers.connections()
        let local = Servers.scratch()
        defer { try? FileManager.default.removeItem(atPath: local) }

        // Down, with progress that reaches the whole size.
        var last: (Int64, Int64) = (0, 0)
        try connections.download(
            Servers.url(scheme, "/big.bin"), to: local + "/big.bin", as: Servers.alice
        ) { done, total in last = (done, total); return true }
        #expect(try Data(contentsOf: URL(fileURLWithPath: local + "/big.bin")).count == 300_000)
        #expect(last.0 == 300_000)

        // Up, into folders that do not exist yet.
        let tag = "\(scheme.rawValue)-\(UUID().uuidString.prefix(8))"
        try Data("hi \(tag)".utf8).write(to: URL(fileURLWithPath: local + "/up.txt"))
        let target = Servers.url(scheme, "/incoming \(tag)/deep/up.txt")
        try connections.upload(local + "/up.txt", to: target, as: Servers.alice)
        let onDisk = Servers.root! + "/incoming \(tag)/deep/up.txt"
        #expect(try String(contentsOfFile: onDisk, encoding: .utf8) == "hi \(tag)")

        // An empty folder, and taking the file back.
        try connections.makeFolder(Servers.url(scheme, "/incoming \(tag)/empty"), as: Servers.alice)
        #expect(FileManager.default.fileExists(atPath: Servers.root! + "/incoming \(tag)/empty"))
        try connections.removeFile(target, as: Servers.alice)
        #expect(!FileManager.default.fileExists(atPath: onDisk))
        try? FileManager.default.removeItem(atPath: Servers.root! + "/incoming \(tag)")
    }

    /// No password at all: the first key is refused, the second is let in,
    /// and the next call starts with the one that worked.
    @Test func sftpLogsInWithTheKeyThatWorks() throws {
        let certs = (Servers.ca! as NSString).deletingLastPathComponent
        let hosts = NSTemporaryDirectory() + "lava-known-hosts-\(UUID().uuidString)"
        let connections = RemoteConnections(knownHosts: hosts) { server in
            RemoteEndpoint(
                host: server.host, port: server.port ?? 22,
                identities: [certs + "/decoy_key", certs + "/client_key"], useAgent: false
            )
        }
        let alice = RemoteCredentials(user: "alice")
        let rows = try connections.list(Servers.url(.sftp, "/"), as: alice)
        #expect(rows.contains { $0.name == "docs" })
        _ = try connections.list(Servers.url(.sftp, "/docs"), as: alice)
    }

    @Test func sftpWithOnlyRefusedKeysIsALoginError() {
        let certs = (Servers.ca! as NSString).deletingLastPathComponent
        let hosts = NSTemporaryDirectory() + "lava-known-hosts-\(UUID().uuidString)"
        let connections = RemoteConnections(knownHosts: hosts) { server in
            RemoteEndpoint(host: server.host, port: server.port ?? 22,
                           identities: [certs + "/decoy_key"], useAgent: false)
        }
        #expect {
            try connections.list(Servers.url(.sftp, "/"), as: RemoteCredentials(user: "alice"))
        } throws: { ($0 as? RemoteError)?.kind == .login }
    }

    /// Make, rename and delete — a tree with a file and a folder in it — the
    /// way the explorer's New Folder, Rename and Delete do.
    @Test(arguments: [RemoteServer.Scheme.ftp, .ftps, .sftp])
    func makesRenamesAndDeletesATree(_ scheme: RemoteServer.Scheme) throws {
        let (connections, _) = Servers.connections()
        let local = Servers.scratch()
        defer { try? FileManager.default.removeItem(atPath: local) }
        let root = Servers.root!
        let tag = "\(scheme.rawValue)-\(UUID().uuidString.prefix(8))"
        let folder = Servers.url(scheme, "/tree \(tag)")

        try connections.makeFolder(folder, as: Servers.alice)
        try Data("x".utf8).write(to: URL(fileURLWithPath: local + "/f.txt"))
        try connections.upload(local + "/f.txt", to: folder.appending("in it/f.txt"), as: Servers.alice)

        try connections.rename(folder.appending("in it/f.txt"), to: "renamed file.txt", as: Servers.alice)
        #expect(FileManager.default.fileExists(atPath: root + "/tree \(tag)/in it/renamed file.txt"))
        try connections.rename(folder, to: "tree renamed \(tag)", as: Servers.alice)
        #expect(FileManager.default.fileExists(atPath: root + "/tree renamed \(tag)/in it/renamed file.txt"))

        try connections.removeFolder(Servers.url(scheme, "/tree renamed \(tag)"), as: Servers.alice)
        #expect(!FileManager.default.fileExists(atPath: root + "/tree renamed \(tag)"))
    }

    /// The same under the login folder, `/~`, which is where an `sftp://host`
    /// address lands. Commands there once named `~` literally.
    @Test func sftpChangesTheLoginFolder() throws {
        let (connections, _) = Servers.connections()
        let local = Servers.scratch()
        defer { try? FileManager.default.removeItem(atPath: local) }
        let tag = UUID().uuidString.prefix(8)
        let home = Servers.url(.sftp, "/~")
        let folder = home.appending("home tree \(tag)")
        try connections.makeFolder(folder, as: Servers.alice)
        try Data("x".utf8).write(to: URL(fileURLWithPath: local + "/f.txt"))
        try connections.upload(local + "/f.txt", to: folder.appending("f.txt"), as: Servers.alice)
        try connections.rename(folder.appending("f.txt"), to: "g.txt", as: Servers.alice)
        #expect(FileManager.default.fileExists(atPath: Servers.root! + "/home tree \(tag)/g.txt"))
        try connections.removeFile(folder.appending("g.txt"), as: Servers.alice)
        try connections.removeFolder(folder, as: Servers.alice)
        #expect(!FileManager.default.fileExists(atPath: Servers.root! + "/home tree \(tag)"))
    }

    @Test func aRefusedCommandIsNotNotFound() {
        let (connections, _) = Servers.connections()
        // Making a folder that is already there.
        #expect {
            try connections.makeFolder(Servers.url(.ftp, "/docs"), as: Servers.alice)
        } throws: { ($0 as? RemoteError)?.kind == .failed }
    }

    @Test(arguments: [RemoteServer.Scheme.ftp, .sftp])
    func aWrongPasswordIsALoginError(_ scheme: RemoteServer.Scheme) {
        let (connections, _) = Servers.connections()
        #expect {
            try connections.list(Servers.url(scheme, "/"), as: RemoteCredentials(user: "alice", password: "wrong"))
        } throws: { ($0 as? RemoteError)?.kind == .login }
    }

    @Test func aMissingFolderIsNotFound() {
        let (connections, _) = Servers.connections()
        #expect {
            try connections.download(
                Servers.url(.ftp, "/nope.txt"), to: Servers.scratch() + "/x", as: Servers.alice
            )
        } throws: { ($0 as? RemoteError)?.kind == .notFound }
    }

    @Test func cancellingFromProgressStopsTheTransfer() {
        let (connections, _) = Servers.connections()
        #expect {
            try connections.download(
                Servers.url(.sftp, "/big.bin"), to: Servers.scratch() + "/x", as: Servers.alice
            ) { done, _ in done < 1 }
        } throws: { ($0 as? RemoteError)?.kind == .cancelled }
    }

    @Test func ftpsWithoutTrustingTheCertificateIsRefused() {
        let hosts = NSTemporaryDirectory() + "lava-known-hosts-\(UUID().uuidString)"
        let connections = RemoteConnections(knownHosts: hosts, caFile: nil)
        #expect {
            try connections.list(Servers.url(.ftps, "/"), as: Servers.alice)
        } throws: { ($0 as? RemoteError)?.kind == .tls }
    }

    /// The host on port 22, filed with another kind of key, says nothing
    /// about a server on 2222. curl, given the file, looked the host up
    /// without its port and narrowed the key exchange to that kind — so the
    /// SFTP server beside a machine's own sshd could not be reached at all.
    @Test func anEntryForAnotherPortDoesNotGetInTheWay() throws {
        let (connections, hosts) = Servers.connections()
        let port22 = "127.0.0.1 ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=\n"
        try port22.write(toFile: hosts, atomically: true, encoding: .utf8)
        _ = try connections.list(Servers.url(.sftp, "/"), as: Servers.alice)
        let after = try String(contentsOfFile: hosts, encoding: .utf8)
        // Kept as it was, with the new host after it.
        #expect(after.hasPrefix(port22))
        #expect(after.contains("[127.0.0.1]:2222 ssh-ed25519 "))
    }

    /// The first sight of a host is written down; a different key after that
    /// is refused, which is the whole point of writing it down.
    @Test func aChangedHostKeyIsRefused() throws {
        let (connections, hosts) = Servers.connections()
        _ = try connections.list(Servers.url(.sftp, "/"), as: Servers.alice)
        let recorded = try String(contentsOfFile: hosts, encoding: .utf8)
        #expect(recorded.contains("[127.0.0.1]:2222"))

        // The same line with another ed25519 key.
        let parts = recorded.split(separator: " ")
        let forged = "\(parts[0]) ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n"
        try forged.write(toFile: hosts, atomically: true, encoding: .utf8)
        let fresh = RemoteConnections(knownHosts: hosts, caFile: nil)
        #expect {
            try fresh.list(Servers.url(.sftp, "/"), as: Servers.alice)
        } throws: { ($0 as? RemoteError)?.kind == .hostKey }
    }
}

/// Writes to whichever Secret Service the session bus has, so only when the
/// run says that bus is a throwaway one: `dbus-run-session` with a
/// `gnome-keyring-daemon --unlock` of its own. Never the user's keyring.
@Suite(.enabled(
    if: ProcessInfo.processInfo.environment["LAVA_REMOTE_TEST_KEYRING"] == "private",
    "set LAVA_REMOTE_TEST_KEYRING=private inside a dbus-run-session"
))
struct RemoteKeyringTests {
    @Test func storesFindsAndForgets() {
        let server = RemoteServer(scheme: .sftp, user: "alice", host: "keyring.test", port: 2222)
        #expect(RemoteKeyring.password(for: server) == nil)
        #expect(RemoteKeyring.store("pw with spaces", for: server))
        #expect(RemoteKeyring.password(for: server) == "pw with spaces")
        // Another port is another server.
        var other = server
        other.port = 2223
        #expect(RemoteKeyring.password(for: other) == nil)
        #expect(RemoteKeyring.forget(server))
        #expect(RemoteKeyring.password(for: server) == nil)
    }

    @Test func noUserMeansNothingToLookUp() {
        #expect(RemoteKeyring.password(for: RemoteServer(scheme: .ftp, host: "keyring.test")) == nil)
    }
}

/// No server needed: refused before anything is sent.
@Suite struct RemoteNameTests {
    @Test func namesThatWouldBeASecondCommandAreRefused() {
        for name in ["a\r\nDELE b", "a\nb", "a/b", "..", "", "nul\0"] {
            #expect(throws: RemoteError.self) { try RemoteConnections.check(name) }
        }
        #expect(throws: Never.self) { try RemoteConnections.check("ordinary name (2).txt") }
    }

    @Test func renamingToSuchANameSendsNothing() {
        // No server listens here; a check that let the name through would
        // fail with a connection error instead.
        let connections = RemoteConnections(knownHosts: "/dev/null")
        let file = RemoteURL("ftp://127.0.0.1:1/a.txt")!
        #expect {
            try connections.rename(file, to: "b\r\nDELE c", as: RemoteCredentials())
        } throws: { ($0 as? RemoteError)?.message.contains("line break") == true }
    }
}

@Suite struct SFTPPathTests {
    @Test func theLoginFolderGoesAsARelativePath() {
        #expect(RemoteConnections.quoted("/~") == "\".\"")
        #expect(RemoteConnections.quoted("/~/temp/a b.txt") == "\"temp/a b.txt\"")
        #expect(RemoteConnections.quoted("/srv/x") == "\"/srv/x\"")
        #expect(RemoteConnections.quoted("/srv/say \"hi\"") == "\"/srv/say \\\"hi\\\"\"")
    }
}
