import Foundation

/// What NetworkManager says is there, as plain values — the shape of
/// `CLavaNet`'s snapshot, without the C. The rows the panel shows are
/// decided from this, here, where they are a test.
public struct NetworkState: Equatable, Sendable {
    public var running = false
    public var networkingEnabled = true
    public var wirelessEnabled = false
    /// The radio switch: rfkill, an airplane-mode key.
    public var wirelessHardwareEnabled = true
    /// `NMState`: 70 connected, 60 site-only, 50 local-only, 40 connecting,
    /// 20 disconnected, 10 asleep.
    public var state = 0
    /// `NMConnectivityState`: 4 full, 3 limited, 2 behind a portal, 1 none.
    public var connectivity = 0
    /// The active connection with the default route; "" if none.
    public var primary = ""
    public var scanning = false
    public var devices: [NetDevice] = []
    public var accessPoints: [NetAccessPoint] = []
    public var active: [NetActive] = []
    public var connections: [NetConnection] = []

    public init() {}

    public var hasWifi: Bool { devices.contains { $0.kind == .wifi } }
}

public struct NetDevice: Equatable, Sendable {
    public enum Kind: Int, Sendable { case other = 0, ethernet = 1, wifi = 2 }

    public var path: String
    public var iface: String
    public var kind: Kind
    /// `NMDeviceState`.
    public var state: Int
    public var activeConnection: String
    public var activeAccessPoint: String
    public var managed: Bool
    /// "192.168.1.20/24", or "".
    public var ip4: String

    public init(
        path: String, iface: String, kind: Kind, state: Int, activeConnection: String = "",
        activeAccessPoint: String = "", managed: Bool = true, ip4: String = ""
    ) {
        self.path = path
        self.iface = iface
        self.kind = kind
        self.state = state
        self.activeConnection = activeConnection
        self.activeAccessPoint = activeAccessPoint
        self.managed = managed
        self.ip4 = ip4
    }

    /// `NM_DEVICE_STATE_ACTIVATED`.
    public var isConnected: Bool { state == 100 }
    /// Prepare through secondaries: 40…90.
    public var isConnecting: Bool { (40...90).contains(state) }
    /// `NM_DEVICE_STATE_UNAVAILABLE`: no carrier, or the radio is off.
    public var isUnavailable: Bool { state == 20 }
}

/// What an access point asks before it will associate.
public enum NetSecurity: Int, Sendable {
    case open = 0, wep = 1, psk = 2, sae = 3, enterprise = 4, owe = 5

    /// Whether joining needs something typed.
    public var needsPassword: Bool { self == .wep || self == .psk || self == .sae }
    /// Whether to draw a lock. OWE is encrypted but asks nothing, and is
    /// the one case where a lock would promise a password that never comes.
    public var showsLock: Bool { needsPassword || self == .enterprise }
}

public struct NetAccessPoint: Equatable, Sendable {
    public var path: String
    public var device: String
    public var ssid: String
    public var bssid: String
    /// 0…100.
    public var strength: Int
    public var security: NetSecurity
    /// MHz.
    public var frequency: UInt32

    public init(
        path: String, device: String, ssid: String, bssid: String = "", strength: Int,
        security: NetSecurity, frequency: UInt32 = 2412
    ) {
        self.path = path
        self.device = device
        self.ssid = ssid
        self.bssid = bssid
        self.strength = strength
        self.security = security
        self.frequency = frequency
    }
}

public struct NetActive: Equatable, Sendable {
    public enum State: Int, Sendable {
        case unknown = 0, activating = 1, activated = 2, deactivating = 3, deactivated = 4
    }

    public var path: String
    public var id: String
    public var uuid: String
    public var type: String
    public var state: State
    public var vpn: Bool
    /// The saved connection it runs.
    public var connection: String
    public var specificObject: String
    public var device: String
    public var isDefault: Bool

    public init(
        path: String, id: String, uuid: String = "", type: String, state: State,
        vpn: Bool = false, connection: String = "", specificObject: String = "",
        device: String = "", isDefault: Bool = false
    ) {
        self.path = path
        self.id = id
        self.uuid = uuid
        self.type = type
        self.state = state
        self.vpn = vpn
        self.connection = connection
        self.specificObject = specificObject
        self.device = device
        self.isDefault = isDefault
    }
}

public struct NetConnection: Equatable, Sendable {
    public var path: String
    public var id: String
    public var uuid: String
    public var type: String
    public var ssid: String
    public var vpnService: String
    public var autoconnect: Bool
    /// Seconds since the epoch it last connected; 0 if never.
    public var timestamp: UInt64

    public init(
        path: String, id: String, uuid: String = "", type: String, ssid: String = "",
        vpnService: String = "", autoconnect: Bool = true, timestamp: UInt64 = 0
    ) {
        self.path = path
        self.id = id
        self.uuid = uuid
        self.type = type
        self.ssid = ssid
        self.vpnService = vpnService
        self.autoconnect = autoconnect
        self.timestamp = timestamp
    }

    public static let wifiType = "802-11-wireless"
    public static let ethernetType = "802-3-ethernet"

    /// What the panel lists under VPN: a plugin VPN or a WireGuard tunnel.
    public var isVPN: Bool { type == "vpn" || type == "wireguard" }
}
