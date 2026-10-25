import Foundation
import LavaBluetoothCore
import LavaUI
import Testing

@testable import LavaBluetooth

/// `BluetoothSession` against tools/mock_bluez.py: the snapshot, the
/// commands, and the agent answering what bluetoothd asks it. One run per
/// mock — pairing and forgetting change it.
///
/// The system bus points at the mock, so the machine's own adapter is not
/// reachable from here: a test that paired something real, or switched the
/// radio off under a headset in use, would be a test with consequences.
private let mockBus = ProcessInfo.processInfo.environment["LAVA_BT_TEST_BUS"]
    .flatMap { $0.isEmpty ? nil : $0 }

@Suite("Bluetooth session", .serialized, .enabled(if: mockBus != nil))
struct BluetoothSessionTests {
    static let hci = "/org/bluez/hci0"
    static let headphones = hci + "/dev_11_22_33_44_55_01"
    static let mouse = hci + "/dev_11_22_33_44_55_02"
    static let speaker = hci + "/dev_11_22_33_44_55_03"
    static let phone = hci + "/dev_11_22_33_44_55_04"

    /// One session for the suite: GIO reads the bus address once.
    static let session: BluetoothSession = {
        setenv("DBUS_SYSTEM_BUS_ADDRESS", mockBus!, 1)
        setenv("DBUS_SESSION_BUS_ADDRESS", mockBus!, 1)
        return BluetoothSession()
    }()

