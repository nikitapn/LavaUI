import Foundation
import Testing

@testable import LavaBluetoothCore

@Suite("Bluetooth rows")
struct BluetoothRowsTests {
    static let hci = "/org/bluez/hci0"

    // A headset that is on, a mouse that is asleep, a keyboard paired and
    // then blocked, and a scan's worth of strangers.
    static func state() -> BluetoothState {
        var s = BluetoothState()
        s.running = true
        s.adapters = [BtAdapter(path: hci, name: "laptop", powered: true, powerState: "on")]
        s.devices = [
            BtDevice(path: hci + "/dev_mouse", name: "Logi M196", icon: "input-mouse", paired: true),
            BtDevice(path: hci + "/dev_head", name: "soundcore Space One", icon: "audio-headset",
                     paired: true, connected: true, battery: 80),
            BtDevice(path: hci + "/dev_keys", name: "Old keyboard", icon: "input-keyboard",
                     paired: true, blocked: true),
            BtDevice(path: hci + "/dev_far", name: "TV", rssi: -88),
            BtDevice(path: hci + "/dev_near", name: "Pixel 9", icon: "phone", rssi: -48),
            BtDevice(path: hci + "/dev_anon", name: "4C:11:22:33:44:55", hasName: false, rssi: -40),
            BtDevice(path: hci + "/dev_quiet", name: "Speaker"),
        ]
        return s
    }

    @Test func knownDevicesConnectedFirstThenByName() {
        let names = BluetoothRows.known(Self.state()).map(\.name)
        #expect(names == ["soundcore Space One", "Logi M196"])
    }

    @Test func discoveredSkipsKnownUnnamedAndBlocked() {
        let names = BluetoothRows.discovered(Self.state()).map(\.name)
        // Nearest first; one no longer heard goes last.
        #expect(names == ["Pixel 9", "TV", "Speaker"])
    }

    @Test func aConnectedLowEnergyDeviceWithoutPairingIsKnown() {
        var s = Self.state()
        s.devices.append(BtDevice(path: Self.hci + "/dev_le", name: "Heart rate", connected: true))
        #expect(BluetoothRows.known(s).map(\.name).contains("Heart rate"))
        #expect(!BluetoothRows.discovered(s).map(\.name).contains("Heart rate"))
    }

    @Test func status() {
        var s = Self.state()
        #expect(BluetoothRows.status(s) == .connected(1))
        s.devices = s.devices.map { var d = $0; d.connected = false; return d }
        #expect(BluetoothRows.status(s) == .on)
        s.adapters[0].powered = false
        #expect(BluetoothRows.status(s) == .off)
        s.adapters[0].powerState = "off-blocked"
        #expect(BluetoothRows.status(s) == .blocked)
        s.adapters = []
        #expect(BluetoothRows.status(s) == .absent)
        s = Self.state()
        s.running = false
        #expect(BluetoothRows.status(s) == .absent)
    }

    @Test func aPoweredAdapterIsTheOneShown() {
        var s = BluetoothState()
        s.adapters = [BtAdapter(path: "/org/bluez/hci0", powered: false),
                      BtAdapter(path: "/org/bluez/hci1", powered: true)]
        #expect(s.adapter?.path == "/org/bluez/hci1")
    }

    @Test func summaryNamesTheConnectedAndTheirBattery() {
        #expect(BluetoothRows.summary(Self.state()) == "soundcore Space One (80%)")
        var s = Self.state()
        s.devices[0].connected = true
        #expect(BluetoothRows.summary(s) == "Logi M196, soundcore Space One (80%)")
    }

    @Test func deviceStatusWords() {
        var d = BtDevice(path: "/d", name: "x", paired: true)
        #expect(BluetoothRows.status(d) == "")
        d.connected = true
        #expect(BluetoothRows.status(d) == "Connected")
        d.busy = .disconnecting
        #expect(BluetoothRows.status(d) == "Disconnecting…")
        d.busy = .pairing
        #expect(BluetoothRows.status(d) == "Pairing…")
    }

