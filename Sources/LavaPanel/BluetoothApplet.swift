import Foundation
import LavaBluetooth
import LavaBluetoothCore
import LavaUI
import Observation

/// The Bluetooth window: the radio, the devices this machine knows, and a
/// way to add one. A popup of this process, sized from rows of stated
/// heights, as the network window is.
struct BluetoothWindow: View {
    var bluetooth: BluetoothSession
    /// The pane beside it, which searches while it is open and lists what
    /// it finds.
    var isSearch = false

    var body: some View {
        let blocks = isSearch ? BluetoothBlock.searchBlocks(bluetooth) : BluetoothBlock.blocks(bluetooth)
        return ScrollingCard(padding: BluetoothBlock.padding) {
            ForEach(blocks) { block in
                row(block).frame(height: .pt(block.height))
            }
        }
        .agentId(isSearch ? "bluetooth.search" : "bluetooth.window")
    }

    @ViewBuilder
    private func row(_ block: BluetoothBlock) -> some View {
        let palette = PopupPalette.current
        let fonts = popupFonts!
        switch block {
        case .powerHeader:
            powerHeader(palette: palette)
        case .searchHeader:
            HStack(padding: 0, alignment: .center, spacing: 8) {
                Text("Add a device", color: palette.bar.text, font: fonts.title15)
                    .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0))
                Spacer()
                if let adapter = bluetooth.state.adapter, adapter.powered, adapter.discovering {
                    Spinner(color: palette.bar.textSoft)
                    Text("Searching…", color: palette.bar.textSoft, font: fonts.caption12)
                        .padding(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 4))
                }
            }
        case .header(let title):
            HStack(padding: 0, alignment: .end) {
                Kicker(text: title)
            }
        case .divider:
            CardDivider()
                .padding(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
        case .note(let text, _):
            HStack(padding: 0, alignment: .center) {
                Text(text, color: palette.bar.textSoft, font: fonts.body14, lineLimit: 2)
                    .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .flexShrink(1)
            }
        case .error(let text):
            HStack(padding: 0, alignment: .center) {
                Text(text, color: palette.bar.accentInk, font: fonts.small13, lineLimit: 2)
                    .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .flexShrink(1)
            }
            .agentId("bluetooth.error")
        case .known(let device):
            KnownDeviceRow(bluetooth: bluetooth, device: device)
        case .found(let device):
            FoundDeviceRow(bluetooth: bluetooth, device: device)
        case .add:
            addRow(palette: palette)
        }
    }

    /// The radio: its disc, how many devices are connected, its switch.
    private func powerHeader(palette: PopupPalette) -> some View {
        let fonts = popupFonts!
        let adapter = bluetooth.state.adapter
        let on = adapter?.powered == true && adapter?.isBlocked == false
        let connected = bluetooth.known.filter(\.connected).count
        let sub: String = {
            if adapter?.isChanging == true {
                return adapter?.powered == true ? "Turning off…" : "Turning on…"
            }
            if adapter?.isBlocked == true { return "Off at the radio switch" }
            guard on else { return "Off" }
            return connected == 0 ? "On" : "\(connected) connected"
        }()
        return HStack(padding: 0, alignment: .center, spacing: 10) {
            IconDisc(icon: [.path(PanelIcons.bluetooth)], size: 30, glyph: 15,
                     fill: on ? palette.bar.accent : palette.neutral300,
                     color: on ? palette.bar.onAccent : palette.bar.textSoft, strokeWidth: 2.5)
            VStack(flexGrow: 1, padding: 0, spacing: 1) {
                Text("Bluetooth", color: palette.bar.text, font: fonts.title15)
                Text(sub, color: palette.bar.textSoft, font: fonts.caption12)
            }
            Toggle(isOn: bluetooth.poweredBinding, style: PopupStyles.toggle(palette),
                   isEnabled: adapter?.isBlocked == false)
                .agentId("bluetooth.power")
        }
        .padding(EdgeInsets(top: 2, leading: 8, bottom: 0, trailing: 4))
    }

    /// Opens the pane that searches. Searching is the radio shouting for
    /// as long as it lasts, so it runs while the pane is open and no longer.
    private func addRow(palette: PopupPalette) -> some View {
        let fonts = popupFonts!
        let open = session.bluetoothSearchWindow.map { LavaApp.isWindowOpen($0) } ?? false
        return HStack(
            padding: 0, alignment: .center, spacing: 10,
            onClick: { session.toggleBluetoothSearch() }
        ) {
            IconDisc(icon: [.path(PanelIcons.plus)], size: 22, glyph: 12,
                     fill: palette.bar.accentSoft, color: palette.bar.accentInk, strokeWidth: 3)
            Text("Add a device…", color: palette.bar.text, font: fonts.body14Semi, lineLimit: 1)
                .flexShrink(1)
            Spacer()
            Icon(open ? PanelIcons.chevronLeft : PanelIcons.chevronRight, size: 14,
                 color: palette.neutral700, strokeWidth: 2.75)
        }
        .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
        .background(open ? palette.rowHover : .clear)
        .hoverBackground(palette.rowHover)
        .cornerRadius(14)
        .cursor(.pointer)
        .tooltip("Search for devices in pairing mode, beside this window")
        .agentId("bluetooth.add")
    }
}

