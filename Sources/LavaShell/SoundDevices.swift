import Foundation

/// What the sound server says is there, as plain values — the shape of
/// `CPulse`'s snapshot, without the C. Kept here so the choosing of rows can
/// be tested with no server.
public struct SoundPort: Equatable, Sendable {
    public enum Availability: Sendable { case unknown, no, yes }

    public var name: String
    public var description: String
    public var availability: Availability

    public init(name: String, description: String, availability: Availability) {
        self.name = name
        self.description = description
        self.availability = availability
    }
}

/// A sink or a (non-monitor) source.
public struct SoundDevice: Equatable, Sendable {
    public var name: String
    /// The node's own description: "GA106 … Digital Stereo (HDMI)".
    public var description: String
    /// The card's: "GA106 High Definition Audio Controller". Empty when the
    /// server has none, as for a Bluetooth headset.
    public var card: String
    /// `device.bus`: "pci", "usb", "bluetooth".
    public var bus: String
    public var volume: Float
    public var muted: Bool
    public var channels: Int
    public var ports: [SoundPort]
    public var activePort: String

    public init(
        name: String, description: String, card: String = "", bus: String = "",
        volume: Float = 1, muted: Bool = false, channels: Int = 2,
        ports: [SoundPort] = [], activePort: String = ""
    ) {
        self.name = name
        self.description = description
        self.card = card
        self.bus = bus
        self.volume = volume
        self.muted = muted
        self.channels = channels
        self.ports = ports
        self.activePort = activePort
    }
}

/// Something playing — a sink input.
public struct SoundStream: Equatable, Sendable, Identifiable {
    public var id: UInt32
    public var sink: UInt32
    public var app: String
    public var media: String
    public var icon: String
    public var binary: String
    public var volume: Float
    public var muted: Bool
    public var channels: Int
    public var corked: Bool

    public init(
        id: UInt32, sink: UInt32 = 0, app: String, media: String = "",
        icon: String = "", binary: String = "", volume: Float = 1,
        muted: Bool = false, channels: Int = 2, corked: Bool = false
    ) {
        self.id = id
        self.sink = sink
        self.app = app
        self.media = media
        self.icon = icon
        self.binary = binary
        self.volume = volume
        self.muted = muted
        self.channels = channels
        self.corked = corked
    }

    /// The application's name, or what the stream calls itself when the
    /// application did not say — some only fill in `media.name`.
    public var title: String {
        if !app.isEmpty { return app }
        if !media.isEmpty { return media }
        return binary.isEmpty ? "Unknown" : binary
    }
}

/// One thing to click in the output (or input) list: a device, on a port.
///
/// A row per *port* rather than per device, because a laptop's speakers and
/// its headphone jack are one sink with two ports, and "switch to the
/// headphones" there is a port change. A port with nothing plugged in is left
/// out — a jack that says it is empty is not a choice.
public struct SoundRoute: Equatable, Sendable, Identifiable {
    public var device: String
    /// The port to select along with the device; nil when that is already
    /// the one in use, or there is only the device.
    public var port: String?
    public var title: String
    public var subtitle: String
    public var isCurrent: Bool

    public var id: String { device + "#" + (port ?? "") }

    public init(device: String, port: String?, title: String, subtitle: String, isCurrent: Bool) {
        self.device = device
        self.port = port
        self.title = title
        self.subtitle = subtitle
        self.isCurrent = isCurrent
    }
}

public enum SoundRoutes {
    /// The rows for `devices`, with `current` the default's name.
    public static func routes(_ devices: [SoundDevice], current: String) -> [SoundRoute] {
        var rows: [SoundRoute] = []
        for device in unique(devices) {
            let isDefault = device.name == current
            let usable = device.ports.filter { $0.availability != .no }
            // A device whose every jack is empty is not there — an HDMI
            // output with no screen that takes sound — unless it is what
            // is playing now, which has to stay visible to be switched away
            // from.
            if !device.ports.isEmpty, usable.isEmpty, !isDefault { continue }
            let named = describesItself(device)
            if usable.count <= 1 {
                let port = usable.first ?? device.ports.first { $0.name == device.activePort }
                // The one jack that works is not always the one selected:
                // unplugging headphones can leave the sink on their port.
                let switchTo = usable.first.flatMap { $0.name == device.activePort ? nil : $0.name }
                rows.append(SoundRoute(
                    device: device.name, port: switchTo,
                    title: named || port == nil ? device.description : port!.description,
                    subtitle: named || port == nil ? "" : cardName(device),
                    isCurrent: isDefault
                ))
                continue
            }
            for port in usable {
                rows.append(SoundRoute(
                    device: device.name, port: port.name,
                    title: port.description, subtitle: cardName(device),
                    isCurrent: isDefault && port.name == device.activePort
                ))
            }
        }
        return rows
    }

    /// The default device, out of `devices`.
    public static func current(_ devices: [SoundDevice], name: String) -> SoundDevice? {
        devices.first { $0.name == name }
    }

    /// One entry per name. Pulse names are unique, but PipeWire's Pulse
    /// layer has been seen listing one HDMI sink thirty-five times over —
    /// a node left behind on each monitor hotplug, every copy with the same
    /// name — and a list of those is not a list anyone can pick from.
    static func unique(_ devices: [SoundDevice]) -> [SoundDevice] {
        var seen = Set<String>()
        return devices.filter { seen.insert($0.name).inserted }
    }

    /// Headphones and USB headsets are named after themselves — "soundcore
    /// Space One Pro" — and their port says only "Headphones". A sound card's
    /// ports are the useful part ("Speakers", "HDMI / DisplayPort") and its
    /// name is the subtitle.
    static func describesItself(_ device: SoundDevice) -> Bool {
        device.bus == "bluetooth" || device.bus == "usb" || device.ports.isEmpty
    }

    static func cardName(_ device: SoundDevice) -> String {
        device.card.isEmpty ? device.description : device.card
    }
}
