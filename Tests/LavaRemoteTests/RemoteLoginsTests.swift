import Foundation
import LavaExplorerCore
import Testing

@testable import LavaRemote

/// Who to log in as, without a keyring: what the login bar's answers do.
@Suite struct RemoteLoginsTests {
    let server = RemoteServer(scheme: .sftp, user: "alice", host: "h")

    @Test func noUserInTheAddressIsLeftToTheConnection() {
        let logins = RemoteLogins(keyring: false)
        #expect(logins.credentials(for: RemoteServer(scheme: .sftp, host: "h")).user == nil)
        #expect(logins.credentials(for: RemoteServer(scheme: .ftp, host: "h")).user == nil)
    }

    @Test func sshConfigSaysWhereAndWithWhichKey() throws {
        let home = NSTemporaryDirectory() + "lava-ssh-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        try "Host vps\n  HostName 203.0.113.9\n  User debian\n  Port 2200\n  IdentityFile ~/.ssh/vps_key\n  IdentitiesOnly yes\n"
            .write(toFile: home + "/.ssh/config", atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: home + "/.ssh/vps_key", contents: Data())
        FileManager.default.createFile(atPath: home + "/.ssh/id_ed25519", contents: Data())

        let vps = RemoteEndpoint.sshConfig(RemoteServer(scheme: .sftp, host: "vps"), home: home)
        #expect(vps == RemoteEndpoint(
            host: "203.0.113.9", port: 2200, user: "debian",
            identities: [home + "/.ssh/vps_key"], useAgent: false
        ))
        // The address's own port wins; a host the file does not name gets
        // the default keys and the agent.
        let other = RemoteEndpoint.sshConfig(RemoteServer(scheme: .sftp, host: "else", port: 2222), home: home)
        #expect(other == RemoteEndpoint(host: "else", port: 2222, identities: [home + "/.ssh/id_ed25519"]))
        // Not SFTP: as typed.
        #expect(RemoteEndpoint.sshConfig(RemoteServer(scheme: .ftp, host: "vps"), home: home).host == "vps")
    }

    @Test func aTypedPasswordIsUsedUntilRefused() {
        let logins = RemoteLogins(keyring: false)
        #expect(logins.credentials(for: server).password == nil)
        logins.remember("pw", for: server)
        #expect(logins.credentials(for: server) == RemoteCredentials(user: "alice", password: "pw"))
        logins.refused(server)
        #expect(logins.credentials(for: server).password == nil)
        // It was a password that was refused: the bar says "try again".
        #expect(logins.refusedAPassword(server))
    }

    @Test func refusedForHavingNoneIsNotAWrongPassword() {
        let logins = RemoteLogins(keyring: false)
        logins.refused(server)
        #expect(!logins.refusedAPassword(server))
    }

    @Test func anotherPortIsAnotherLogin() {
        let logins = RemoteLogins(keyring: false)
        logins.remember("pw", for: server)
        let other = RemoteServer(scheme: .sftp, user: "alice", host: "h", port: 2222)
        #expect(logins.credentials(for: other).password == nil)
    }
}