extension BtDevice {
    /// The design's glyph for what the device is.
    var iconPath: String {
        switch kind {
        case .headphones: return PanelIcons.headphones
        case .speaker: return PanelIcons.speaker
        case .mouse: return PanelIcons.mouse
        case .keyboard: return PanelIcons.keyboard
        case .gamepad: return PanelIcons.gamepad
        case .phone, .tablet: return PanelIcons.phone
        case .computer, .other: return PanelIcons.device
        }
    }
}

/// A device this machine knows: its disc, its name, what it is doing and
/// its battery. Click to connect or disconnect; the cross forgets it.
struct KnownDeviceRow: View {
    var bluetooth: BluetoothSession
    var device: BtDevice

    var body: some View {
        let palette = PopupPalette.current
        let fonts = popupFonts!
        let device = device
        let bluetooth = bluetooth
        let busy = device.busy != .idle
        let status = BluetoothRows.status(device)
        let connected = device.connected
        return HStack(
            padding: 0, alignment: .center, spacing: 10,
            onClick: busy ? nil : { bluetooth.toggle(device) }
        ) {
            IconDisc(icon: [.path(device.iconPath)], size: 32, glyph: 16,
                     fill: connected ? palette.bar.accentSoft : palette.neutral200,
                     color: connected ? palette.bar.accentInk : palette.bar.textSoft)
            VStack(flexGrow: 1, padding: 0, spacing: 1) {
                Text(device.name, color: palette.bar.text, font: fonts.body14Semi, lineLimit: 1)
                HStack(padding: 0, alignment: .center, spacing: 6) {
                    Text(status.isEmpty ? (connected ? "Connected" : "Paired") : status,
                         color: palette.bar.textSoft, font: fonts.caption12, lineLimit: 1)
                    if let battery = device.battery {
                        BatteryLevel(percent: battery)
                    }
                }
            }
            .clipped()
            // A click of its own inside the row's, as the network window's
            // Disconnect is: the innermost handler takes it.
            CardIconButton(icon: [.path(PanelIcons.close)], size: 28, glyph: 12,
                           color: palette.bar.textSoft, hover: palette.bar.accentSoft,
                           agentId: "bluetooth.forget." + device.address) {
                bluetooth.forget(device)
            }
            .tooltip("Forget \(device.name)")
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 6))
        .background(connected ? palette.rowHover.opacity(0.9) : .clear)
        .hoverBackground(busy ? Color.clear : palette.rowHover)
        .cornerRadius(14)
        .cursor(busy ? .arrow : .pointer)
        .tooltip(connected ? "Disconnect \(device.name)" : "Connect \(device.name)")
        .padding(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
        .agentId("bluetooth.device." + device.address)
    }
}

/// A device a search has found. Click to pair, and then it is a known
/// device in the other window.
struct FoundDeviceRow: View {
    var bluetooth: BluetoothSession
    var device: BtDevice

    var body: some View {
        let palette = PopupPalette.current
        let fonts = popupFonts!
        let device = device
        let bluetooth = bluetooth
        let busy = device.busy != .idle
        let bars = BluetoothRows.bars(device.rssi)
        let textSoft = palette.bar.textSoft
        return HStack(
            padding: 0, alignment: .center, spacing: 10,
            onClick: busy ? nil : { bluetooth.pair(device) }
        ) {
            IconDisc(icon: [.path(device.iconPath)], size: 28, glyph: 14,
                     fill: palette.neutral200, color: palette.bar.textSoft)
            Text(device.name, color: palette.bar.text, font: fonts.body14, lineLimit: 1)
                .flexShrink(1)
            Spacer()
            if busy {
                Text(BluetoothRows.status(device), color: palette.bar.textSoft,
                     font: fonts.caption12, lineLimit: 1)
                    .flexShrink(0)
            } else {
                Canvas(label: "signal", width: .pt(14), height: .pt(12)) { list, frame in
                    BluetoothGlyph.paintSignal(bars, list: list, frame: frame, color: textSoft)
                }
                .flexShrink(0)
            }
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 10))
        .hoverBackground(busy ? Color.clear : palette.rowHover)
        .cornerRadius(14)
        .cursor(busy ? .arrow : .pointer)
        .tooltip("Pair with \(device.name)")
        .agentId("bluetooth.found." + device.address)
    }
}

