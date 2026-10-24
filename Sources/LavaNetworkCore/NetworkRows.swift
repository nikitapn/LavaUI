import Foundation

/// One Wi-Fi network as the list shows it: every access point that shares a
/// name is one row. A home network with a 2.4 GHz and a 5 GHz radio, or an
/// office with a dozen, is still one choice.
public struct WifiNetwork: Equatable, Sendable, Identifiable {
    public var ssid: String
    /// The strongest access point's, which is the one a connect names.
    public var strength: Int
    public var security: NetSecurity
    public var accessPoint: String
    public var device: String
    /// The saved connection for this name, if there is one — the most
    /// recently used, when several were saved over the years.
    public var saved: NetConnection?
    /// The active connection on it, while connecting or connected.
    public var active: NetActive?

    public var id: String { ssid }

    public var isConnected: Bool { active?.state == .activated }
    public var isConnecting: Bool { active?.state == .activating }
}

/// A VPN or a WireGuard tunnel, and whether it is up.
public struct VPNRow: Equatable, Sendable, Identifiable {
    public var connection: NetConnection
    public var active: NetActive?

    public var id: String { connection.path }
    public var isOn: Bool {
        guard let state = active?.state else { return false }
        return state == .activating || state == .activated
    }
    public var isConnecting: Bool { active?.state == .activating }
}

/// A wired port.
public struct WiredRow: Equatable, Sendable, Identifiable {
    public var device: NetDevice
    public var active: NetActive?

    public var id: String { device.path }

    public var status: String {
        if device.isConnected { return device.ip4.isEmpty ? "Connected" : device.ip4 }
        if device.isConnecting { return "Connecting…" }
        if device.isUnavailable { return "Cable unplugged" }
        return "Disconnected"
    }
}

/// What the strip's glyph shows.
public struct NetworkStatus: Equatable, Sendable {
    public enum Link: Equatable, Sendable {
        /// NetworkManager is not running, or networking is switched off.
        case off
        case disconnected
        case connecting
        case wired
        /// Bars, 0…4.
        case wifi(bars: Int)
    }

    public var link: Link
    public var vpn: Bool
    /// Connected, but not to the internet: a captive portal, or a router
    /// with no uplink.
    public var limited: Bool

    public init(link: Link, vpn: Bool = false, limited: Bool = false) {
        self.link = link
        self.vpn = vpn
        self.limited = limited
    }
}

