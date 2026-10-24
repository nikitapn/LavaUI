import Foundation
import Testing

@testable import LavaExplorerCore

@Suite struct RemoteURLTests {
    @Test func anAddressKeepsEverythingButThePassword() throws {
        let (url, password) = try #require(RemoteURL.parse("sftp://alice:s3cret@Example.com:2222/srv/My%20Docs/"))
        #expect(password == "s3cret")
        #expect(url.server == RemoteServer(scheme: .sftp, user: "alice", host: "example.com", port: 2222))
        #expect(url.path == "/srv/My Docs")
        #expect(url.string == "sftp://alice@example.com:2222/srv/My Docs")
        #expect(!url.string.contains("s3cret"))
    }

    @Test func theDefaultPortIsLeftOut() throws {
        let url = try #require(RemoteURL("ftp://host:21/pub"))
        #expect(url.server.port == nil)
        #expect(url.string == "ftp://host/pub")
    }

    @Test func noPathIsTheLoginFolder() throws {
        #expect(try #require(RemoteURL("sftp://host")).path == "/~")
        #expect(try #require(RemoteURL("ftp://host")).path == "/")
        #expect(try #require(RemoteURL("sftp://host/")).path == "/")
    }

    @Test func aUserNameMayBeAnEmailAddress() throws {
        let (url, password) = try #require(RemoteURL.parse("ftp://me%40mail.com:pw@ftp.example.com/"))
        #expect(url.server.user == "me@mail.com")
        #expect(password == "pw")
        #expect(url.string == "ftp://me%40mail.com@ftp.example.com/")
        // And back, through the explorer's own string.
        #expect(RemoteURL(url.string) == url)
    }

    @Test func ipv6HostsKeepTheirBrackets() throws {
        let url = try #require(RemoteURL("sftp://[::1]:2200/tmp"))
        #expect(url.server.host == "::1")
        #expect(url.string == "sftp://[::1]:2200/tmp")
        #expect(url.curlURL(directory: true) == "sftp://[::1]:2200/tmp/")
    }

    @Test func parentAndChildWalkThePath() throws {
        let url = try #require(RemoteURL("sftp://h/a/b"))
        #expect(url.name == "b")
        #expect(url.parent?.string == "sftp://h/a")
        #expect(url.parent?.parent?.string == "sftp://h/")
        #expect(url.parent?.parent?.parent == nil)
        #expect(url.parent?.parent?.name == "h")
        #expect(url.appending("c d").string == "sftp://h/a/b/c d")
        #expect(try #require(RemoteURL("sftp://h/")).appending("x").string == "sftp://h/x")
    }

    @Test func dotsAndDoubleSlashesAreResolved() throws {
        #expect(try #require(RemoteURL("ftp://h//a/./b/../c/")).path == "/a/c")
    }

    @Test func curlGetsAnEncodedPathAndNoUser() throws {
        let url = try #require(RemoteURL("sftp://alice@h/My Docs/100%.txt"))
        #expect(url.curlURL(directory: false) == "sftp://h/My%20Docs/100%25.txt")
        #expect(url.parent!.curlURL(directory: true) == "sftp://h/My%20Docs/")
    }

    @Test func explicitFtpsIsSpokenAsFtp() throws {
        #expect(try #require(RemoteURL("ftps://h/x")).curlURL(directory: false) == "ftp://h/x")
        #expect(try #require(RemoteURL("ftps://h:990/x")).curlURL(directory: false) == "ftps://h:990/x")
    }

    @Test func onlyTheThreeSchemesAreRemote() {
        #expect(RemoteURL.isRemote("sftp://h/"))
        #expect(RemoteURL.isRemote("ftps://h/"))
        #expect(!RemoteURL.isRemote("/home/u"))
        #expect(!RemoteURL.isRemote("trash:///"))
        #expect(RemoteURL("http://h/") == nil)
        #expect(RemoteURL("sftp://") == nil)
    }

    @Test func historyGoesUpToTheServerAndStops() {
        var history = FolderHistory(path: "sftp://h/a/b")
        #expect(history.path == "sftp://h/a/b")
        history.goUp()
        #expect(history.path == "sftp://h/a")
        history.goUp()
        #expect(history.path == "sftp://h/")
        #expect(!history.canGoUp)
    }

    @Test func aTypedPasswordNeverReachesTheHistory() {
        let history = FolderHistory(path: "ftp://bob:pw@h/x")
        #expect(history.path == "ftp://bob@h/x")
    }
}