/// "80%" beside a small battery, the fill in the sage; the accent's ink
/// when it is low enough to matter.
struct BatteryLevel: View {
    var percent: Int

    var body: some View {
        let palette = PopupPalette.current
        let percent = percent
        let low = percent <= 15
        let outline = palette.bar.textSoft
        let fill = low ? palette.bar.accent : palette.sage600
        return HStack(padding: 0, alignment: .center, spacing: 4) {
            Canvas(label: "battery", width: .pt(16), height: .pt(10)) { list, frame in
                // The design's: a rounded body, a fill to the level, a nub.
                let s = frame.w / 26
                list.strokedRect(x: frame.x + 1 * s, y: frame.y + 1 * s, w: 21 * s, h: 12 * s,
                                 color: outline, radius: 3 * s, width: 1.8 * s)
                list.roundedRect(x: frame.x + 3.5 * s, y: frame.y + 3.5 * s,
                                 w: max(1, 16 * s * Float(percent) / 100), h: 7 * s,
                                 color: fill, radius: 1.5 * s)
                list.roundedRect(x: frame.x + 23 * s, y: frame.y + 5 * s, w: 2.2 * s, h: 4 * s,
                                 color: outline, radius: 1 * s)
            }
            Text("\(percent)%", color: low ? palette.bar.accentInk : palette.bar.textSoft,
                 font: popupFonts.caption12Tabular, lineLimit: 1)
        }
    }
}

/// The Bluetooth window's rows, each a stated height, so the panel can open
/// the window at the size of its contents; past `maxHeight` it scrolls.
enum BluetoothBlock: Identifiable {
    case powerHeader
    case searchHeader
    case header(String)
    /// Named after the section it opens: `ForEach` keys must be unique.
    case divider(String)
    case note(String, id: String)
    case error(String)
    case known(BtDevice)
    case found(BtDevice)
    case add

    static let padding: Float = 12
    static let width: Float = 340
    static let searchWidth: Float = 300
    static let maxHeight: Float = 520

    var id: String {
        switch self {
        case .powerHeader: return "power"
        case .searchHeader: return "search-header"
        case .header(let title): return "header." + title
        case .divider(let name): return "divider." + name
        case .note(_, let id): return "note." + id
        case .error: return "error"
        case .known(let device): return "known." + device.path
        case .found(let device): return "found." + device.path
        case .add: return "add"
        }
    }

    var height: Float {
        switch self {
        case .powerHeader: return 34
        case .searchHeader: return 32
        case .header: return 23
        case .divider: return 21
        case .note: return 40
        case .error: return 44
        case .known: return 48
        case .found: return 38
        case .add: return 40
        }
    }

    static func blocks(_ bluetooth: BluetoothSession) -> [BluetoothBlock] {
        let state = bluetooth.state
        var out: [BluetoothBlock] = []
        if let error = bluetooth.recentError { out.append(.error(error)) }
        guard state.running, let adapter = state.adapter else {
            return out + [.note("No Bluetooth adapter", id: "absent")]
        }
        out.append(.powerHeader)
        out.append(.divider("power"))
        if adapter.isBlocked {
            return out + [.note("Off at the radio switch", id: "blocked")]
        }
        if !adapter.powered {
            return out + [.note("Bluetooth is off", id: "off")]
        }
        let known = bluetooth.known
        if known.isEmpty {
            out.append(.note("No devices yet", id: "none"))
        } else {
            out.append(.header("Devices"))
            out += known.map { .known($0) }
        }
        out.append(.divider("add"))
        out.append(.add)
        return out
    }

    static func searchBlocks(_ bluetooth: BluetoothSession) -> [BluetoothBlock] {
        let found = bluetooth.discovered
        guard bluetooth.state.adapter?.powered == true else {
            return [.searchHeader, .note("Bluetooth is off", id: "off")]
        }
        guard !found.isEmpty else {
            return [.searchHeader, .note("Looking… Put the device in pairing mode.", id: "empty")]
        }
        return [.searchHeader] + found.map { .found($0) }
    }

