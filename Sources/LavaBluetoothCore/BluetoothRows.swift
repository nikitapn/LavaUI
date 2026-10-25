import Foundation

/// What the strip's glyph shows.
public enum BluetoothStatus: Equatable, Sendable {
    /// No adapter, or no bluetoothd: there is no applet.
    case absent
    case off
    /// Off at the radio switch.
    case blocked
    case on
    /// On, with this many devices connected.
    case connected(Int)
}

/// An agent request, as the window that answers it words it.
public struct PairingText: Equatable, Sendable {
    public var title: String
    public var message: String
    /// The code, large, when there is one to compare or type.
    public var code: String

    public init(title: String, message: String, code: String) {
        self.title = title
        self.message = message
        self.code = code
    }
}

public enum BluetoothRows {
    /// What the window lists under the power switch: the devices this
    /// machine knows — paired, or connected without pairing, as some LE
    /// devices are. Connected first, then by name.
    public static func known(_ state: BluetoothState) -> [BtDevice] {
        state.devices
            .filter { ($0.paired || $0.connected) && !$0.blocked }
            .sorted { a, b in
                if a.connected != b.connected { return a.connected }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// Settings' list: the known devices and the blocked ones, which the
    /// panel leaves out and which can only be unblocked from here.
    /// Connected first, blocked last, by name between.
    public static func settingsDevices(_ state: BluetoothState) -> [BtDevice] {
        func rank(_ d: BtDevice) -> Int { d.connected ? 0 : d.blocked ? 2 : 1 }
        return state.devices
            .filter { $0.paired || $0.connected || $0.blocked }
            .sorted { a, b in
                if rank(a) != rank(b) { return rank(a) < rank(b) }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// The line under a device's name in Settings' list.
    public static func detail(_ device: BtDevice) -> String {
        if device.blocked { return "Blocked" }
        let status = status(device)
        var parts = [status.isEmpty ? (device.paired ? "Not connected" : "Not paired") : status]
        if let battery = device.battery { parts.append("Battery \(battery)%") }
        return parts.joined(separator: " · ")
    }

    /// What kind of thing it is, in a word, for a heading.
    public static func kindName(_ kind: BtKind) -> String {
        switch kind {
        case .headphones: return "Headphones"
        case .speaker: return "Speaker"
        case .mouse: return "Mouse"
        case .keyboard: return "Keyboard"
        case .gamepad: return "Game controller"
        case .phone: return "Phone"
        case .computer: return "Computer"
        case .tablet: return "Tablet"
        case .other: return "Device"
        }
    }

    /// How long "visible" lasts, for the line under its switch.
    public static func visibility(_ adapter: BtAdapter) -> String {
        let t = adapter.discoverableTimeout
        let span: String
        if t == 0 {
            span = "It stays visible until switched off here."
        } else if t % 60 == 0 {
            span = "It hides again after \(t / 60) minute\(t == 60 ? "" : "s")."
        } else {
            span = "It hides again after \(t) seconds."
        }
        return "Lets a phone or another computer find this one and pair from its side. " + span
    }

    /// Why a name cannot be used, or nil. Bluetooth carries 248 bytes of it.
    public static func nameProblem(_ name: String) -> String? {
        name.utf8.count > 248 ? "Too long: Bluetooth carries at most 248 bytes of a name." : nil
    }

    /// What a search has found that is not already known: only what sent a
    /// name — a scan anywhere near people is mostly anonymous beacons — and
    /// the nearest first, which is usually the thing in the person's hand.
    public static func discovered(_ state: BluetoothState) -> [BtDevice] {
        state.devices
            .filter { !$0.paired && !$0.connected && $0.hasName && !$0.blocked }
            .sorted { a, b in
                switch (a.rssi, b.rssi) {
                case let (x?, y?) where x != y: return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
    }

    public static func status(_ state: BluetoothState) -> BluetoothStatus {
        guard state.running, let adapter = state.adapter else { return .absent }
        if adapter.isBlocked { return .blocked }
        if !adapter.powered { return .off }
        let connected = state.devices.filter(\.connected).count
        return connected > 0 ? .connected(connected) : .on
    }

    /// The tooltip on the strip glyph.
    public static func summary(_ state: BluetoothState) -> String {
        switch status(state) {
        case .absent: return "No Bluetooth"
        case .off: return "Bluetooth is off"
        case .blocked: return "Bluetooth is off at the radio switch"
        case .on: return "Bluetooth is on"
        case .connected(let count):
            let names = known(state).filter(\.connected).map { device in
                device.battery.map { "\(device.name) (\($0)%)" } ?? device.name
            }
            return count == 1 ? names.first ?? "1 device connected" : names.joined(separator: ", ")
        }
    }

    /// The word beside a device in the list; "" for one doing nothing.
    public static func status(_ device: BtDevice) -> String {
        switch device.busy {
        case .connecting: return "Connecting…"
        case .disconnecting: return "Disconnecting…"
        case .pairing: return "Pairing…"
        case .idle: return device.connected ? "Connected" : ""
        }
    }

    /// A strength for a found device: bars out of four, from dBm. Close is
    /// above -60, across a room about -75, through a wall -85 and worse.
    public static func bars(_ rssi: Int?) -> Int {
        guard let rssi else { return 0 }
        switch rssi {
        case (-60)...: return 4
        case (-70)..<(-60): return 3
        case (-80)..<(-70): return 2
        default: return 1
        }
    }

    // MARK: - Errors

    /// BlueZ's errors are written for the people who wrote BlueZ:
    /// "br-connection-page-timeout". This says what they mean for the
    /// person holding the headset.
    public static func explain(error: String, message: String) -> String {
        let m = message.lowercased()
        if m.contains("page-timeout") || m.contains("page timeout") || m.contains("host is down") {
            return "It did not answer. Is it switched on and nearby?"
        }
        if m.contains("profile-unavailable") || m.contains("protocol not available") {
            return "Nothing here can use it. For audio, PipeWire's Bluetooth support has to be running."
        }
        if m.contains("rfkill") {
            return "Bluetooth is off at the radio switch."
        }
        if m.contains("already-connected") || m.contains("busy") {
            return "It is busy with another connection. Try again in a moment."
        }
        switch error {
        case "org.bluez.Error.AuthenticationFailed":
            return "Pairing failed. The codes may not have matched."
        case "org.bluez.Error.AuthenticationRejected":
            return "The device turned the pairing down."
        case "org.bluez.Error.AuthenticationTimeout":
            return "Pairing took too long. Try again, with the device in pairing mode."
        case "org.bluez.Error.ConnectionAttemptFailed":
            return "Could not reach it. Is it in pairing mode?"
        case "org.bluez.Error.NotReady":
            return "Bluetooth is off."
        case "org.bluez.Error.DoesNotExist":
            return "It is no longer around."
        case "org.freedesktop.DBus.Error.NoReply", "org.freedesktop.DBus.Error.Timeout":
            return "It did not answer in time."
        default:
            return message.isEmpty ? error : message
        }
    }

    // MARK: - The agent's questions

    /// A passkey as both screens show it: six digits, zeros kept.
    public static func passkey(_ value: UInt32) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, 6 - digits.count)) + digits
    }

    /// What a service UUID is, in words, for "may it use …?". Only the ones
    /// a device on a desk asks for; the rest are shown as the number.
    public static func service(_ uuid: String) -> String {
        let short = uuid.lowercased().split(separator: "-").first.map(String.init) ?? ""
        switch short {
        case "0000110a", "0000110b", "0000110d": return "audio"
        case "00001108", "00001112", "0000111e", "0000111f": return "calls"
        case "0000110c", "0000110e", "0000110f": return "media controls"
        case "00001124", "00001812": return "input"
        case "00001105", "00001106": return "file transfer"
        case "0000112f": return "your contacts"
        case "00001132", "00001133", "00001134": return "messages"
        case "00001115", "00001116", "00001117": return "network access"
        case "0000180f": return "battery level"
        default: return uuid.isEmpty ? "a service" : uuid
        }
    }

    public enum Ask: Equatable, Sendable {
        case pin, passkey, showPin(String), showPasskey(UInt32, entered: Int)
        case confirm(UInt32), authorize, authorizeService(String)
    }

    public static func text(_ ask: Ask, device: String) -> PairingText {
        switch ask {
        case .pin:
            return PairingText(
                title: "Pair with \(device)",
                message: "Type the PIN \(device) expects. If it shows none, its manual has it; often it is 0000.",
                code: ""
            )
        case .passkey:
            return PairingText(
                title: "Pair with \(device)",
                message: "Type the six-digit code \(device) shows.",
                code: ""
            )
        case .showPin(let pin):
            return PairingText(
                title: "Pair with \(device)",
                message: "Type this PIN on \(device), then press Enter.",
                code: pin
            )
        case .showPasskey(let key, _):
            return PairingText(
                title: "Pair with \(device)",
                message: "Type this code on \(device), then press Enter.",
                code: passkey(key)
            )
        case .confirm(let key):
            return PairingText(
                title: "Pair with \(device)?",
                message: "Make sure \(device) shows the same code.",
                code: passkey(key)
            )
        case .authorize:
            return PairingText(
                title: "Pair with \(device)?",
                message: "\(device) wants to pair with this computer.",
                code: ""
            )
        case .authorizeService(let uuid):
            return PairingText(
                title: "Allow \(device)?",
                message: "\(device) wants to use \(service(uuid)). Pair it to stop being asked.",
                code: ""
            )
        }
    }
}
