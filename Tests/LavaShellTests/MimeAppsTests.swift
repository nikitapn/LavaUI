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
