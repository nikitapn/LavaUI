import Foundation
import LavaBluetooth
import LavaBluetoothCore
import LavaUI
import Observation

/// Panel Bluetooth control: the rune, dim when the radio is off and with a
/// dot either side while something is connected, and a click for the
/// Bluetooth window. Talks to BlueZ through `BluetoothSession`, which is
/// also the session's pairing agent.
struct BluetoothApplet: View {
    var bluetooth: BluetoothSession

    var body: some View {
        // Read on the body path so Observation invalidates when it changes
        // (the paint closure alone is not tracked).
        let status = bluetooth.status
        let theme = Theme.current
        HStack(
            height: .pt(36),
            padding: 0,
            alignment: .center,
            onPointer: { _, button in
                guard button == PointerButton.left else { return }
                session.toggleBluetooth()
            }) {
            Canvas(
                label: "bluetooth",
                width: .pt(20),
                height: .pt(22),
                paint: { list, frame in
                    BluetoothGlyph.paintStatus(
                        status, list: list, frame: frame,
                        color: theme.textPrimary, accent: theme.accent
                    )
                }
            )
        }
        .padding(EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2))
        .hoverBackground(PanelChrome.style.titleHover)
        .cornerRadius(6)
        .agentId("applet.bluetooth")
    }
}

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
        ScrollView(showsIndicator: true) {
            VStack(padding: BluetoothBlock.padding, spacing: 0) {
                ForEach(blocks) { block in
                    row(block).frame(height: .pt(block.height))
                }
            }
        }
        .background(PanelChrome.popupWash)
        .agentId(isSearch ? "bluetooth.search" : "bluetooth.window")
    }

    @ViewBuilder
    private func row(_ block: BluetoothBlock) -> some View {
        let theme = Theme.current
        switch block {
        case .powerHeader:
            let adapter = bluetooth.state.adapter
            HStack(padding: 0, alignment: .center, spacing: 8) {
                Text("Bluetooth", color: theme.textSecondary)
                    .padding(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
                if adapter?.isChanging == true {
                    Text(adapter?.powered == true ? "Turning off…" : "Turning on…", color: theme.textDim)
                }
                Spacer()
                Toggle(isOn: bluetooth.poweredBinding, isEnabled: adapter?.isBlocked == false)
                    .agentId("bluetooth.power")
            }
        case .searchHeader:
            HStack(padding: 0, alignment: .center, spacing: 8) {
                Text("Add a device", color: theme.textSecondary)
                    .padding(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
                Spacer()
                if let adapter = bluetooth.state.adapter, adapter.powered, adapter.discovering {
                    Text("Searching…", color: theme.textDim)
                }
            }
        case .header(let title):
            HStack(padding: 0, alignment: .end) {
                Text(title, color: theme.textSecondary)
                    .padding(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 0))
            }
        case .divider:
            HStack(padding: 0, alignment: .center) {
                VStack(height: .pt(1)) {}
                    .flexGrow(1)
                    .background(theme.border)
            }
        case .note(let text, _):
            HStack(padding: 0, alignment: .center) {
                Text(text, color: theme.textDim, lineLimit: 2)
                    .padding(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    .flexShrink(1)
            }
        case .error(let text):
            HStack(padding: 0, alignment: .center) {
                Text(text, color: theme.accent, lineLimit: 2)
                    .padding(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    .flexShrink(1)
            }
            .agentId("bluetooth.error")
        case .known(let device):
            KnownDeviceRow(bluetooth: bluetooth, device: device)
        case .found(let device):
            FoundDeviceRow(bluetooth: bluetooth, device: device)
        case .add:
            addRow()
        }
    }

    /// Opens the pane that searches. Searching is the radio shouting for
    /// as long as it lasts, so it runs while the pane is open and no longer.
    private func addRow() -> some View {
        let theme = Theme.current
        let open = session.bluetoothSearchWindow.map { LavaApp.isWindowOpen($0) } ?? false
        return HStack(
            padding: 0, alignment: .center, spacing: 8,
            onClick: { session.toggleBluetoothSearch() }
        ) {
            Text("Add a device…", color: theme.textPrimary, lineLimit: 1)
                .flexShrink(1)
            Spacer()
            Canvas(label: "chevron", width: .pt(10), height: .pt(14)) { list, frame in
                BluetoothGlyph.paintChevronLeft(
                    list: list, frame: frame, color: open ? theme.accent : theme.textDim
                )
            }
            .flexShrink(0)
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .hoverBackground(theme.hover)
        .cornerRadius(6)
        .cursor(.pointer)
        .tooltip("Search for devices in pairing mode, beside this window")
        .agentId("bluetooth.add")
    }
}

/// A device this machine knows. Click to connect or disconnect; the cross
/// forgets it.
struct KnownDeviceRow: View {
    var bluetooth: BluetoothSession
    var device: BtDevice

    var body: some View {
        let theme = Theme.current
        let device = device
        let bluetooth = bluetooth
        let busy = device.busy != .idle
        let status = BluetoothRows.status(device)
        return HStack(
            padding: 0, alignment: .center, spacing: 8,
            onClick: busy ? nil : { bluetooth.toggle(device) }
        ) {
            Canvas(label: "kind", width: .pt(18), height: .pt(16)) { list, frame in
                BluetoothGlyph.paintDevice(
                    device.kind, list: list, frame: frame,
                    color: device.connected ? theme.accent : theme.textDim
                )
            }
            .flexShrink(0)
            Text(device.name, color: theme.textPrimary, lineLimit: 1)
                .flexShrink(1)
            Spacer()
            if let battery = device.battery {
                BatteryLevel(percent: battery)
                    .flexShrink(0)
            }
            if !status.isEmpty, busy || device.battery == nil {
                Text(status, color: theme.textDim, lineLimit: 1)
                    .flexShrink(0)
            }
            // A click of its own inside the row's, as the network window's
            // Disconnect is: the innermost handler takes it.
            HStack(padding: 0, alignment: .center, onClick: { bluetooth.forget(device) }) {
                Canvas(label: "forget", width: .pt(16), height: .pt(16)) { list, frame in
                    BluetoothGlyph.paintCross(list: list, frame: frame, color: theme.textDim)
                }
            }
            .hoverBackground(theme.hover)
            .cornerRadius(4)
            .tooltip("Forget \(device.name)")
            .flexShrink(0)
            .agentId("bluetooth.forget." + device.address)
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 6))
        .hoverBackground(busy ? Color.clear : theme.hover)
        .cornerRadius(6)
        .cursor(busy ? .arrow : .pointer)
        .tooltip(device.connected ? "Disconnect \(device.name)" : "Connect \(device.name)")
        .agentId("bluetooth.device." + device.address)
    }
}

/// A device a search has found. Click to pair, and then it is a known
/// device in the other window.
struct FoundDeviceRow: View {
    var bluetooth: BluetoothSession
    var device: BtDevice

    var body: some View {
        let theme = Theme.current
        let device = device
        let bluetooth = bluetooth
        let busy = device.busy != .idle
        let bars = BluetoothRows.bars(device.rssi)
        return HStack(
            padding: 0, alignment: .center, spacing: 8,
            onClick: busy ? nil : { bluetooth.pair(device) }
        ) {
            Canvas(label: "kind", width: .pt(18), height: .pt(16)) { list, frame in
                BluetoothGlyph.paintDevice(device.kind, list: list, frame: frame, color: theme.textDim)
            }
            .flexShrink(0)
            Text(device.name, color: theme.textPrimary, lineLimit: 1)
                .flexShrink(1)
            Spacer()
            if busy {
                Text(BluetoothRows.status(device), color: theme.textDim, lineLimit: 1)
                    .flexShrink(0)
            } else {
                Canvas(label: "signal", width: .pt(14), height: .pt(12)) { list, frame in
                    BluetoothGlyph.paintSignal(
                        bars, list: list, frame: frame, color: theme.textDim
                    )
                }
                .flexShrink(0)
            }
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .hoverBackground(busy ? Color.clear : theme.hover)
        .cornerRadius(6)
        .cursor(busy ? .arrow : .pointer)
        .tooltip("Pair with \(device.name)")
        .agentId("bluetooth.found." + device.address)
    }
}

/// "80%" beside a small battery, red-ish when it is low enough to matter.
struct BatteryLevel: View {
    var percent: Int

    var body: some View {
        let theme = Theme.current
        let percent = percent
        let low = percent <= 15
        HStack(padding: 0, alignment: .center, spacing: 4) {
            Canvas(label: "battery", width: .pt(16), height: .pt(10)) { list, frame in
                BluetoothGlyph.paintBattery(
                    percent, list: list, frame: frame,
                    color: theme.textDim, fill: low ? theme.accent : theme.textSecondary
                )
            }
            Text("\(percent)%", color: low ? theme.accent : theme.textDim, lineLimit: 1)
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
        case .powerHeader, .searchHeader: return 32
        case .header: return 26
        case .divider: return 13
        case .note: return 40
        case .error: return 44
        case .known, .found, .add: return 34
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
        return 24 * 2 + 26 + 46 + code + entered + field + 48
    }

    var body: some View {
        let theme = Theme.current
        // Read through the session: a passkey being typed on a keyboard
        // updates the same prompt, digit by digit.
        let prompt = bluetooth.prompt(id)
        let text = prompt?.text ?? PairingText(title: "", message: "", code: "")
        let id = id
        VStack(flexGrow: 1, padding: 24, spacing: 10) {
            Text(text.title, color: theme.textPrimary, lineLimit: 1)
                .agentId("pair.title")
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
