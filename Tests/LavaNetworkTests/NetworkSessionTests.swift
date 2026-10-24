import Foundation
import LavaNetworkCore
import LavaUI
import Testing

@testable import LavaNetwork

/// `NetworkSession` against tools/mock_networkmanager.py: the snapshot, the
/// commands, and the agent answering GetSecrets as NetworkManager asks it.
/// One run per mock — joining and disconnecting change it.
///
/// Both buses point at the mock, so neither the machine's NetworkManager
/// nor its keyring is reachable from here — a test that typed a password
/// into the real one would be a test with consequences.
private let mockBus = ProcessInfo.processInfo.environment["LAVA_NET_TEST_BUS"]
    .flatMap { $0.isEmpty ? nil : $0 }

@Suite("Network session", .serialized, .enabled(if: mockBus != nil))
struct NetworkSessionTests {
    static let bus = mockBus

    /// One session for the suite: libnm reads the bus address once.
    nonisolated(unsafe) static let session: NetworkSession = {
        setenv("DBUS_SYSTEM_BUS_ADDRESS", bus!, 1)
        setenv("DBUS_SESSION_BUS_ADDRESS", bus!, 1)
        setenv("NM_VPN_PLUGIN_DIR", fakePlugin(), 1)
        return NetworkSession()
    }()

    /// A VPN plugin whose auth dialog is this script: it keeps what it was
    /// given and describes a form with a password to ask and a user name not
    /// to, as nm-openvpn's does for a password connection.
    static let pluginRoot = NSTemporaryDirectory() + "lava-net-plugin-\(getpid())"

    static func fakePlugin() -> String {
        let dir = pluginRoot
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dialog = dir + "/auth-dialog"
        let script = """
            #!/bin/sh
            echo "$@" > "\(dir)/args"
            cat > "\(dir)/stdin"
            cat <<'FORM'
            [VPN Plugin UI]
            Version=2
            Description=Enter the password for Office VPN.
            Title=Authenticate VPN Office VPN

            [password]
            Value=
            Label=Password:
            IsSecret=true
            ShouldAsk=true

            [username]
            Value=alice
            Label=User name:
            IsSecret=false
            ShouldAsk=false
            FORM
            """
        FileManager.default.createFile(atPath: dialog, contents: Data(script.utf8))
        chmod(dialog, 0o755)
        let name = """
            [VPN Connection]
            name=fakevpn
            service=org.lava.fakevpn
            program=/bin/true

            [GNOME]
            auth-dialog=\(dialog)
            supports-external-ui-mode=true
            supports-hints=true
            """
        FileManager.default.createFile(atPath: dir + "/fakevpn.name", contents: Data(name.utf8))
        return dir
    }