    @Test func kinds() {
        #expect(BtKind(icon: "audio-headset") == .headphones)
        #expect(BtKind(icon: "audio-card") == .speaker)
        #expect(BtKind(icon: "input-mouse") == .mouse)
        #expect(BtKind(icon: "phone") == .phone)
        #expect(BtKind(icon: "") == .other)
    }

    @Test func bars() {
        #expect(BluetoothRows.bars(nil) == 0)
        #expect(BluetoothRows.bars(-45) == 4)
        #expect(BluetoothRows.bars(-65) == 3)
        #expect(BluetoothRows.bars(-75) == 2)
        #expect(BluetoothRows.bars(-95) == 1)
    }

    @Test func errorsSayWhatTheyMean() {
        #expect(BluetoothRows.explain(error: "org.bluez.Error.Failed",
                                      message: "br-connection-page-timeout")
            == "It did not answer. Is it switched on and nearby?")
        #expect(BluetoothRows.explain(error: "org.bluez.Error.Failed",
                                      message: "br-connection-profile-unavailable")
            .hasPrefix("Nothing here can use it"))
        #expect(BluetoothRows.explain(error: "org.bluez.Error.AuthenticationFailed",
                                      message: "Authentication Failed")
            == "Pairing failed. The codes may not have matched.")
        #expect(BluetoothRows.explain(error: "org.bluez.Error.Failed", message: "Blocked through rfkill")
            == "Bluetooth is off at the radio switch.")
        // Unknown: BlueZ's own words, rather than nothing.
        #expect(BluetoothRows.explain(error: "org.bluez.Error.Weird", message: "Something odd")
            == "Something odd")
    }

    @Test func passkeysKeepTheirZeros() {
        #expect(BluetoothRows.passkey(42) == "000042")
        #expect(BluetoothRows.passkey(123456) == "123456")
    }

    @Test func services() {
        #expect(BluetoothRows.service("0000110b-0000-1000-8000-00805f9b34fb") == "audio")
        #expect(BluetoothRows.service("00001124-0000-1000-8000-00805F9B34FB") == "input")
        #expect(BluetoothRows.service("12345678-0000-1000-8000-00805f9b34fb")
            == "12345678-0000-1000-8000-00805f9b34fb")
    }

    @Test func confirmationShowsTheCode() {
        let text = BluetoothRows.text(.confirm(7), device: "Pixel 9")
        #expect(text.code == "000007")
        #expect(text.title == "Pair with Pixel 9?")
    }
}

@Suite("Bluetooth settings rows")
struct BluetoothSettingsRowsTests {
    @Test func blockedDevicesAreListedLast() {
        let names = BluetoothRows.settingsDevices(BluetoothRowsTests.state()).map(\.name)
        #expect(names == ["soundcore Space One", "Logi M196", "Old keyboard"])
    }

    @Test func details() {
        let s = BluetoothRowsTests.state()
        let byName = Dictionary(uniqueKeysWithValues: s.devices.map { ($0.name, $0) })
        #expect(BluetoothRows.detail(byName["soundcore Space One"]!) == "Connected · Battery 80%")
        #expect(BluetoothRows.detail(byName["Logi M196"]!) == "Not connected")
        #expect(BluetoothRows.detail(byName["Old keyboard"]!) == "Blocked")
    }

    @Test func visibilitySaysHowLong() {
        var a = BtAdapter(path: "/a", discoverableTimeout: 180)
        #expect(BluetoothRows.visibility(a).hasSuffix("after 3 minutes."))
        a.discoverableTimeout = 60
        #expect(BluetoothRows.visibility(a).hasSuffix("after 1 minute."))
        a.discoverableTimeout = 0
        #expect(BluetoothRows.visibility(a).hasSuffix("until switched off here."))
    }

    @Test func namesFitInWhatBluetoothCarries() {
        #expect(BluetoothRows.nameProblem("Living room") == nil)
        #expect(BluetoothRows.nameProblem(String(repeating: "é", count: 125)) != nil)
    }
}
