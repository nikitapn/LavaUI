import Foundation
import Testing

@testable import LavaShell

@Suite("MIME types")
struct MimeAppsTests {
    @Test("a folder is inode/directory")
    func folder() {
        #expect(MimeApps.type(of: "/home", isDirectory: true) == "inode/directory")
    }

    @Test("known extensions map to shared-mime-info names")
    func extensions() {
        #expect(MimeApps.typeFromExtension("photo.JPG") == "image/jpeg")
        #expect(MimeApps.typeFromExtension("notes.txt") == "text/plain")
        #expect(MimeApps.typeFromExtension("doc.pdf") == "application/pdf")
        #expect(MimeApps.typeFromExtension("Passwords.kdbx") == "application/x-keepass2")
        #expect(MimeApps.typeFromExtension("no-ext") == "application/octet-stream")
        #expect(MimeApps.type(of: "photo.png", isDirectory: false) == "image/png")
    }

    @Test("Default Applications keeps the first desktop file")
    func parseDefaults() {
        let text = """
            [Added Associations]
            image/png=other.desktop;

            [Default Applications]
            image/png=lava-view.desktop;eog.desktop;
            inode/directory=LavaExplorer.desktop;

            [Removed Associations]
            image/png=bad.desktop;
            """
        let defaults = MimeApps.parseDefaults(text)
        #expect(defaults["image/png"] == "lava-view.desktop")
        #expect(defaults["inode/directory"] == "LavaExplorer.desktop")
        #expect(defaults["image/jpeg"] == nil)
    }
}

@Suite("Default application resolution")
struct DefaultApplicationTests {
    private let aliases = ["video/x-matroska": "video/matroska"]

    @Test("Matroska aliases and log extensions select the configured apps, with filenames passed intact")
    func mediaAndLogs() throws {
        let paths = [
            "/mnt/windows/Video/Hydroponic cucumbers [Rp9MSa3Xn20].mkv",
            "/tmp/server events.LOG",
        ]
        let apps = [
            DesktopEntry(id: "mpv", name: "mpv", exec: "mpv %F"),
            DesktopEntry(id: "emacs", name: "Emacs", exec: "emacs %F"),
            DesktopEntry(id: "LavaPlayer", name: "LavaPlayer", exec: "LavaPlayer %F", mimeTypes: ["video/x-matroska"]),
            DesktopEntry(id: "glogg", name: "glogg", exec: "glogg %F", mimeTypes: ["text/x-log"]),
        ]
        let candidates = MimeApps.mergeDefaults([
            "[Default Applications]\nvideo/x-matroska=LavaPlayer.desktop;\ntext/x-log=glogg.desktop;",
            "[Default Applications]\nvideo/matroska=mpv.desktop;\ntext/x-log=emacs.desktop;",
        ], aliases: aliases)
        for (path, id) in zip(paths, ["LavaPlayer", "glogg"]) {
            let mime = MimeApps.type(of: path, isDirectory: false)
            let app = try #require(MimeApps.preferredApplication(for: mime, applications: apps, candidates: candidates))
            #expect(app.id == id)
            #expect(app.command(files: [path]) == [id, path])
        }
        let player = try #require(apps.first { $0.id == "LavaPlayer" })
        #expect(player.handles("video/matroska"))
        #expect(MimeApps.canonicalType("video/x-matroska") == MimeApps.canonicalType("video/matroska"))
        #expect(MimeApps.typeFromExtension("clip.MOV") == "video/quicktime")
        #expect(MimeApps.typeFromExtension("clip.avi") == MimeApps.canonicalType("video/x-msvideo"))
    }

    @Test("Stale defaults are skipped before trying lower-priority defaults")
    func staleDefaults() {
        let candidates = MimeApps.mergeDefaults([
            "[Default Applications]\ntext/x-log=missing.desktop;glogg.desktop;",
            "[Default Applications]\ntext/x-log=emacs.desktop;",
        ], aliases: [:])
        let glogg = DesktopEntry(id: "glogg", name: "glogg", exec: "glogg %F")
        let emacs = DesktopEntry(id: "emacs", name: "Emacs", exec: "emacs %F")
        #expect(MimeApps.preferredApplication(for: "text/x-log", applications: [emacs, glogg], candidates: candidates)?.id == "glogg")
        #expect(MimeApps.preferredApplication(for: "text/x-log", applications: [emacs], candidates: candidates)?.id == "emacs")
        #expect(MimeApps.preferredApplication(for: "text/x-log", applications: [], candidates: candidates) == nil)
    }

    @Test("User alias defaults outrank system canonical defaults; canonical spelling wins within one file")
    func aliasPrecedence() {
        let merged = MimeApps.mergeDefaults([
            "[Default Applications]\nvideo/x-matroska=LavaPlayer.desktop;",
            "[Default Applications]\nvideo/matroska=mpv.desktop;",
        ], aliases: aliases)
        #expect(merged["video/matroska"] == ["LavaPlayer.desktop", "mpv.desktop"])
        let both = MimeApps.mergeDefaults([
            "[Default Applications]\nvideo/x-matroska=mpv.desktop;\nvideo/matroska=LavaPlayer.desktop;"
        ], aliases: aliases)
        #expect(both["video/matroska"]?.first == "LavaPlayer.desktop")
    }

    @Test("XDG desktop-specific, user and system files follow precedence order")
    func searchPaths() {
        let paths = MimeApps.mimeappsPaths(environment: [
            "HOME": "/home/test", "XDG_CONFIG_HOME": "/config", "XDG_CONFIG_DIRS": "/etc/one:/etc/two",
            "XDG_DATA_HOME": "/data", "XDG_DATA_DIRS": "/share/one:/share/two", "XDG_CURRENT_DESKTOP": "Lava:Other",
        ])
        #expect(Array(paths.prefix(6)) == [
            "/config/lava-mimeapps.list", "/config/other-mimeapps.list", "/config/mimeapps.list",
            "/etc/one/lava-mimeapps.list", "/etc/one/other-mimeapps.list", "/etc/one/mimeapps.list",
        ])
        #expect(paths.firstIndex(of: "/etc/two/mimeapps.list")! < paths.firstIndex(of: "/data/applications/lava-mimeapps.list")!)
        #expect(paths.last == "/share/two/applications/mimeapps.list")
    }
}
