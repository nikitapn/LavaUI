import Foundation
import LavaShell
import LavaUI
import Observation

/// The battery, as the panel shows it: read from sysfs every few seconds on
/// the clock's thread, applied here on the main one. Unchecked because only
/// the read crosses threads; every write lands on the main queue.
@Observable
final class BatteryMonitor: @unchecked Sendable {
    /// Nil on a machine with no battery, which is the applet not being there.
    private(set) var status: BatteryStatus?
    /// The draw, averaged over the last half minute: one reading of
    /// `power_now` swings with every burst of work, and a "time left" that
    /// jumped between two and five hours from one poll to the next would be
    /// read as no estimate at all.
    private(set) var watts: Double?

    @ObservationIgnored private var samples: [Double] = []
    /// Where to read from. `LAVA_POWER_SUPPLY` points it at a directory of
    /// one's own — the only way to show a discharging battery on a machine
    /// sitting on its charger, or any battery on one with none.
    @ObservationIgnored let root =
        ProcessInfo.processInfo.environment["LAVA_POWER_SUPPLY"] ?? PowerSupply.sysfs

    /// Seconds between reads: often while the card is open, so it reads
    /// live, and rarely otherwise — a battery moves a percent in minutes.
    var interval: Int { session.batteryWindow != nil ? 2 : 5 }

    /// On the clock's thread: sysfs reads are file reads.
    func poll() {
        let next = PowerSupply.read(root: root)
        MainQueue.async { self.apply(next) }
    }

    private func apply(_ next: BatteryStatus?) {
        // A change of direction starts the average over: the draw while
        // charging says nothing about the draw on battery.
        if next?.state != status?.state { samples.removeAll() }
        if let w = next?.watts {
            samples.append(w)
            if samples.count > 15 { samples.removeFirst(samples.count - 15) }
        }
        let average = samples.isEmpty ? nil : samples.reduce(0, +) / Double(samples.count)
        // Compared before assigning, like the clock: an observed write that
        // changes nothing still rebuilds the bar.
        if next != status { status = next }
        if average != watts { watts = average }
    }

    /// "3 h 20 min left", "full in 1 h 10 min", or nil.
    var remaining: String? {
        guard let status, let seconds = status.secondsRemaining(atWatts: watts) else {
            return nil
        }
        let time = PowerSupply.duration(seconds)
        return status.state == .charging ? "full in \(time)" : "\(time) left"
    }

    /// The line under "Battery", and the tooltip after the percentage.
    var summary: String {
        guard let status else { return "" }
        let rest = remaining
        switch status.state {
        case .charging: return rest.map { "Charging · \($0)" } ?? "Charging"
        case .discharging: return rest.map { "On battery · \($0)" } ?? "On battery"
        case .full: return "Fully charged"
        case .notCharging: return "Plugged in · not charging"
        case .unknown: return status.pluggedIn ? "Plugged in" : "On battery"
        }
    }

    /// Low enough that the glyph should say so.
    var isLow: Bool {
        guard let status else { return false }
        return status.state == .discharging && status.percent <= 15
    }

    /// The bar's glyph: the cell's outline, then its level — or a bolt while
    /// it charges. The level is drawn, not picked from a set of five icons,
    /// so 37% looks like 37%.
    static func glyph(_ status: BatteryStatus) -> [IconShape] {
        var shapes: [IconShape] = [
            .rect(x: 2, y: 7, width: 16, height: 10, rx: 2),
            .path("M22 11v2"),
        ]
        if status.state == .charging {
            shapes.append(.path("m11 9-2.5 3h3L9 15"))
        } else {
            let w = max(1, Float(status.percent) / 100 * 10)
            shapes.append(.fill("M5 10h\(w)v4H5Z"))
        }
        return shapes
    }
}

let battery = BatteryMonitor()

