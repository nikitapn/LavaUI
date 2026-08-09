import Testing

@testable import LavaShell

// What a desktop entry means, tested against text rather than against whatever
// happens to be installed on the machine running the tests. Every case here is
// one this parser met in the wild on a normal Arch install.

@Suite("Desktop entry parsing")
struct DesktopEntryParsingTests {
    @Test("reads the fields a launcher shows")
    func readsFields() throws {
        let entry = try #require(DesktopEntry.parse(text: """
            [Desktop Entry]
            Type=Application
            Name=Firefox
            GenericName=Web Browser
            Comment=Browse the World Wide Web
            Exec=firefox %u
            Icon=firefox
            Categories=Network;WebBrowser;
            Keywords=Internet;WWW;Browser;
            StartupWMClass=firefox
            """, id: "firefox"))

        #expect(entry.name == "Firefox")
        #expect(entry.genericName == "Web Browser")
        #expect(entry.icon == "firefox")
        #expect(entry.categories == ["Network", "WebBrowser"])
        #expect(entry.keywords == ["Internet", "WWW", "Browser"])
        #expect(entry.startupWMClass == "firefox")
        #expect(!entry.terminal)
    }

    @Test("ignores everything after the first group")
    func ignoresActionGroups() throws {
        // The trap this exists for: an action group's Name and Icon describe a
        // right-click item, not the application, and reading the last one
        // wins would show "New Private Window" in the launcher.
        let entry = try #require(DesktopEntry.parse(text: """
            [Desktop Entry]
            Type=Application
            Name=Firefox
            Exec=firefox
            Icon=firefox

            [Desktop Action new-private-window]
            Name=New Private Window
            Exec=firefox --private-window
            Icon=private-browsing
            """, id: "firefox"))

        #expect(entry.name == "Firefox")
        #expect(entry.icon == "firefox")
        #expect(entry.exec == "firefox")
    }

    @Test("skips entries that ask not to be listed")
    func skipsHidden() {
        let noDisplay = """
            [Desktop Entry]
            Type=Application
            Name=A MIME handler
            Exec=handler
            NoDisplay=true
            """
        let hidden = """
            [Desktop Entry]
            Type=Application
            Name=Deleted
            Exec=gone
            Hidden=true
            """
        let link = """
            [Desktop Entry]
            Type=Link
            Name=Somewhere
            URL=https://example.com
            """
        #expect(DesktopEntry.parse(text: noDisplay, id: "a") == nil)
        #expect(DesktopEntry.parse(text: hidden, id: "b") == nil)
        #expect(DesktopEntry.parse(text: link, id: "c") == nil)
    }

    @Test("an entry with no Exec is not launchable and not listed")
    func requiresExec() {
        #expect(DesktopEntry.parse(text: """
            [Desktop Entry]
            Type=Application
            Name=Nothing
            """, id: "nothing") == nil)
    }

    @Test("Terminal=true is carried through")
    func terminalFlag() throws {
        let entry = try #require(DesktopEntry.parse(text: """
            [Desktop Entry]
            Type=Application
            Name=htop
            Exec=htop
            Terminal=true
            """, id: "htop"))
        #expect(entry.terminal)
    }
}

@Suite("Exec lines")
struct ExecTests {
    private func entry(_ exec: String, terminal: Bool = false) -> DesktopEntry {
        DesktopEntry(
            id: "test", name: "Test", genericName: "", comment: "", icon: "",
            exec: exec, workingDirectory: "", terminal: terminal,
            categories: [], keywords: [], startupWMClass: ""
        )
    }

    @Test("drops the field codes")
    func dropsFieldCodes() {
        // The bug this prevents: an editor handed the literal "%F" opens a
        // file by that name instead of starting empty.
        #expect(entry("firefox %u").command() == ["firefox"])
        #expect(entry("gimp-2.10 %U").command() == ["gimp-2.10"])
        #expect(entry("code --unity-launch %F").command()
                    == ["code", "--unity-launch"])
        #expect(entry("app %i %c %k").command() == ["app"])
    }

    @Test("keeps quoted arguments whole")
    func keepsQuotedArguments() {
        #expect(entry("\"/opt/My App/run\" --flag").command()
                    == ["/opt/My App/run", "--flag"])
        #expect(entry("sh -c \"echo hello world\"").command()
                    == ["sh", "-c", "echo hello world"])
    }

    @Test("%% is a literal percent")
    func literalPercent() {
        #expect(entry("app %%").command() == ["app", "%"])
        #expect(entry("app 50%%off").command() == ["app", "50%off"])
    }

    @Test("collapses runs of whitespace")
    func collapsesWhitespace() {
        #expect(entry("  app   --flag  ").command() == ["app", "--flag"])
    }
}

@Suite("Searching")
struct SearchTests {
    private func entry(
        _ id: String, _ name: String, generic: String = "",
        keywords: [String] = [], comment: String = ""
    ) -> DesktopEntry {
        DesktopEntry(
            id: id, name: name, genericName: generic, comment: comment,
            icon: "", exec: id, workingDirectory: "", terminal: false,
            categories: [], keywords: keywords, startupWMClass: ""
        )
    }

    @Test("an exact name beats a prefix beats a substring")
    func ranking() {
        let entries = [
            entry("barcode", "Barcode Scanner"),
            entry("visual-studio-code", "Visual Studio Code"),
            entry("code", "Code"),
        ]
        let names = DesktopEntry.search("code", in: entries).map(\.name)
        // Exact, then a word inside the name, then merely containing the
        // letters — which is the order that puts the thing you meant first.
        #expect(names == ["Code", "Visual Studio Code", "Barcode Scanner"])
    }

    @Test("finds an application by what it is, not only what it is called")
    func findsByKeyword() {
        let entries = [
            entry("firefox", "Firefox", generic: "Web Browser",
                  keywords: ["Internet", "WWW"]),
            entry("gedit", "Text Editor"),
        ]
        #expect(DesktopEntry.search("browser", in: entries).map(\.id) == ["firefox"])
        #expect(DesktopEntry.search("www", in: entries).map(\.id) == ["firefox"])
    }

    @Test("an empty query is everything, unreordered")
    func emptyQuery() {
        let entries = [entry("b", "B"), entry("a", "A")]
        #expect(DesktopEntry.search("", in: entries).map(\.id) == ["b", "a"])
        #expect(DesktopEntry.search("   ", in: entries).map(\.id) == ["b", "a"])
    }

    @Test("no match is no results rather than everything")
    func noMatch() {
        let entries = [entry("firefox", "Firefox")]
        #expect(DesktopEntry.search("zzzz", in: entries).isEmpty)
    }

    @Test("ties break by name, so the order does not shuffle as you type")
    func stableOrder() {
        let entries = [
            entry("z", "Zebra Chat"), entry("a", "Alpha Chat"),
        ]
        #expect(DesktopEntry.search("chat", in: entries).map(\.id) == ["a", "z"])
    }
}