    /// Drains the main queue until `condition` holds, or fails after `timeout`.
    static func wait(
        _ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            MainQueue.drain()
            if condition() { return true }
            usleep(20_000)
        }
        MainQueue.drain()
        return condition()
    }

    /// The agent's answer, once it has one.
    final class Answer: @unchecked Sendable {
        var text = ""
    }

    /// Asks the agent for `setting` on `connection`, the way NetworkManager
    /// would, through `lava_net_test_get_secrets`.
    static func ask(_ connection: String, setting: String, flags: UInt32) -> Answer {
        let answer = Answer()
        session.testGetSecrets(connection: connection, setting: setting, flags: flags) {
            answer.text = $0
        }
        return answer
    }

    /// An SSID as `ay`, without the NUL a GVariant `b''` literal would add.
    static func bytes(_ text: String) -> String {
        "[" + text.utf8.map { "byte 0x" + String($0, radix: 16) }.joined(separator: ", ") + "]"
    }

    static func wifi(_ ssid: String, uuid: String) -> String {
        """
        {'connection': {'id': <'\(ssid)'>, 'uuid': <'\(uuid)'>, 'type': <'802-11-wireless'>}, \
        '802-11-wireless': {'ssid': <\(bytes(ssid))>}, \
        '802-11-wireless-security': {'key-mgmt': <'wpa-psk'>, 'psk-flags': <uint32 0>}}
        """
    }

    // Only what a second run against the same mock still finds: the join and
    // disconnect tests below change which network is saved and up. The order
    // of the rows is NetworkRowsTests' to check.
    @Test("the snapshot: three networks, one saved, their security")
    func snapshot() {
        let session = Self.session
        #expect(Self.wait("access points") { session.state.accessPoints.count == 3 })
        let rows = Dictionary(uniqueKeysWithValues: session.wifi.map { ($0.ssid, $0) })
        #expect(Set(rows.keys) == ["Home", "Neighbour", "Café"])
        #expect(rows["Home"]?.saved != nil)
        #expect(rows["Neighbour"]?.security == .psk)
        #expect(rows["Café"]?.security == .open)
        #expect(session.state.devices.contains { $0.kind == .wifi && $0.iface == "wlan0" })
    }

    @Test("a Wi-Fi password is asked for, and goes back as the PSK")
    func wifiPrompt() throws {
        let session = Self.session
        let answer = Self.ask(
            Self.wifi("Neighbour", uuid: "8f4f1e8a-0000-4000-8000-000000000001"),
            setting: "802-11-wireless-security", flags: 1
        )
        #expect(Self.wait("prompt") { !session.prompts.isEmpty })
        let prompt = try #require(session.prompts.first)
        #expect(prompt.connection == "Neighbour")
        #expect(prompt.message == "Type the password for “Neighbour”.")
        #expect(prompt.asked.map(\.key) == ["psk"])
        #expect(prompt.asked[0].secret)

        session.answer(prompt.id, values: ["psk": "correct horse"])
        #expect(Self.wait("reply") { !answer.text.isEmpty })
        #expect(answer.text == "{'802-11-wireless-security': {'psk': <'correct horse'>}}")
        #expect(session.prompts.isEmpty)
    }

    @Test("asked again straight after an answer is a rejected password")
    func rejected() throws {
        let session = Self.session
        let neighbour = Self.wifi("Neighbour", uuid: "8f4f1e8a-0000-4000-8000-000000000002")
        let first = Self.ask(neighbour, setting: "802-11-wireless-security", flags: 1)
        #expect(Self.wait("first prompt") { !session.prompts.isEmpty })
        session.answer(session.prompts[0].id, values: ["psk": "wrong one"])
        #expect(Self.wait("first reply") { first.text.hasPrefix("{") })

        // ALLOW_INTERACTION | REQUEST_NEW: the association failed.
        let second = Self.ask(neighbour, setting: "802-11-wireless-security", flags: 3)
        #expect(Self.wait("second prompt") { !session.prompts.isEmpty })
        #expect(session.prompts.first?.message
            == "The password for “Neighbour” was not accepted. Try again.")
        session.decline(session.prompts[0].id)
        #expect(Self.wait("cancel") { !second.text.isEmpty })
        #expect(second.text.hasPrefix("error org.freedesktop.NetworkManager.SecretAgent.UserCanceled"))
    }

    @Test("no asking allowed and nothing saved is an error, not a prompt")
    func noInteraction() {
        let session = Self.session
        let answer = Self.ask(
            Self.wifi("Café", uuid: "8f4f1e8a-0000-4000-8000-000000000003"),
            setting: "802-11-wireless-security", flags: 0
        )
        #expect(Self.wait("error") { !answer.text.isEmpty })
        #expect(answer.text.hasPrefix("error org.freedesktop.NetworkManager.SecretAgent.NoSecrets"))
        #expect(session.prompts.isEmpty)
    }

    @Test("NetworkManager calling it off takes the prompt down")
    func cancelledByNetworkManager() throws {
        let session = Self.session
        var gone: [UInt64] = []
        session.onPromptGone = { gone.append($0) }
        defer { session.onPromptGone = nil }
        // A second ask for the same connection and setting replaces nothing,
        // but a cancel for it must find and drop the first.
        _ = Self.ask(
            Self.wifi("Neighbour", uuid: "8f4f1e8a-0000-4000-8000-000000000005"),
            setting: "802-11-wireless-security", flags: 1
        )
        #expect(Self.wait("prompt") { !session.prompts.isEmpty })
        let id = try #require(session.prompts.first?.id)
        session.testCancelSecrets(setting: "802-11-wireless-security")
        #expect(Self.wait("gone") { session.prompts.isEmpty })
        #expect(gone == [id])
    }

    @Test("a VPN asks through its plugin's dialog, and answers with what it did not ask too")
    func vpnPrompt() throws {
        let session = Self.session
        let answer = Self.ask("""
            {'connection': {'id': <'Office VPN'>, 'uuid': <'8f4f1e8a-0000-4000-8000-000000000004'>, \
            'type': <'vpn'>}, 'vpn': {'service-type': <'org.lava.fakevpn'>, \
            'data': <{'username': 'alice', 'password-flags': '2', 'remote': 'vpn.example'}>}}
            """, setting: "vpn", flags: 1)
        #expect(Self.wait("vpn prompt") { !session.prompts.isEmpty })
        let prompt = try #require(session.prompts.first)
        #expect(prompt.title == "Authenticate VPN Office VPN")
        #expect(prompt.message == "Enter the password for Office VPN.")
        #expect(prompt.asked.map(\.key) == ["password"])
        #expect(prompt.fields.first { $0.key == "username" }?.value == "alice")

        // What the dialog was told: who, which service, external UI, may ask.
        let args = try String(contentsOfFile: Self.pluginRoot + "/args", encoding: .utf8)
        #expect(args.contains("-u 8f4f1e8a-0000-4000-8000-000000000004"))
        #expect(args.contains("-s org.lava.fakevpn"))
        #expect(args.contains("--external-ui-mode") && args.contains("-i"))
        let stdin = try String(contentsOfFile: Self.pluginRoot + "/stdin", encoding: .utf8)
        #expect(stdin.contains("DATA_KEY=remote\nDATA_VAL=vpn.example\n\n"))
        #expect(stdin.hasSuffix("DONE\n\n"))

        session.answer(prompt.id, values: ["password": "s3cret"])
        #expect(Self.wait("vpn reply") { !answer.text.isEmpty })
        #expect(answer.text == "{'vpn': {'secrets': <{'password': 's3cret', 'username': 'alice'}>}}")
    }

    /// A property of the mock's NetworkManager, read over its bus.
    static func managerProperty(_ name: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/busctl")
        process.arguments = [
            "--address=\(bus!)", "get-property", "org.freedesktop.NetworkManager",
            "/org/freedesktop/NetworkManager", "org.freedesktop.NetworkManager", name,
        ]
        let out = Pipe()
        process.standardOutput = out
        try? process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("Wi-Fi off and on reach NetworkManager")
    func wireless() {
        let session = Self.session
        #expect(Self.wait("running") { session.state.running })
        session.setWirelessEnabled(false)
        #expect(Self.wait("off at NetworkManager") { Self.managerProperty("WirelessEnabled") == "b false" })
        #expect(Self.wait("off in the snapshot") { !session.state.wirelessEnabled })
        session.setWirelessEnabled(true)
        #expect(Self.wait("on at NetworkManager") { Self.managerProperty("WirelessEnabled") == "b true" })
    }

    @Test("joining a network with no saved connection saves one and starts it")
    func join() throws {
        let session = Self.session
        #expect(Self.wait("café") { session.wifi.contains { $0.ssid == "Café" } })
        let cafe = try #require(session.wifi.first { $0.ssid == "Café" })
        #expect(cafe.saved == nil)
        session.connect(cafe)
        #expect(Self.wait("saved and active") {
            session.wifi.first { $0.ssid == "Café" }.map { $0.saved != nil && $0.active != nil } ?? false
        })
        #expect(session.recentError == nil)
    }

    @Test("disconnect deactivates the connection")
    func disconnect() throws {
        let session = Self.session
        #expect(Self.wait("home up") { session.wifi.first { $0.ssid == "Home" }?.active != nil })
        let active = try #require(session.wifi.first { $0.ssid == "Home" }?.active)
        session.disconnect(active)
        #expect(Self.wait("home down") { !session.state.active.contains { $0.path == active.path } })
    }
}