/// The battery card: what it is doing and for how long, how full, and what
/// is known about the cell itself.
struct BatteryWindow: View {
    static let width: Float = 320
    static let padding: Float = 14
    static let detailHeight: Float = 26

    /// The header, the level bar and the rule, then a row per detail.
    static func height(details: Int) -> Float {
        padding * 2 + 36 + 14 + 8 + 14 + 1 + 8 + Float(details) * detailHeight
    }

    static func details(_ monitor: BatteryMonitor) -> [(String, String)] {
        guard let status = monitor.status else { return [] }
        var rows: [(String, String)] = []
        if let watts = monitor.watts,
           status.state == .charging || status.state == .discharging {
            rows.append((status.state == .charging ? "Charging at" : "Power draw",
                         String(format: "%.1f W", watts)))
        }
        if status.energyFull > 0 {
            rows.append(("Stored", String(format: "%.1f of %.1f Wh",
                                          status.energyNow, status.energyFull)))
        }
        if let health = status.health {
            rows.append(("Health", "\(Int((health * 100).rounded()))% of new"))
        }
        if let cycles = status.cycles { rows.append(("Charge cycles", "\(cycles)")) }
        if !status.model.isEmpty { rows.append(("Battery", status.model)) }
        return rows
    }

    var body: some View {
        let palette = PopupPalette.current
        let fonts = popupFonts!
        let status = battery.status
        let percent = status?.percent ?? 0
        let charging = status?.state == .charging || status?.state == .full
        let low = battery.isLow
        let details = Self.details(battery)
        let level = Float(percent) / 100
        let fill = low ? palette.accent700 : charging ? palette.sage600 : palette.bar.accent
        let track = palette.track
        // The power draw comes and goes with the charger: the card follows.
        PopupFit.follow(LavaApp.currentWindow, height: Self.height(details: details.count))

        return PopupCard(padding: Self.padding) {
            HStack(padding: 0, alignment: .center, spacing: 10) {
                IconDisc(icon: status.map(BatteryMonitor.glyph) ?? [], size: 30, glyph: 16,
                         fill: charging ? palette.sage200 : palette.bar.accentSoft,
                         color: charging ? palette.sage800 : palette.bar.accentInk,
                         strokeWidth: 2.25)
                VStack(flexGrow: 1, padding: 0, spacing: 1) {
                    Text("Battery", color: palette.bar.text, font: fonts.title15)
                    Text(battery.summary, color: palette.bar.textSoft, font: fonts.caption12,
                         lineLimit: 1)
                }
                .clipped()
                Text("\(percent)%", color: low ? palette.accent700 : palette.bar.text,
                     font: fonts.heading22)
            }
            .frame(height: .pt(36))
            .padding(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))

            // In a stack: padding on the canvas itself lands inside its node,
            // and the bar drew at the top of the padded box.
            VStack(padding: 0, spacing: 0) {
                Canvas(label: "battery.level", width: .pct(100), height: .pt(8)) { list, frame in
                    list.roundedRect(x: frame.x, y: frame.y, w: frame.w, h: 8, color: track,
                                     radius: 4)
                    let w = max(8, frame.w * level)
                    list.roundedRect(x: frame.x, y: frame.y, w: w, h: 8, color: fill, radius: 4)
                }
                .agentId("battery.level")
            }
            .padding(EdgeInsets(top: 14, leading: 4, bottom: 14, trailing: 4))

            CardDivider()

            VStack(padding: 0, spacing: 0) {
                ForEach(Array(details.enumerated()), id: \.offset) { _, row in
                    HStack(height: .pt(Self.detailHeight), padding: 0, alignment: .center,
                           spacing: 12) {
                        Text(row.0, color: palette.bar.textSoft, font: fonts.small13)
                        Spacer()
                        Text(row.1, color: palette.bar.text, font: fonts.small13Semi,
                             lineLimit: 1)
                    }
                    .padding(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }
            }
            .padding(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
        }
        .agentId("battery.window")
    }
}
