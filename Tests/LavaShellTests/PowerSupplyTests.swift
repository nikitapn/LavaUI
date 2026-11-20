import Foundation
import Testing
@testable import LavaShell

@Suite("Power supply")
struct PowerSupplyTests {
    /// A `/sys/class/power_supply` of our own: `supplies[name][file] = text`.
    private func withSysfs(
        _ supplies: [String: [String: String]], _ body: (String) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lava-psy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, files) in supplies {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (file, text) in files {
                try (text + "\n").write(to: dir.appendingPathComponent(file),
                                        atomically: true, encoding: .utf8)
            }
        }
        try body(root.path)
    }

    /// This machine's, as read on the day it was written.
    private let bat0 = [
        "type": "Battery", "status": "Not charging", "capacity": "96",
        "energy_now": "54510000", "energy_full": "56670000",
        "energy_full_design": "71000000", "power_now": "0",
        "voltage_now": "15360000", "cycle_count": "840",
        "manufacturer": "SMP", "model_name": "L20M4PD3",
    ]

    @Test("a laptop on its charger, held below full")
    func heldBelowFull() throws {
        try withSysfs(["BAT0": bat0, "ADP1": ["type": "Mains", "online": "1"]]) { root in
            let status = try #require(PowerSupply.read(root: root))
            #expect(status.percent == 96)
            #expect(status.state == .notCharging)
            #expect(status.pluggedIn)
            #expect(status.watts == nil, "a zero power_now is no reading, not 0 W")
            #expect(abs((status.health ?? 0) - 0.798) < 0.001)
            #expect(status.cycles == 840)
            #expect(status.model == "SMP L20M4PD3")
        }
    }

    @Test("no battery is no applet; a mouse's battery is not the machine's")
    func noBattery() throws {
        try withSysfs([
            "ADP1": ["type": "Mains", "online": "1"],
            "hid-mouse-battery": ["type": "Battery", "scope": "Device", "capacity": "40",
                                  "status": "Discharging"],
        ]) { root in
            #expect(PowerSupply.read(root: root) == nil)
        }
    }

    @Test("charge counters are turned into energy with the voltage")
    func chargeOnly() throws {
        try withSysfs(["BAT1": [
            "type": "Battery", "status": "Discharging",
            "charge_now": "2000000", "charge_full": "4000000",
            "current_now": "1000000", "voltage_now": "12000000",
        ]]) { root in
            let status = try #require(PowerSupply.read(root: root))
            #expect(status.percent == 50)
            #expect(status.energyNow == 24)
            #expect(status.watts == 12)
            #expect(status.secondsRemaining(atWatts: status.watts) == 2 * 3600)
        }
    }

    @Test("two batteries are one: energy summed, and discharging wins")
    func twoBatteries() throws {
        var full = bat0
        full["status"] = "Full"
        full["energy_now"] = "56670000"
        var draining = bat0
        draining["status"] = "Discharging"
        draining["energy_now"] = "28335000"
        try withSysfs(["BAT0": full, "BAT1": draining]) { root in
            let status = try #require(PowerSupply.read(root: root))
            #expect(status.percent == 75)
            #expect(status.state == .discharging)
            #expect(!status.pluggedIn)
            #expect(status.cycles == 1680)
        }
    }

    @Test("time left: to empty, to full, and nothing when it would be nonsense")
    func timeLeft() {
        var status = BatteryStatus(
            percent: 50, state: .discharging, pluggedIn: false, watts: 10,
            energyNow: 30, energyFull: 60, health: nil, cycles: nil, model: "")
        #expect(status.secondsRemaining(atWatts: 10) == 3 * 3600)
        status.state = .charging
        #expect(status.secondsRemaining(atWatts: 20) == 90 * 60)
        #expect(status.secondsRemaining(atWatts: 0) == nil)
        #expect(status.secondsRemaining(atWatts: 0.5) == nil, "over a day")
        status.state = .full
        #expect(status.secondsRemaining(atWatts: 10) == nil)
    }

    @Test("durations read the way a person says them")
    func durations() {
        #expect(PowerSupply.duration(20) == "under a minute")
        #expect(PowerSupply.duration(45 * 60) == "45 min")
        #expect(PowerSupply.duration(3 * 3600) == "3 h")
        #expect(PowerSupply.duration(3 * 3600 + 20 * 60 + 10) == "3 h 20 min")
    }
}
