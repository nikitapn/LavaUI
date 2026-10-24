import Foundation
import Testing

@testable import LavaNetworkCore

@Suite("Network rows")
struct NetworkRowsTests {
    static let wlan = "/org/freedesktop/NetworkManager/Devices/3"

    // A home router on two bands under one name, a neighbour, a saved
    // phone hotspot that is out of range, and a café that asks nothing.
    static func state() -> NetworkState {
        var s = NetworkState()
        s.running = true
        s.wirelessEnabled = true
        s.connectivity = 4
        s.devices = [
            NetDevice(path: wlan, iface: "wlp2s0", kind: .wifi, state: 100,
                      activeConnection: "/AC/1", activeAccessPoint: "/AP/2"),
            NetDevice(path: "/D/eth", iface: "enp0s31f6", kind: .ethernet, state: 20),
            NetDevice(path: "/D/docker", iface: "docker0", kind: .other, state: 100, managed: false),
        ]
        s.accessPoints = [
            NetAccessPoint(path: "/AP/1", device: wlan, ssid: "Home", strength: 40, security: .psk),
            NetAccessPoint(path: "/AP/2", device: wlan, ssid: "Home", strength: 72, security: .psk,
                           frequency: 5180),
            NetAccessPoint(path: "/AP/3", device: wlan, ssid: "Neighbour", strength: 90, security: .sae),
            NetAccessPoint(path: "/AP/4", device: wlan, ssid: "Café", strength: 30, security: .open),
            NetAccessPoint(path: "/AP/5", device: wlan, ssid: "Office", strength: 50,
                           security: .enterprise),
            NetAccessPoint(path: "/AP/6", device: wlan, ssid: "Saved Far", strength: 10, security: .psk),
        ]
        s.connections = [
            NetConnection(path: "/C/home-old", id: "Home 1", type: NetConnection.wifiType,
                          ssid: "Home", timestamp: 100),
            NetConnection(path: "/C/home", id: "Home", type: NetConnection.wifiType,
                          ssid: "Home", timestamp: 900),
            NetConnection(path: "/C/far", id: "Saved Far", type: NetConnection.wifiType,
                          ssid: "Saved Far", timestamp: 50),
            NetConnection(path: "/C/vpn", id: "zodiac-udp", uuid: "u-vpn", type: "vpn",
                          vpnService: "org.freedesktop.NetworkManager.openvpn"),
            NetConnection(path: "/C/wg", id: "OVH", uuid: "u-wg", type: "wireguard"),
            NetConnection(path: "/C/eth", id: "Wired connection 1", type: NetConnection.ethernetType),
        ]
        s.active = [
            NetActive(path: "/AC/1", id: "Home", type: NetConnection.wifiType, state: .activated,
                      connection: "/C/home", specificObject: "/AP/2", device: wlan, isDefault: true),
        ]
        s.primary = "/AC/1"
        return s
    }

    @Test("one row per name, the strongest access point, connected first")
    func grouping() {
        let rows = NetworkRows.wifi(Self.state())
        #expect(rows.map(\.ssid) == ["Home", "Saved Far", "Neighbour", "Office", "Café"])
        let home = rows[0]
        #expect(home.accessPoint == "/AP/2")
        #expect(home.strength == 72)
        #expect(home.isConnected)
        // The connection used most recently, of the two saved for it.
        #expect(home.saved?.path == "/C/home")
        #expect(rows.first { $0.ssid == "Café" }?.saved == nil)
    }

    @Test("connecting is found by the saved connection while the access point is not known yet")
    func connectingWithoutAccessPoint() {
        var s = Self.state()
        s.active = [NetActive(path: "/AC/9", id: "Saved Far", type: NetConnection.wifiType,
                              state: .activating, connection: "/C/far", specificObject: "/")]
        let rows = NetworkRows.wifi(s)
        #expect(rows[0].ssid == "Saved Far")
        #expect(rows[0].isConnecting)
        #expect(NetworkRows.status(s).link == .connecting)
    }