    /// The window height for `blocks`, padding included.
    static func height(of blocks: [BluetoothBlock]) -> Float {
        min(blocks.reduce(padding * 2) { $0 + $1.height }, maxHeight)
    }

    /// The search pane opens before it has found anything, and grows as a
    /// popup cannot: room for a handful of rows from the start.
    static let searchHeight: Float = padding * 2 + 32 + 34 * 6
}

/// What the agent asks: compare a code, type one, or allow a device. An
/// ordinary window, not a popup — it may need the keyboard, and the
/// compositor focuses a window that opens.
struct BluetoothPairWindow: View {
    var bluetooth: BluetoothSession
    var id: UInt64
    @Bindable var draft: PairDraft
    var codeFont: UIFont?

    static let width: Float = 400

    static func height(_ prompt: BluetoothSession.PairingPrompt) -> Float {
        let code: Float = prompt.text.code.isEmpty ? 0 : 52
        let entered: Float = prompt.isShown && !prompt.wantsInput ? 40 : 0
        let field: Float = prompt.wantsInput ? 44 : 0
        let gaps = Float(2 + (code > 0 ? 1 : 0) + (entered > 0 ? 1 : 0)
                         + (field > 0 ? 1 : 0)) * 10
        return 44 + 4 + 24 + 46 + code + entered + field + 48 + gaps
    }

    var body: some View {
        let theme = Theme.current
        // Read through the session: a passkey being typed on a keyboard
        // updates the same prompt, digit by digit.
        let prompt = bluetooth.prompt(id)
        let text = prompt?.text ?? PairingText(title: "", message: "", code: "")
        let id = id
        VStack(flexGrow: 1, padding: 0, spacing: 0) {
            HStack(padding: 0, alignment: .center, spacing: 12) {
                WindowControls([.close])
                Text(text.title, color: theme.textPrimary, lineLimit: 1)
                    .agentId("pair.title")
                Spacer()
            }
            .padding(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .frame(height: .pt(44))
            .windowDrag(doubleClickMaximizes: false)
            VStack(flexGrow: 1, padding: 0, spacing: 10) {
                Text(text.message, color: theme.textSecondary, lineLimit: 2)
                    .agentId("pair.message")
                if !text.code.isEmpty {
                    HStack(padding: 0, alignment: .center) {
                        Spacer()
                        Text(spaced(text.code), color: theme.textPrimary, font: codeFont, lineLimit: 1)
                            .agentId("pair.code")
                        Spacer()
                    }
                    .frame(height: .pt(42))
                }
                // A keyboard shows nothing of what is typed on it; BlueZ does
                // say how far along it is.
                if let entered = entered(prompt) {
                    HStack(padding: 0, alignment: .center) {
                        Spacer()
                        Text(entered == 0 ? "Nothing typed yet" : "\(entered) of \(text.code.count) typed",
                             color: theme.textDim, lineLimit: 1)
                            .agentId("pair.entered")
                        Spacer()
                    }
                }
                if prompt?.wantsInput == true {
                    TextField(
                        text: $draft.text,
                        autoFocus: true,
                        onSubmit: { session.answerPairing(id, accept: true) }
                    )
                    .agentId("pair.field")
                }
                Spacer()
                HStack(padding: 0, alignment: .center, spacing: 10) {
                    Spacer()
                    Button(prompt?.isShown == true ? "Stop" : declineLabel(prompt)) {
                        session.answerPairing(id, accept: false)
                    }
                    .agentId("pair.decline")
                    if prompt?.isShown == false {
                        Button(acceptLabel(prompt)) { session.answerPairing(id, accept: true) }
                            .agentId("pair.accept")
                    }
                }
            }
            .padding(EdgeInsets(top: 4, leading: 24, bottom: 24, trailing: 24))
        }
        .background(theme.background)
        .agentId("pair.window")
    }

    private func entered(_ prompt: BluetoothSession.PairingPrompt?) -> Int? {
        if case .showPasskey(_, let entered) = prompt?.ask { return entered }
        return nil
    }

    /// "123 456": two halves are what people read off and type.
    private func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }

    private func acceptLabel(_ prompt: BluetoothSession.PairingPrompt?) -> String {
        switch prompt?.ask {
        case .authorizeService: return "Allow"
        default: return "Pair"
        }
    }

