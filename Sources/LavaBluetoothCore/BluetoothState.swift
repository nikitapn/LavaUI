import Foundation

/// What BlueZ says is there, as plain values — the shape of
/// `CLavaBluetooth`'s snapshot, without the C. The rows the panel shows are
/// decided from this, here, where they are a test.
public struct BluetoothState: Equatable, Sendable {
    /// bluetoothd is on the bus.
    public var running = false
    /// The panel's pairing agent is registered and the default.
    public var agent = false
    public var adapters: [BtAdapter] = []
    public var devices: [BtDevice] = []

    public init() {}

    /// The adapter the window is about. Machines with two are rare, and the
    /// second is usually a dongle somebody plugged in because the first one
    /// is broken — so a powered one first.
    public var adapter: BtAdapter? {
        adapters.first { $0.powered } ?? adapters.first
    }
}

public struct BtAdapter: Equatable, Sendable {
    public var path: String
    public var address: String
    public var name: String
    public var powered: Bool
    /// "on", "off", "off-enabling", "on-disabling", "off-blocked"; "".
    public var powerState: String
    public var discovering: Bool
    public var discoverable: Bool
    /// Seconds a visible adapter stays visible; 0 is until switched off.
    public var discoverableTimeout: UInt32
    public var pairable: Bool

    public init(
        path: String, address: String = "", name: String = "", powered: Bool = true,
        powerState: String = "", discovering: Bool = false, discoverable: Bool = false,
        discoverableTimeout: UInt32 = 180, pairable: Bool = true
    ) {
        self.path = path
        self.address = address
        self.name = name
        self.powered = powered
        self.powerState = powerState
        self.discovering = discovering
        self.discoverable = discoverable
        self.discoverableTimeout = discoverableTimeout
        self.pairable = pairable
    }

    /// Held off by the radio switch — rfkill, an airplane-mode key — so a
    /// toggle here would only be refused.
    public var isBlocked: Bool { powerState == "off-blocked" }
    public var isChanging: Bool { powerState == "off-enabling" || powerState == "on-disabling" }
}

public struct BtDevice: Equatable, Sendable, Identifiable {
    /// What this process asked of it and has not heard back about.
    public enum Busy: Int, Sendable {
        case idle = 0, connecting = 1, disconnecting = 2, pairing = 3
    }

    public var path: String
    public var adapter: String
    public var address: String
    public var name: String
    /// The device sent a name; `name` is otherwise its address.
    public var hasName: Bool
    /// That name, which a cleared rename goes back to; "".
    public var ownName: String
    /// freedesktop icon name: "audio-headset", "input-mouse", …
    public var icon: String
    public var deviceClass: UInt32
    public var appearance: UInt32
    public var paired: Bool
    public var trusted: Bool
    public var blocked: Bool
    public var connected: Bool
    /// 0…100, nil when the device reports none.
    public var battery: Int?
    /// dBm while a scan hears it; nil otherwise.
    public var rssi: Int?
    public var busy: Busy

    public var id: String { path }

    public init(
        path: String, adapter: String = "", address: String = "", name: String,
        hasName: Bool = true, ownName: String = "", icon: String = "", deviceClass: UInt32 = 0,
        appearance: UInt32 = 0, paired: Bool = false, trusted: Bool = false,
        blocked: Bool = false, connected: Bool = false, battery: Int? = nil, rssi: Int? = nil,
        busy: Busy = .idle
    ) {
        self.path = path
        self.adapter = adapter
        self.address = address
        self.name = name
        self.hasName = hasName
        self.ownName = ownName
        self.icon = icon
        self.deviceClass = deviceClass
        self.appearance = appearance
        self.paired = paired
        self.trusted = trusted
        self.blocked = blocked
        self.connected = connected
        self.battery = battery
        self.rssi = rssi
        self.busy = busy
    }

    public var kind: BtKind { BtKind(icon: icon) }
}

/// What a device is, for its glyph — from the icon name BlueZ derives from
/// the class of device or the LE appearance, which is already the mapping
/// everyone agrees on.
public enum BtKind: Equatable, Sendable {
    case headphones, speaker, mouse, keyboard, gamepad, phone, computer, tablet, other

    public init(icon: String) {
        switch icon {
        case "audio-headset", "audio-headphones": self = .headphones
        case "audio-card", "audio-speakers", "multimedia-player": self = .speaker
        case "input-mouse": self = .mouse
        case "input-keyboard": self = .keyboard
        case "input-gaming": self = .gamepad
        case "phone": self = .phone
        case "computer": self = .computer
        case "input-tablet": self = .tablet
        default: self = .other
        }
    }
}
