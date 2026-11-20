import Foundation

/// The machine's batteries, as one: what the panel's battery applet shows.
///
/// Read straight from `/sys/class/power_supply` rather than asked of UPower.
/// UPower's numbers are these files with the units converted, and a reader
/// here costs no bus connection, no thread of its own and no daemon that has
/// to be running — and it can be pointed at a directory a test made.
public struct BatteryStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case charging
        case discharging
        /// Plugged in and full, or at the limit the firmware charges to.
        case full
        /// Plugged in, not full, and still not charging: a charge threshold
        /// below 100%, or a supply too weak to do more than hold the level.
        case notCharging
        case unknown
    }

    /// 0…100, over every battery together.
    public var percent: Int
    public var state: State
    /// A mains or USB supply is connected.
    public var pluggedIn: Bool
    /// Watts into or out of the batteries; nil when the hardware reports none.
    public var watts: Double?
    /// Watt-hours stored now, and when full.
    public var energyNow: Double
    public var energyFull: Double
    /// Full now as a share of full when new, 0…1; nil when unknown.
    public var health: Double?
    public var cycles: Int?
    /// "SMP L20M4PD3", or empty.
    public var model: String

    public init(percent: Int, state: State, pluggedIn: Bool, watts: Double?,
                energyNow: Double, energyFull: Double, health: Double?,
                cycles: Int?, model: String) {
        self.percent = percent
        self.state = state
        self.pluggedIn = pluggedIn
        self.watts = watts
        self.energyNow = energyNow
        self.energyFull = energyFull
        self.health = health
        self.cycles = cycles
        self.model = model
    }

    /// Seconds until empty while discharging, until full while charging, at
    /// `watts` — the caller's average, since one reading of `power_now`
    /// jumps with every burst of work. Nil when there is no rate to divide by
    /// or the answer is not one a person could use (a day and more).
    public func secondsRemaining(atWatts watts: Double?) -> Int? {
        guard let watts, watts > 0.1 else { return nil }
        let wh: Double
        switch state {
        case .discharging: wh = energyNow
        case .charging: wh = max(0, energyFull - energyNow)
        default: return nil
        }
        let seconds = wh / watts * 3600
        guard seconds.isFinite, seconds > 0, seconds < 24 * 3600 else { return nil }
        return Int(seconds)
    }
}

public enum PowerSupply {
    public static let sysfs = "/sys/class/power_supply"

    /// Every battery under `root` folded into one status, or nil when the
    /// machine has none. Peripherals' batteries — a mouse, headphones —
    /// report `scope=Device` and are left out: they do not power this.
    public static func read(root: String = sysfs) -> BatteryStatus? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        var nowWh = 0.0, fullWh = 0.0, designWh = 0.0
        var watts = 0.0, anyWatts = false
        var capacities: [Int] = []
        var states: [BatteryStatus.State] = []
        var pluggedIn = false
        var cycles: Int?
        var model = ""
        var batteries = 0

        for name in names.sorted() {
            let dir = (root as NSString).appendingPathComponent(name)
            func text(_ file: String) -> String? {
                guard let data = fm.contents(atPath: (dir as NSString).appendingPathComponent(file)),
                      let s = String(data: data, encoding: .utf8)
                else { return nil }
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func number(_ file: String) -> Double? { text(file).flatMap(Double.init) }

            switch text("type") {
            case "Mains", "USB":
                if number("online") == 1 { pluggedIn = true }
            case "Battery":
                if text("scope") == "Device" { continue }
                if number("present") == 0 { continue }
                batteries += 1
                // µWh and µW; or µAh and µA times µV, for batteries that only
                // count charge.
                let volts = (number("voltage_now") ?? 0) / 1e6
                if let now = number("energy_now"), let full = number("energy_full") {
                    nowWh += now / 1e6
                    fullWh += full / 1e6
                    designWh += (number("energy_full_design") ?? 0) / 1e6
                } else if let now = number("charge_now"), let full = number("charge_full"),
                          volts > 0 {
                    nowWh += now / 1e6 * volts
                    fullWh += full / 1e6 * volts
                    designWh += (number("charge_full_design") ?? 0) / 1e6 * volts
                }
                if let power = number("power_now"), power > 0 {
                    watts += power / 1e6
                    anyWatts = true
                } else if let current = number("current_now"), current != 0, volts > 0 {
                    watts += abs(current) / 1e6 * volts
                    anyWatts = true
                }
                if let capacity = number("capacity") { capacities.append(Int(capacity)) }
                states.append(state(text("status") ?? ""))
                if let c = number("cycle_count"), c > 0 { cycles = (cycles ?? 0) + Int(c) }
                if model.isEmpty {
                    model = [text("manufacturer"), text("model_name")]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                }
            default:
                continue
            }
        }
        guard batteries > 0 else { return nil }

        let percent: Int
        if fullWh > 0 {
            percent = Int((nowWh / fullWh * 100).rounded())
        } else if !capacities.isEmpty {
            percent = capacities.reduce(0, +) / capacities.count
        } else {
            percent = 0
        }
        return BatteryStatus(
            percent: min(100, max(0, percent)),
            state: combined(states, pluggedIn: pluggedIn),
            pluggedIn: pluggedIn,
            watts: anyWatts ? watts : nil,
            energyNow: nowWh, energyFull: fullWh,
            health: designWh > 0 && fullWh > 0 ? min(1, fullWh / designWh) : nil,
            cycles: cycles, model: model
        )
    }

    static func state(_ status: String) -> BatteryStatus.State {
        switch status {
        case "Charging": return .charging
        case "Discharging": return .discharging
        case "Full": return .full
        case "Not charging": return .notCharging
        default: return .unknown
        }
    }

    /// Two batteries can disagree — one charging while the other is full.
    /// Moving energy wins over standing still, and discharging over charging,
    /// because that is the one the user has to act on.
    static func combined(_ states: [BatteryStatus.State], pluggedIn: Bool) -> BatteryStatus.State {
        if states.contains(.discharging) { return .discharging }
        if states.contains(.charging) { return .charging }
        if states.contains(.notCharging) { return .notCharging }
        if states.allSatisfy({ $0 == .full }) { return .full }
        // "Unknown" is what some firmware says while plugged in and idle.
        return pluggedIn ? .notCharging : .discharging
    }

    /// "3 h 20 min", "45 min", "under a minute".
    public static func duration(_ seconds: Int) -> String {
        let minutes = (seconds + 30) / 60
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