    private func declineLabel(_ prompt: BluetoothSession.PairingPrompt?) -> String {
        switch prompt?.ask {
        case .authorizeService, .authorize: return "Deny"
        default: return "Cancel"
        }
    }
}

/// What has been typed into one prompt so far.
@Observable
final class PairDraft {
    var text = ""

    /// A PIN does not outlive the prompt in this object.
    func clear() { text = "" }
}

/// The rune, the device kinds, a battery, signal bars.
enum BluetoothGlyph {
    static func paintStatus(
        _ status: BluetoothStatus, list: DrawList, frame: CanvasFrame, color: Color, accent: Color
    ) {
        let dim = color.opacity(0.35)
        switch status {
        case .absent, .off:
            paintRune(list: list, frame: frame, color: dim)
        case .blocked:
            paintRune(list: list, frame: frame, color: dim)
            list.line(
                x1: frame.x + frame.w * 0.15, y1: frame.y + frame.h * 0.85,
                x2: frame.x + frame.w * 0.85, y2: frame.y + frame.h * 0.15,
                color: dim, width: 1.6
            )
        case .on:
            paintRune(list: list, frame: frame, color: color)
        case .connected:
            paintRune(list: list, frame: frame, color: color)
            // The dots every desktop puts either side for "connected".
            let cy = frame.y + frame.h * 0.5
            let r = max(1.1, min(frame.w, frame.h) * 0.07)
            list.circle(cx: frame.x + frame.w * 0.12, cy: cy, radius: r, color: accent)
            list.circle(cx: frame.x + frame.w * 0.88, cy: cy, radius: r, color: accent)
        }
    }

    /// The runic B: a spine, and two arrowheads crossing it.
    static func paintRune(list: DrawList, frame: CanvasFrame, color: Color) {
        let h = min(frame.h * 0.82, frame.w * 1.6)
        let w = h * 0.26
        let cx = frame.x + frame.w * 0.5
        let top = frame.y + (frame.h - h) * 0.5
        let bottom = top + h
        let q1 = top + h * 0.27
        let q3 = top + h * 0.73
        let width = max(1.5, h * 0.095)
        let points: [(Float, Float)] = [
            (cx - w, q1), (cx + w, q3), (cx, bottom), (cx, top), (cx + w, q1), (cx - w, q3),
        ]
        for i in 0..<(points.count - 1) {
            list.line(x1: points[i].0, y1: points[i].1, x2: points[i + 1].0, y2: points[i + 1].1,
                      color: color, width: width)
        }
    }

    static func paintDevice(_ kind: BtKind, list: DrawList, frame: CanvasFrame, color: Color) {
        let s = min(frame.w, frame.h)
        let cx = frame.x + frame.w * 0.5
        let cy = frame.y + frame.h * 0.5
        let stroke: Float = 1.4
        switch kind {
        case .headphones:
            // A band over the top, two cups at its ends.
            let r = s * 0.4
            let steps = 10
            var last: (Float, Float)?
            for i in 0...steps {
                let a = Float.pi * (1 + Float(i) / Float(steps))
                let p = (cx + cos(a) * r, cy + s * 0.08 + sin(a) * r)
                if let last {
                    list.line(x1: last.0, y1: last.1, x2: p.0, y2: p.1, color: color, width: stroke)
                }
                last = p
            }
            let cupW = s * 0.22
            let cupH = s * 0.34
            let cupY = cy + s * 0.04
            list.roundedRect(x: cx - r - cupW * 0.5, y: cupY, w: cupW, h: cupH, color: color, radius: 1.5)
            list.roundedRect(x: cx + r - cupW * 0.5, y: cupY, w: cupW, h: cupH, color: color, radius: 1.5)
        case .speaker:
            let w = s * 0.62
            let h = s * 0.86
            list.strokedRect(x: cx - w * 0.5, y: cy - h * 0.5, w: w, h: h, color: color, radius: 2,
                             width: stroke)
            list.circle(cx: cx, cy: cy + h * 0.12, radius: s * 0.16, color: color)
            list.circle(cx: cx, cy: cy - h * 0.27, radius: s * 0.06, color: color)
        case .mouse:
            let w = s * 0.56
            let h = s * 0.86
            list.strokedRect(x: cx - w * 0.5, y: cy - h * 0.5, w: w, h: h, color: color,
                             radius: w * 0.5, width: stroke)
            list.line(x1: cx, y1: cy - h * 0.5, x2: cx, y2: cy - h * 0.12, color: color, width: stroke)
        case .keyboard:
            let w = s * 1.0
            let h = s * 0.6
            list.strokedRect(x: cx - w * 0.5, y: cy - h * 0.5, w: w, h: h, color: color, radius: 2,
                             width: stroke)
            for row in 0..<2 {
                for col in 0..<4 {
                    list.rect(
                        x: cx - w * 0.32 + Float(col) * w * 0.19, y: cy - h * 0.22 + Float(row) * h * 0.26,
                        w: 1.6, h: 1.6, color: color
                    )
                }
            }
            list.rect(x: cx - w * 0.22, y: cy + h * 0.2, w: w * 0.44, h: 1.4, color: color)
        case .gamepad:
            let w = s * 1.0
            let h = s * 0.56
            list.strokedRect(x: cx - w * 0.5, y: cy - h * 0.5, w: w, h: h, color: color,
                             radius: h * 0.45, width: stroke)
            list.rect(x: cx - w * 0.32, y: cy - 0.7, w: w * 0.2, h: 1.4, color: color)
            list.rect(x: cx - w * 0.22 - 0.7, y: cy - w * 0.1, w: 1.4, h: w * 0.2, color: color)
            list.circle(cx: cx + w * 0.22, cy: cy, radius: 1.3, color: color)
        case .phone, .tablet:
            let w = kind == .phone ? s * 0.5 : s * 0.72
            let h = s * 0.92
            list.strokedRect(x: cx - w * 0.5, y: cy - h * 0.5, w: w, h: h, color: color, radius: 2,
                             width: stroke)
            list.rect(x: cx - w * 0.16, y: cy + h * 0.32, w: w * 0.32, h: 1.4, color: color)
        case .computer:
            let w = s * 0.96
            let h = s * 0.62
            list.strokedRect(x: cx - w * 0.5, y: cy - h * 0.62, w: w, h: h, color: color, radius: 1.5,
                             width: stroke)
            list.rect(x: cx - w * 0.6, y: cy + h * 0.5, w: w * 1.2, h: 1.6, color: color)
        case .other:
            paintRune(list: list, frame: frame, color: color)
        }
    }