    @Test("the quick list: the network in use, then saved ones in range, capped")
    func quick() {
        var s = Self.state()
        for i in 0..<5 {
            s.accessPoints.append(NetAccessPoint(path: "/AP/s\(i)", device: Self.wlan, ssid: "Saved \(i)",
                                                 strength: 60 - i, security: .psk))
            s.connections.append(NetConnection(path: "/C/s\(i)", id: "Saved \(i)",
                                               type: NetConnection.wifiType, ssid: "Saved \(i)"))
        }
        let rows = NetworkRows.wifi(s)
        #expect(NetworkRows.quick(rows).map(\.ssid) == ["Home", "Saved 0", "Saved 1", "Saved 2"])
        // Nothing up: Home is still saved, and the strongest of them.
        s.active = []
        #expect(NetworkRows.quick(NetworkRows.wifi(s)).map(\.ssid) == ["Home", "Saved 0", "Saved 1"])
        #expect(NetworkRows.quick([]).isEmpty)
    }

    @Test("a lock means a password, or a login")
    func locks() {
        #expect(NetSecurity.psk.showsLock && NetSecurity.sae.showsLock && NetSecurity.wep.showsLock)
        #expect(NetSecurity.enterprise.showsLock && !NetSecurity.enterprise.needsPassword)
        #expect(!NetSecurity.open.showsLock && !NetSecurity.owe.showsLock)
    }

    @Test("VPNs and WireGuard, by name, with their state")
    func vpns() {
        var s = Self.state()
        s.active.append(NetActive(path: "/AC/2", id: "zodiac-udp", uuid: "u-vpn", type: "vpn",
                                  state: .activating, vpn: true, connection: "/C/vpn"))
        let rows = NetworkRows.vpns(s)
        #expect(rows.map(\.connection.id) == ["OVH", "zodiac-udp"])
        #expect(!rows[0].isOn)
        #expect(rows[1].isOn && rows[1].isConnecting)
    }

    @Test("wired ports NetworkManager manages, with what they are doing")
    func wired() {
        let rows = NetworkRows.wired(Self.state())
        #expect(rows.map(\.device.iface) == ["enp0s31f6"])
        #expect(rows[0].status == "Cable unplugged")
    }

    @Test("bars follow nmcli's thresholds")
    func bars() {
        #expect([0, 5, 6, 30, 31, 55, 56, 80, 81, 100].map(NetworkRows.bars) == [0, 0, 1, 1, 2, 2, 3, 3, 4, 4])
    }

    @Test("the glyph: Wi-Fi bars from the access point in use, VPN on top, limited")
    func status() {
        var s = Self.state()
        #expect(NetworkRows.status(s) == NetworkStatus(link: .wifi(bars: 3)))
        s.active.append(NetActive(path: "/AC/3", id: "OVH", type: "wireguard", state: .activated,
                                  connection: "/C/wg"))
        s.connectivity = 2
        #expect(NetworkRows.status(s) == NetworkStatus(link: .wifi(bars: 3), vpn: true, limited: true))
        #expect(NetworkRows.summary(s) == "Home — no internet · VPN OVH")
    }

    @Test("wired beats Wi-Fi; nothing up is disconnected; no NetworkManager is off")
    func links() {
        var s = Self.state()
        s.active.append(NetActive(path: "/AC/4", id: "Wired connection 1",
                                  type: NetConnection.ethernetType, state: .activated))
        #expect(NetworkRows.status(s).link == .wired)
        s.active = []
        #expect(NetworkRows.status(s).link == .disconnected)
        #expect(NetworkRows.summary(s) == "Not connected")
        s.running = false
        #expect(NetworkRows.status(s).link == .off)
        #expect(NetworkRows.summary(s) == "NetworkManager is not running")
    }
}