@Suite struct RemoteListingTests {
    let folder = RemoteURL("sftp://h/srv")!
    let utc = TimeZone(identifier: "UTC")!
    // 2026-10-24, so "Oct 24 12:00" is this year and "Dec 31 12:00" last year.
    let now = Date(timeIntervalSince1970: 1_792_843_200)

    @Test func mlsdGivesExactSizesAndUtcTimes() {
        let text = """
            type=cdir;modify=20240101000000; .
            type=pdir;modify=20240101000000; ..
            type=dir;modify=20240102030405; photos
            type=file;size=1234;modify=20240102030405.123;UNIX.mode=0644; read me; now.txt\r
            """
        let rows = RemoteListing.parse(text, in: folder)
        #expect(rows.map(\.name) == ["photos", "read me; now.txt"])
        #expect(rows[0].isDirectory && rows[0].size == nil)
        #expect(rows[1].size == 1234)
        #expect(rows[1].path == "sftp://h/srv/read me; now.txt")
        #expect(rows[1].modified == Date(timeIntervalSince1970: 1_704_164_645))
    }

    @Test func lsLongFormatKeepsSpacesInNames() {
        let text = """
            total 12
            drwxr-xr-x    2 alice    staff        4096 Oct 24 12:00 My Folder
            -rw-r--r--    1 alice    staff       52914 Mar  3  2023 old report.pdf
            lrwxrwxrwx    1 alice    staff          11 Oct 24 09:30 latest -> v2/build
            -rw-r--r--    1 alice    staff          10 Dec 31 12:00 .hidden
            """
        let rows = RemoteListing.parse(text, in: folder, now: now, timeZone: utc)
        #expect(rows.map(\.name) == ["My Folder", "old report.pdf", "latest", ".hidden"])
        #expect(rows[0].isDirectory)
        #expect(rows[1].size == 52914)
        #expect(rows[2].isSymlink)
        #expect(rows[3].isHidden)
        let year = { (d: Date?) in RemoteListing.utc.component(.year, from: d!) }
        #expect(year(rows[0].modified) == 2026)
        #expect(year(rows[1].modified) == 2023)
        // A date that would be in the future is last year's.
        #expect(year(rows[3].modified) == 2025)
    }

    @Test func lsWithoutAGroupColumnStillParses() {
        let rows = RemoteListing.parse("-rw-r--r-- 1 ftp 1024 Jan 5 10:00 a.bin", in: folder, now: now, timeZone: utc)
        #expect(rows.first?.name == "a.bin")
        #expect(rows.first?.size == 1024)
    }

    @Test func dosListingsFromIIS() {
        let text = """
            10-24-23  09:15PM       <DIR>          Shared Files
            01-02-24  12:05AM                 2048 notes.txt
            """
        let rows = RemoteListing.parse(text, in: folder, timeZone: utc)
        #expect(rows.map(\.name) == ["Shared Files", "notes.txt"])
        #expect(rows[0].isDirectory)
        #expect(rows[1].size == 2048)
        let parts = RemoteListing.utc.dateComponents([.year, .hour], from: rows[1].modified!)
        #expect(parts.year == 2024 && parts.hour == 0)
    }

    /// An `ls -l` time is the server's wall clock; read in the zone given,
    /// it is that wall clock there. MLSD's is UTC whatever the zone.
    @Test func wallClockTimesFollowTheZoneAndMlsdDoesNot() {
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let ls = RemoteListing.parse("-rw-r--r-- 1 a b 1 Mar 3 2023 x", in: folder, timeZone: berlin)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        #expect(calendar.component(.hour, from: ls[0].modified!) == 0)
        let mlsd = RemoteListing.parse("type=file;modify=20230303000000; x", in: folder, timeZone: berlin)
        #expect(mlsd[0].modified == Date(timeIntervalSince1970: 1_677_801_600))
    }

    @Test func crlfLineEndingsSplit() {
        let text = "type=dir; a\r\ntype=file;size=1; b\r\ntype=file;size=2; c\r\n"
        #expect(RemoteListing.parse(text, in: folder).map(\.name) == ["a", "b", "c"])
    }

    @Test func linesThatAreNoneOfThemAreSkipped() {
        #expect(RemoteListing.parse("total 0\n\nsomething odd\n", in: folder).isEmpty)
    }
}

@Suite struct RemoteListingSourceTests {
    final class Server: @unchecked Sendable {
        var pending: [(RemoteURL, @Sendable (Result<[FileEntry], RemoteError>) -> Void)] = []
        var changed: [String] = []
    }