    /// An outline with a nub, filled to `percent`.
    static func paintBattery(
        _ percent: Int, list: DrawList, frame: CanvasFrame, color: Color, fill: Color
    ) {
        let h = min(frame.h, frame.w * 0.55)
        let w = h * 1.7
        let x = frame.x + (frame.w - w - 2) * 0.5
        let y = frame.y + (frame.h - h) * 0.5
        list.strokedRect(x: x, y: y, w: w, h: h, color: color, radius: 1.5, width: 1.2)
        list.rect(x: x + w, y: y + h * 0.3, w: 1.6, h: h * 0.4, color: color)
        let inner = (w - 3.6) * Float(max(0, min(100, percent))) / 100
        if inner > 0 {
            list.rect(x: x + 1.8, y: y + 1.8, w: inner, h: h - 3.6, color: fill)
        }
    }

    /// Four rising bars, `bars` of them lit.
    static func paintSignal(_ bars: Int, list: DrawList, frame: CanvasFrame, color: Color) {
        let gap: Float = 1.5
        let w = (frame.w - gap * 3) / 4
        for i in 0..<4 {
            let h = frame.h * (0.3 + 0.7 * Float(i + 1) / 4)
            list.rect(
                x: frame.x + Float(i) * (w + gap), y: frame.y + frame.h - h, w: w, h: h,
                color: i < bars ? color : color.opacity(0.3)
            )
        }
    }

    static func paintCross(list: DrawList, frame: CanvasFrame, color: Color) {
        let s = min(frame.w, frame.h) * 0.22
        let cx = frame.x + frame.w * 0.5
        let cy = frame.y + frame.h * 0.5
        list.line(x1: cx - s, y1: cy - s, x2: cx + s, y2: cy + s, color: color, width: 1.4)
        list.line(x1: cx - s, y1: cy + s, x2: cx + s, y2: cy - s, color: color, width: 1.4)
    }

    static func paintChevronLeft(list: DrawList, frame: CanvasFrame, color: Color) {
        let h = min(frame.h, frame.w * 2) * 0.6
        let w = h * 0.5
        let cx = frame.x + frame.w * 0.5
        let cy = frame.y + frame.h * 0.5
        list.line(x1: cx + w * 0.5, y1: cy - h * 0.5, x2: cx - w * 0.5, y2: cy, color: color, width: 1.6)
        list.line(x1: cx - w * 0.5, y1: cy, x2: cx + w * 0.5, y2: cy + h * 0.5, color: color, width: 1.6)
    }
}
