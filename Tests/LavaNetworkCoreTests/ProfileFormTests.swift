import Foundation
import Testing

@testable import LavaNetworkCore

@Suite("Profile form")
struct ProfileFormTests {
    static let home = NetConnection(
        path: "/C/home", id: "Home", type: NetConnection.wifiType, ssid: "Home",
        ip4: IPv4Settings(method: "auto", dns: ["9.9.9.9"])
    )

    @Test("IPv4 the way NetworkManager parses it")
    func addresses() {
        #expect(IPv4.isAddress("192.168.1.20"))
        #expect(IPv4.isAddress("0.0.0.0"))
        for bad in ["256.1.1.1", "1.2.3", "1.2.3.4.5", "01.2.3.4", "a.b.c.d", "1..2.3", "", "١.2.3.4"] {
            #expect(!IPv4.isAddress(bad), "\(bad)")
        }
        #expect(IPv4.cidr("10.0.0.2/8")! == ("10.0.0.2", 8))
        #expect(IPv4.cidr("10.0.0.2")! == ("10.0.0.2", 24))
        #expect(IPv4.cidr("10.0.0.2/0") == nil)
        #expect(IPv4.cidr("10.0.0.2/33") == nil)
        #expect(IPv4.cidr("10.0.0.2/x") == nil)
    }

    @Test("an untouched form has nothing to send")
    func untouched() {
        let form = ProfileForm(Self.home)
        #expect(form.edit(from: form) == nil)
        #expect(form.isValid)
        // Retyping the same list another way is not a change.
        var spaced = form
        spaced.dns = "  9.9.9.9 "
        #expect(spaced.edit(from: form) == nil)
    }

    @Test("only what changed is sent; IPv4 goes whole")
    func edits() throws {
        let original = ProfileForm(Self.home)
        var form = original
        form.name = "  Home 5G "
        #expect(form.edit(from: original) == ProfileEdit(name: "Home 5G"))

        form = original
        form.method = "manual"
        form.addresses = "192.168.1.20/24,10.1.1.1"
        form.gateway = " 192.168.1.1 "
        let edit = try #require(form.edit(from: original))
        #expect(edit.name == nil && edit.autoconnect == nil && edit.neverDefault == nil)
        #expect(edit.ip4 == .init(method: "manual", addresses: ["192.168.1.20/24", "10.1.1.1"],
                                  gateway: "192.168.1.1", dns: ["9.9.9.9"], ignoreAutoDNS: false))

        // Going back to automatic drops the static half rather than sending
        // addresses NetworkManager would refuse beside "auto".
        var auto = form
        auto.method = "auto"
        let back = try #require(auto.edit(from: form))
        #expect(back.ip4?.addresses == [] && back.ip4?.gateway == "")

        var off = form
        off.method = "disabled"
        #expect(off.edit(from: form)?.ip4?.dns == [])
    }

    @Test("problems name the field and the value")
    func problems() {
        var form = ProfileForm(Self.home)
        form.name = " "
        form.method = "manual"
        #expect(form.problems[.name] != nil)
        #expect(form.problems[.addresses]?.contains("needed") == true)
        form.addresses = "192.168.1.20/24, 192.168.1.300"
        form.gateway = "router"
        form.dns = "1.1.1.1, dns.example"
        #expect(form.problems[.addresses]?.contains("192.168.1.300") == true)
        #expect(form.problems[.gateway]?.contains("router") == true)
        #expect(form.problems[.dns]?.contains("dns.example") == true)
        // A gateway is not checked when it is not going to be sent.
        form.method = "auto"
        #expect(form.problems[.gateway] == nil && form.problems[.addresses] == nil)
    }

    @Test("a profile with no IPv4 setting reads as automatic")
    func noIPv4() {
        let wg = NetConnection(path: "/C/wg", id: "wg0", type: "wireguard")
        #expect(ProfileForm(wg).method == "auto")
    }
}

@Suite("Saved profiles")
struct SavedProfileTests {
    @Test("saved Wi-Fi: the one in use, then most recently used, in range or not")
    func savedWifi() {
        var s = NetworkState()
        s.accessPoints = [NetAccessPoint(path: "/AP/1", device: "/D", ssid: "Office", strength: 50,
                                         security: .psk)]
        s.connections = [
            NetConnection(path: "/C/a", id: "Old", type: NetConnection.wifiType, ssid: "Old", timestamp: 10),
            NetConnection(path: "/C/b", id: "Office", type: NetConnection.wifiType, ssid: "Office",
                          timestamp: 50),
            NetConnection(path: "/C/c", id: "Hotel", type: NetConnection.wifiType, ssid: "Hotel",
                          timestamp: 90),
            NetConnection(path: "/C/vpn", id: "VPN", type: "vpn"),
        ]
        s.active = [NetActive(path: "/AC/1", id: "Old", type: NetConnection.wifiType, state: .activated,
                              connection: "/C/a")]
        let rows = NetworkRows.savedWifi(s)
        #expect(rows.map(\.connection.id) == ["Old", "Hotel", "Office"])
        #expect(rows[0].isOn)
        #expect(rows.map(\.inRange) == [false, false, true])
        #expect(NetworkRows.profile(s, path: "/C/b")?.inRange == true)
        #expect(NetworkRows.profile(s, path: "/C/vpn")?.inRange == true)
        #expect(NetworkRows.profile(s, path: "/C/gone") == nil)
    }

    @Test("a link's details, only while it is up")
    func details() {
        var device = NetDevice(path: "/D", iface: "enp0s31f6", kind: .ethernet, state: 100,
                               ip4: "192.168.1.20/24", gateway: "192.168.1.1",
                               dns: ["192.168.1.1", "9.9.9.9"], hwAddress: "AA:BB:CC:00:11:22",
                               speed: 1000)
        #expect(NetworkRows.details(device).map(\.label)
                    == ["IPv4 address", "Gateway", "DNS", "Speed", "Hardware address"])
        #expect(NetworkRows.details(device).first { $0.label == "Speed" }?.value == "1 Gb/s")
        #expect(NetworkRows.details(device).first { $0.label == "DNS" }?.value == "192.168.1.1, 9.9.9.9")
        device.speed = 100
        #expect(NetworkRows.details(device).first { $0.label == "Speed" }?.value == "100 Mb/s")
        device.state = 30
        #expect(NetworkRows.details(device).isEmpty)
    }

    @Test("when a profile was last used, in days")
    func lastUsed() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func ago(_ days: Double) -> UInt64 { UInt64(now.timeIntervalSince1970 - days * 86_400) }
        #expect(NetworkRows.lastUsed(0, now: now, calendar: calendar) == "Never used")
        #expect(NetworkRows.lastUsed(ago(0), now: now, calendar: calendar) == "Used today")
        #expect(NetworkRows.lastUsed(ago(1), now: now, calendar: calendar) == "Used yesterday")
        #expect(NetworkRows.lastUsed(ago(5), now: now, calendar: calendar) == "Used 5 days ago")
        #expect(NetworkRows.lastUsed(ago(65), now: now, calendar: calendar) == "Used 2 months ago")
        #expect(NetworkRows.lastUsed(ago(800), now: now, calendar: calendar) == "Used 2 years ago")
    }
}