    func make(_ server: Server, clock: @escaping @Sendable () -> Date = { Date() }) -> RemoteListingSource {
        let source = RemoteListingSource(base: LocalFileSource(), staleAfter: 10, clock: clock) { url, done in
            server.pending.append((url, done))
        }
        source.onChange = { server.changed.append($0) }
        return source
    }

    @Test func theFirstLookSaysConnectingAndFetches() throws {
        let server = Server()
        let source = make(server)
        let path = "sftp://h/a"
        #expect(throws: FileAccessError.self) { try source.entries(in: path) }
        #expect(server.pending.count == 1)
        // Asking again while it is under way does not start a second fetch.
        _ = try? source.entries(in: path)
        #expect(server.pending.count == 1)
        let row = FileEntry(path: path + "/x", isDirectory: false)
        server.pending[0].1(.success([row]))
        #expect(server.changed == [path])
        #expect(try source.entries(in: path) == [row])
    }

    @Test func aFailureIsTheFoldersErrorUntilInvalidated() {
        let server = Server()
        let source = make(server)
        let path = "ftp://h/"
        _ = try? source.entries(in: path)
        server.pending[0].1(.failure(RemoteError(.login, "530")))
        #expect(source.failure(path)?.kind == .login)
        #expect(throws: FileAccessError.self) { try source.entries(in: path) }
        #expect(server.pending.count == 1)
        source.invalidate(server: RemoteURL(path)!.server)
        _ = try? source.entries(in: path)
        #expect(server.pending.count == 2)
    }

    @Test func aStaleListingIsShownWhileItIsFetchedAgain() throws {
        let server = Server()
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }
        let clock = Clock()
        let source = make(server, clock: { clock.now })
        let path = "sftp://h/a"
        _ = try? source.entries(in: path)
        server.pending[0].1(.success([]))
        clock.now = clock.now.addingTimeInterval(60)
        #expect(try source.entries(in: path) == [])
        #expect(server.pending.count == 2)
    }

    @Test func localPathsGoToTheDisk() throws {
        let server = Server()
        let source = make(server)
        _ = try source.entries(in: NSTemporaryDirectory())
        #expect(server.pending.isEmpty)
        #expect(try source.entry(at: "sftp://h/a/b").isDirectory)
    }
}

@Suite struct SSHConfigTests {
    let home = "/home/u"
    let text = """
        # top
        Host mac
          HostName 192.168.100.24
          User nikita.pennie
          IdentityFile ~/.ssh/id_ed25519_mac
          IdentitiesOnly yes

        Host nikitapn.com
          IdentityFile ~/.ssh/ovhsrv

        Host *.zodiac.tv !gitlab.zodiac.tv
          User=nikita.pennie
          Port 2222

        Host *
          User fallback
          IdentityFile ~/.ssh/everywhere
        """

    @Test func aHostTakesItsBlockAndTheCatchAll() {
        let c = SSHConfig.resolve(host: "nikitapn.com", in: text, home: home)
        #expect(c.identityFiles == ["/home/u/.ssh/ovhsrv", "/home/u/.ssh/everywhere"])
        #expect(c.user == "fallback")
        #expect(c.hostName == nil)
    }

    @Test func theFirstValueWins() {
        let c = SSHConfig.resolve(host: "mac", in: text, home: home)
        #expect(c.hostName == "192.168.100.24")
        #expect(c.user == "nikita.pennie")
        #expect(c.identitiesOnly)
    }

    @Test func patternsAndNegation() {
        #expect(SSHConfig.resolve(host: "gerrit.zodiac.tv", in: text, home: home).port == 2222)
        #expect(SSHConfig.resolve(host: "gitlab.zodiac.tv", in: text, home: home).port == nil)
        #expect(SSHConfig.resolve(host: "MAC", in: text, home: home).hostName == "192.168.100.24")
    }

    @Test func includeAndMatchBlocks() {
        let main = """
            Include extra.conf
            Match exec "true"
              User nope
            Host box
              Port 22
            """
        let c = SSHConfig.resolve(host: "box", in: main, home: home) { path in
            path == "/home/u/.ssh/extra.conf" ? "Host box\n  User fromInclude\n" : nil
        }
        #expect(c.user == "fromInclude")
        #expect(c.port == 22)
    }

    @Test func defaultKeysAreOpenSSHsInItsOrder() {
        let keys = SSHConfig.defaultIdentities(home: home) { $0.hasSuffix("id_ed25519") || $0.hasSuffix("id_rsa") }
        #expect(keys == ["/home/u/.ssh/id_rsa", "/home/u/.ssh/id_ed25519"])
    }
}