public enum NetworkRows {
    /// The Wi-Fi list: connected first, then saved networks, then the rest,
    /// each group strongest first.
    public static func wifi(_ state: NetworkState) -> [WifiNetwork] {
        var best: [String: NetAccessPoint] = [:]
        var bySSIDPaths: [String: Set<String>] = [:]
        var order: [String] = []
        for ap in state.accessPoints where !ap.ssid.isEmpty {
            bySSIDPaths[ap.ssid, default: []].insert(ap.path)
            if let had = best[ap.ssid] {
                if ap.strength > had.strength { best[ap.ssid] = ap }
            } else {
                best[ap.ssid] = ap
                order.append(ap.ssid)
            }
        }

        let wifiActive = state.active.filter { $0.type == NetConnection.wifiType }
        var rows: [WifiNetwork] = []
        for ssid in order {
            guard let ap = best[ssid] else { continue }
            let saved = state.connections
                .filter { $0.type == NetConnection.wifiType && $0.ssid == ssid }
                .max { $0.timestamp < $1.timestamp }
            let paths = bySSIDPaths[ssid] ?? []
            // By access point first — the one NetworkManager says it is on —
            // and by the saved connection otherwise: while associating,
            // the specific object can still be "/".
            let active = wifiActive.first { paths.contains($0.specificObject) }
                ?? wifiActive.first { candidate in
                    state.connections.contains {
                        $0.path == candidate.connection && $0.ssid == ssid
                    }
                }
            rows.append(WifiNetwork(
                ssid: ssid, strength: ap.strength, security: ap.security,
                accessPoint: ap.path, device: ap.device, saved: saved, active: active
            ))
        }
        return rows.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            if a.strength != b.strength { return a.strength > b.strength }
            return a.ssid.localizedCaseInsensitiveCompare(b.ssid) == .orderedAscending
        }
    }

    /// What the network window lists itself, out of `wifi`'s rows: the
    /// network in use, then saved ones in range — the realistic switches —
    /// up to `saved` of them. Everything else is behind "All Wi-Fi networks".
    public static func quick(_ rows: [WifiNetwork], saved: Int = 3) -> [WifiNetwork] {
        rows.filter { $0.active != nil }
            + rows.filter { $0.active == nil && $0.saved != nil }.prefix(saved)
    }

    private static func rank(_ network: WifiNetwork) -> Int {
        if network.active != nil { return 0 }
        if network.saved != nil { return 1 }
        return 2
    }

    public static func vpns(_ state: NetworkState) -> [VPNRow] {
        state.connections.filter(\.isVPN)
            .map { conn in
                VPNRow(
                    connection: conn,
                    active: state.active.first { $0.connection == conn.path }
                        ?? state.active.first { !conn.uuid.isEmpty && $0.uuid == conn.uuid }
                )
            }
            .sorted { $0.connection.id.localizedCaseInsensitiveCompare($1.connection.id) == .orderedAscending }
    }

    /// Ethernet ports NetworkManager manages. An unmanaged one is someone
    /// else's — a container bridge, a VM's tap — and not a choice here.
    public static func wired(_ state: NetworkState) -> [WiredRow] {
        state.devices.filter { $0.kind == .ethernet && $0.managed }.map { device in
            WiredRow(device: device, active: state.active.first { $0.path == device.activeConnection })
        }
    }

    /// nmcli's thresholds, so the glyph and `nmcli dev wifi` agree.
    public static func bars(_ strength: Int) -> Int {
        switch strength {
        case 81...: return 4
        case 56...80: return 3
        case 31...55: return 2
        case 6...30: return 1
        default: return 0
        }
    }

    public static func status(_ state: NetworkState) -> NetworkStatus {
        guard state.running, state.networkingEnabled else { return NetworkStatus(link: .off) }
        let up = state.active.filter { $0.state == .activated }
        let vpn = up.contains { $0.vpn || $0.type == "wireguard" }
        // The link under any tunnel: wired beats Wi-Fi, which is also how
        // NetworkManager ranks their routes by default.
        let link: NetworkStatus.Link
        if up.contains(where: { $0.type == NetConnection.ethernetType }) {
            link = .wired
        } else if let wifi = up.first(where: { $0.type == NetConnection.wifiType }) {
            let strength = state.accessPoints.first { $0.path == wifi.specificObject }?.strength
                ?? state.devices.first { $0.path == wifi.device }
                    .flatMap { device in state.accessPoints.first { $0.path == device.activeAccessPoint } }?
                    .strength
                ?? 0
            link = .wifi(bars: bars(strength))
        } else if state.active.contains(where: { $0.state == .activating && !$0.vpn }) {
            link = .connecting
        } else {
            link = .disconnected
        }
        let connected = link == .wired || { if case .wifi = link { return true }; return false }()
        return NetworkStatus(
            link: link, vpn: vpn && connected,
            limited: connected && state.connectivity > 0 && state.connectivity < 4
        )
    }

    /// One line for the strip's tooltip.
    public static func summary(_ state: NetworkState) -> String {
        let status = status(state)
        let vpnName = state.active.first { ($0.vpn || $0.type == "wireguard") && $0.state == .activated }?.id
        var text: String
        switch status.link {
        case .off: text = state.running ? "Networking is off" : "NetworkManager is not running"
        case .disconnected: text = "Not connected"
        case .connecting: text = "Connecting…"
        case .wired:
            text = state.active.first { $0.type == NetConnection.ethernetType && $0.state == .activated }?.id
                ?? "Wired"
        case .wifi:
            text = state.active.first { $0.type == NetConnection.wifiType && $0.state == .activated }?.id
                ?? "Wi-Fi"
        }
        if status.limited { text += " — no internet" }
        if let vpnName, status.vpn { text += " · VPN \(vpnName)" }
        return text
    }
}