    /// Drains the main queue until `condition` holds, or fails after `timeout`.
    static func until(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            MainQueue.drain()
            if condition() { return true }
            usleep(20_000)
        }
        MainQueue.drain()
        return condition()
    }

    static func device(_ path: String) -> BtDevice? {
        session.state.devices.first { $0.path == path }
    }

    final class Answer: @unchecked Sendable {
        var text = ""
    }

    static func call(_ method: String, _ device: String, number: UInt32 = 0, text: String = "")
        -> Answer
    {
        let answer = Answer()
        session.testCallAgent(method, device: device, number: number, text: text) {
            answer.text = $0
        }
        return answer
    }

    static func newPrompt(after count: Int) -> BluetoothSession.PairingPrompt? {
        guard until(5, { session.prompts.count > count }) else { return nil }
        return session.prompts.last
    }

    @Test func snapshot() {
        let s = Self.session
        #expect(Self.until { s.state.running && s.state.devices.count == 4 })
        #expect(Self.until { s.state.agent }, "the agent registered and became the default")
        #expect(s.state.adapter?.path == Self.hci)
        #expect(s.state.adapter?.powered == true)
        let head = Self.device(Self.headphones)
        #expect(head?.connected == true)
        #expect(head?.battery == 80)
        #expect(head?.kind == .headphones)
        #expect(Self.device(Self.mouse)?.battery == nil)
        #expect(s.known.map(\.name).prefix(1) == ["Headphones"])
        #expect(s.discovered.map(\.name).last == "Phone", "the far one last")
    }

    @Test func power() {
        let s = Self.session
        s.setPowered(false)
        #expect(Self.until { s.state.adapter?.powered == false })
        #expect(s.status == .off)
        s.setPowered(true)
        #expect(Self.until { s.state.adapter?.powered == true })
    }

    @Test func search() {
        let s = Self.session
        s.setSearching(true)
        #expect(Self.until { s.state.adapter?.discovering == true })
        s.setSearching(false)
        #expect(Self.until { s.state.adapter?.discovering == false })
    }

    /// Then forgets it: one test, so the order is not the runner's to pick.
    /// BlueZ ends a discovery when the radio goes off and says nothing to
    /// whoever started it; on again with the pane still open, it searches.
    @Test func searchComesBackAfterPowerCycle() throws {
        let s = Self.session
        s.setSearching(true)
        #expect(Self.until { s.state.adapter?.discovering == true })
        // What the real daemon does on power-off, done behind our back: the
        // mock leaves Discovering alone when Powered changes.
        let stop = Process()
        stop.executableURL = URL(fileURLWithPath: "/usr/bin/busctl")
        stop.arguments = ["--address=" + mockBus!, "call", "org.bluez", Self.hci,
                          "org.bluez.Adapter1", "StopDiscovery"]
        try stop.run()
        stop.waitUntilExit()
        s.setPowered(false)
        #expect(Self.until { s.state.adapter?.powered == false && s.state.adapter?.discovering == false })
        s.setPowered(true)
        #expect(Self.until { s.state.adapter?.powered == true && s.state.adapter?.discovering == true })
        s.setSearching(false)
        #expect(Self.until { s.state.adapter?.discovering == false })
    }

    @Test func connectDisconnectForget() throws {
        let s = Self.session
        let mouse = try #require(Self.device(Self.mouse))
        s.toggle(mouse)
        #expect(Self.until { Self.device(Self.mouse)?.connected == true })
        #expect(Self.until { Self.device(Self.mouse)?.busy == .idle })
        s.toggle(try #require(Self.device(Self.mouse)))
        #expect(Self.until { Self.device(Self.mouse)?.connected == false })
        #expect(s.recentError == nil)
        s.forget(try #require(Self.device(Self.mouse)))
        #expect(Self.until { Self.device(Self.mouse) == nil })
    }

    @Test func pairTrustsAndConnects() throws {
        let s = Self.session
        s.pair(try #require(Self.device(Self.speaker)))
        #expect(Self.until {
            let d = Self.device(Self.speaker)
            return d?.paired == true && d?.trusted == true && d?.connected == true
        })
        #expect(Self.until { Self.device(Self.speaker)?.busy == .idle })
        #expect(s.known.map(\.name).contains("Speaker"))
        #expect(!s.discovered.map(\.name).contains("Speaker"))
    }

    @Test func renameBlockAndVisibility() throws {
        let s = Self.session
        #expect(Self.until { Self.device(Self.headphones) != nil })
        #expect(Self.device(Self.headphones)?.ownName == "Headphones")
        s.rename(Self.headphones, to: "Desk headphones")
        #expect(Self.until { Self.device(Self.headphones)?.name == "Desk headphones" })
        #expect(Self.device(Self.headphones)?.ownName == "Headphones", "the device's own stays")
        s.rename(Self.hci, to: "lava-desk")
        #expect(Self.until { s.state.adapter?.name == "lava-desk" })

        let phone = try #require(Self.device(Self.phone))
        s.setBlocked(phone, true)
        #expect(Self.until { Self.device(Self.phone)?.blocked == true })
        #expect(!s.discovered.map(\.path).contains(Self.phone), "a blocked device is not offered")
        #expect(BluetoothRows.settingsDevices(s.state).last?.path == Self.phone)
        s.setBlocked(phone, false)
        #expect(Self.until { Self.device(Self.phone)?.blocked == false })

        #expect(s.state.adapter?.discoverableTimeout == 180)
        s.setDiscoverable(true)
        #expect(Self.until { s.state.adapter?.discoverable == true })
        s.setDiscoverable(false)
        #expect(Self.until { s.state.adapter?.discoverable == false })
    }

    @Test func aFailureIsReportedInWords() {
        let s = Self.session
        let ghost = BtDevice(path: Self.hci + "/dev_00_00_00_00_00_99", name: "Ghost")
        s.connect(ghost)
        #expect(Self.until { s.recentError != nil })
        #expect(s.recentError?.hasPrefix("Connect") == true)
    }

    // MARK: - The agent

    @Test func confirmAccepted() throws {
        let s = Self.session
        let before = s.prompts.count
        let answer = Self.call("RequestConfirmation", Self.phone, number: 42)
        let prompt = try #require(Self.newPrompt(after: before))
        #expect(prompt.ask == .confirm(42))
        #expect(prompt.name == "Phone")
        #expect(prompt.text.code == "000042")
        s.accept(prompt.id)
        #expect(Self.until { answer.text == "ok" })
    }

    @Test func confirmDeclined() throws {
        let s = Self.session
        let before = s.prompts.count
        let answer = Self.call("RequestConfirmation", Self.phone, number: 7)
        let prompt = try #require(Self.newPrompt(after: before))
        s.decline(prompt.id)
        #expect(Self.until { answer.text == "error org.bluez.Error.Rejected" })
    }

    @Test func pinAndPasskey() throws {
        let s = Self.session
        var before = s.prompts.count
        let pin = Self.call("RequestPinCode", Self.phone)
        let p1 = try #require(Self.newPrompt(after: before))
        #expect(p1.ask == .pin && p1.wantsInput)
        s.accept(p1.id, text: "0000")
        #expect(Self.until { pin.text == "ok 0000" })

        before = s.prompts.count
        let key = Self.call("RequestPasskey", Self.phone)
        let p2 = try #require(Self.newPrompt(after: before))
        s.accept(p2.id, text: "123456")
        #expect(Self.until { key.text == "ok 123456" })

        // Not a number is a no, not a crash or a zero.
        before = s.prompts.count
        let bad = Self.call("RequestPasskey", Self.phone)
        let p3 = try #require(Self.newPrompt(after: before))
        s.accept(p3.id, text: "12ab")
        #expect(Self.until { bad.text == "error org.bluez.Error.Rejected" })
    }

    @Test func aShownPasskeyUpdatesInPlaceAndCancelTakesItDown() throws {
        let s = Self.session
        final class Gone: @unchecked Sendable { var ids: [UInt64] = [] }
        let gone = Gone()
        s.onPromptGone = { gone.ids.append($0) }
        defer { s.onPromptGone = nil }

        let before = s.prompts.count
        let shown = Self.call("DisplayPasskey", Self.phone, number: 314159, text: "0")
        #expect(Self.until { shown.text == "ok" }, "BlueZ is not kept waiting on a display")
        let prompt = try #require(Self.newPrompt(after: before))
        #expect(prompt.isShown)
        #expect(prompt.text.code == "314159")
        _ = Self.call("DisplayPasskey", Self.phone, number: 314159, text: "3")
        #expect(Self.until {
            s.prompt(prompt.id)?.ask == .showPasskey(314159, entered: 3)
        })
        #expect(s.prompts.count == before + 1, "one prompt, three digits typed")

        let cancel = Self.call("Cancel", "/")
        #expect(Self.until { cancel.text == "ok" })
        #expect(Self.until { s.prompt(prompt.id) == nil })
        #expect(gone.ids.contains(prompt.id))
    }

    @Test func authorizeService() throws {
        let s = Self.session
        let before = s.prompts.count
        let answer = Self.call(
            "AuthorizeService", Self.phone, text: "0000110b-0000-1000-8000-00805f9b34fb")
        let prompt = try #require(Self.newPrompt(after: before))
        #expect(prompt.text.message.contains("audio"))
        s.accept(prompt.id)
        #expect(Self.until { answer.text == "ok" })
    }
}
