import Foundation
import LavaNetwork
import LavaNetworkCore
import LavaUI
import Observation

/// The network window: Wi-Fi on or off and the networks in range, wired
/// ports, then VPNs. A popup of this process, sized from rows of stated
/// heights so it opens at the size of what is in it.
struct NetworkWindow: View {
    var network: NetworkSession
    /// The pane beside it: every network in range, instead of the window's
    /// own short list, wired ports and VPNs.
    var isList = false

    var body: some View {
        let blocks = isList ? NetworkBlock.listBlocks(network) : NetworkBlock.blocks(network)
        return PopupCard(padding: 0) {
            ScrollView(showsIndicator: true) {
                VStack(padding: NetworkBlock.padding, spacing: 0) {
                    ForEach(blocks) { block in
                        row(block).frame(height: .pt(block.height))
                    }
                }
            }
        }
        .agentId(isList ? "network.list" : "network.window")
    }

    @ViewBuilder
    private func row(_ block: NetworkBlock) -> some View {
        let palette = PopupPalette.current
        let fonts = popupFonts!
        switch block {
        case .wifiHeader:
            wifiHeader(palette: palette)
        case .header(let title):
            HStack(padding: 0, alignment: .end) {
                Kicker(text: title)
            }
        case .divider:
            CardDivider()
                .padding(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
        case .note(let text, _):
            HStack(padding: 0, alignment: .center) {
                Text(text, color: palette.bar.textSoft, font: fonts.small13, lineLimit: 1)
                    .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0))
                    .flexShrink(1)
            }
        case .error(let text):
            HStack(padding: 0, alignment: .center) {
                Text(text, color: palette.bar.accentInk, font: fonts.small13, lineLimit: 2)
                    .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                    .flexShrink(1)
            }
            .agentId("network.error")
        case .wifi(let wifi):
            WifiRow(
                network: network, wifi: wifi,
                onConnect: isList ? { session.closeNetworkList() } : nil,
                showsDisconnect: !isList
            )
        case .more(let count):
            moreRow(count, palette: palette)
        case .listHeader:
            HStack(padding: 0, alignment: .center, spacing: 8) {
                Text("Wi-Fi networks", color: palette.bar.text, font: fonts.title15)
                    .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 0))
                if network.state.scanning {
                    Spinner(color: palette.bar.textSoft)
                }
                Spacer()
            }
        case .wired(let wired):
            wiredRow(wired, palette: palette)
        case .vpn(let vpn):
            vpnRow(vpn, palette: palette)
        }
    }

    /// The radio: its disc, its name, what it is doing, its switch.
    private func wifiHeader(palette: PopupPalette) -> some View {
        let fonts = popupFonts!
        let state = network.state
        let on = state.wirelessEnabled && state.wirelessHardwareEnabled
        let connected = network.wifi.contains { $0.isConnected }
        let sub = !state.wirelessHardwareEnabled ? "Off at the hardware switch"
            : !state.wirelessEnabled ? "Off"
            : state.scanning ? "Scanning…"
            : connected ? "Connected" : "On"
        return HStack(padding: 0, alignment: .center, spacing: 10) {
            IconDisc(icon: [.path(PanelIcons.wifi)], size: 30, glyph: 15,
                     fill: on ? palette.bar.accent : palette.neutral300,
                     color: on ? palette.bar.onAccent : palette.bar.textSoft, strokeWidth: 2.5)
            VStack(flexGrow: 1, padding: 0, spacing: 1) {
                Text("Wi-Fi", color: palette.bar.text, font: fonts.title15)
                HStack(padding: 0, alignment: .center, spacing: 6) {
                    if on && state.scanning {
                        Spinner(color: palette.bar.textSoft)
                    }
                    Text(sub, color: palette.bar.textSoft, font: fonts.caption12)
                }
            }
            Toggle(isOn: network.wirelessBinding, style: PopupStyles.toggle(palette),
                   isEnabled: state.wirelessHardwareEnabled)
                .agentId("network.wifi-toggle")
        }
        .padding(EdgeInsets(top: 2, leading: 8, bottom: 0, trailing: 4))
    }

    /// Every network in range, in the pane beside this one. A scan in a
    /// city is dozens of names, and listed here they pushed the wired port
    /// and the VPNs — what a click here is usually for — off the bottom.
    private func moreRow(_ count: Int, palette: PopupPalette) -> some View {
        let fonts = popupFonts!
        let open = session.networkListWindow.map { LavaApp.isWindowOpen($0) } ?? false
        return HStack(
            padding: 0, alignment: .center, spacing: 10,
            onClick: { session.toggleNetworkList() }
        ) {
            Text("All Wi-Fi networks", color: palette.bar.text, font: fonts.body14Semi,
                 lineLimit: 1)
                .flexShrink(1)
            Spacer()
            TagLabel(text: "\(count)", tone: .neutral)
            Icon(open ? PanelIcons.chevronLeft : PanelIcons.chevronRight, size: 14,
                 color: palette.neutral700, strokeWidth: 2.75)
        }
        .padding(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 10))
        .background(open ? palette.rowHover : .clear)
        .hoverBackground(palette.rowHover)
        .cornerRadius(14)
        .cursor(.pointer)
        .tooltip("Every network in range, beside this window")
        .agentId("network.all")
    }

    private func wiredRow(_ wired: WiredRow, palette: PopupPalette) -> some View {
        let fonts = popupFonts!
        let on = wired.device.isConnected
        return HStack(padding: 0, alignment: .center, spacing: 10) {
            Icon(PanelIcons.ethernet, size: 16, color: on ? palette.sage700 : palette.neutral700,
                 strokeWidth: 2.25)
            VStack(flexGrow: 1, padding: 0, spacing: 0) {
                Text(wired.active?.id ?? wired.device.iface, color: palette.bar.text,
                     font: on ? fonts.body14Semi : fonts.body14, lineLimit: 1)
                Text(wired.status, color: on ? palette.sage800 : palette.bar.textSoft,
                     font: fonts.caption12, lineLimit: 1)
            }
            .clipped()
        }
        .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 6))
        .background(on ? palette.sage100 : .clear)
        .cornerRadius(14)
        .padding(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
        .agentId("network.wired." + wired.device.iface)
    }

    private func vpnRow(_ vpn: VPNRow, palette: PopupPalette) -> some View {
        let fonts = popupFonts!
        let on = vpn.isOn && !vpn.isConnecting
        return HStack(padding: 0, alignment: .center, spacing: 10) {
            Icon(PanelIcons.shield, size: 16, color: vpn.isOn ? palette.sage700 : palette.neutral700,
                 strokeWidth: 2.25)
            VStack(flexGrow: 1, padding: 0, spacing: 0) {
                Text(vpn.connection.id, color: palette.bar.text,
                     font: on ? fonts.body14Semi : fonts.body14, lineLimit: 1)
                if vpn.isConnecting {
                    Text("Connecting…", color: palette.bar.textSoft, font: fonts.caption12)
                } else if on {
                    Text("Connected", color: palette.sage800, font: fonts.caption12)
                }
            }
            .clipped()
            Toggle(isOn: network.vpnBinding(vpn), style: PopupStyles.toggle(palette))
                .agentId("network.vpn-toggle." + vpn.connection.id)
        }
        .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 6))
        .background(vpn.isOn ? palette.sage100 : .clear)
        .cornerRadius(14)
        .padding(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
        .agentId("network.vpn." + vpn.connection.id)
    }
}

/// One Wi-Fi network. The one in use is a card of its own — its name, that
/// it is connected and secured, and the way off it; the rest are a row each,
/// the fan cut to their strength. In the network window and in the pane of
/// every network beside it.
struct WifiRow: View {
    var network: NetworkSession
    var wifi: WifiNetwork
    /// After a click has asked to connect — the pane closes itself, so the
    /// row that then says "Connecting…" is the one in the network window.
    var onConnect: (() -> Void)?
    /// The network window's rows have it; the pane's leave it to the window,
    /// and the name the room.
    var showsDisconnect = true

    var body: some View {
        let palette = PopupPalette.current
        if wifi.isConnected, showsDisconnect {
            connectedCard(palette: palette)
        } else {
            plainRow(palette: palette)
        }
    }

    private func connectedCard(palette: PopupPalette) -> some View {
        let fonts = popupFonts!
        let wifi = wifi
        let network = network
        let secured = wifi.security.showsLock
        return HStack(padding: 0, alignment: .center, spacing: 10) {
            let fan = TrayCluster.networkIcon(
                NetworkStatus(link: .wifi(bars: NetworkRows.bars(wifi.strength))))
            IconDisc(icon: fan.lit, size: 32, glyph: 15, fill: palette.bar.accent,
                     color: palette.bar.onAccent, strokeWidth: 2.75, faint: fan.faint,
                     faintColor: palette.bar.onAccent.mixed(with: palette.bar.accent, 0.55))
            VStack(flexGrow: 1, padding: 0, spacing: 1) {
                Text(wifi.ssid, color: palette.bar.text, font: fonts.body14Bold, lineLimit: 1)
                HStack(padding: 0, alignment: .center, spacing: 5) {
                    Text("Connected", color: palette.bar.accentInk, font: fonts.caption12)
                    if secured {
                        Icon(PanelIcons.lock, size: 10, color: palette.bar.accentInk, strokeWidth: 3)
                        Text("Secured", color: palette.bar.accentInk, font: fonts.caption12)
                    }
                }
            }
            .clipped()
            if let active = wifi.active {
                PillButton(title: "Disconnect", agentId: "network.disconnect") {
                    network.disconnect(active)
                }
            }
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .background(palette.accent100)
        .cornerRadius(16)
        .padding(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
        .agentId("network.wifi." + wifi.ssid)
    }

    private func plainRow(palette: PopupPalette) -> some View {
        let fonts = popupFonts!
        let wifi = wifi
        let network = network
        let onConnect = onConnect
        let enterprise = wifi.security == .enterprise
        let busy = wifi.isConnected || wifi.isConnecting
        let ink = enterprise ? palette.neutral600 : palette.bar.text
        let status = wifi.isConnected ? "Connected" : wifi.isConnecting ? "Connecting…" : ""
        let bars = NetworkRows.bars(wifi.strength)
        return HStack(
            padding: 0, alignment: .center, spacing: 10,
            onClick: busy || enterprise ? nil : {
                network.connect(wifi)
                onConnect?()
            }
        ) {
            let fan = TrayCluster.networkIcon(NetworkStatus(link: .wifi(bars: bars)))
            let ink = wifi.isConnected ? palette.bar.accent : palette.bar.textSoft
            Icon(fan.lit, size: 17, color: ink, strokeWidth: 2.25, faint: fan.faint,
                 faintColor: ink.mixed(with: palette.bar.onAccent, 0.62))
            Text(wifi.ssid, color: ink, font: fonts.body14, lineLimit: 1)
                .flexShrink(1)
            Spacer()
            if !status.isEmpty {
                Text(status, color: palette.bar.textSoft, font: fonts.caption12, lineLimit: 1)
                    .flexShrink(0)
            }
            if wifi.security.showsLock {
                Icon(PanelIcons.lock, size: 12, color: palette.neutral700, strokeWidth: 2.75)
            }
        }
        .padding(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 10))
        .hoverBackground(busy || enterprise ? Color.clear : palette.rowHover)
        .cornerRadius(14)
        .cursor(busy || enterprise ? .arrow : .pointer)
        .tooltip(enterprise ? "Enterprise network — set it up with nm-connection-editor" : wifi.ssid)
        .agentId("network.wifi." + wifi.ssid)
    }
}

/// An arc turning, for "Scanning…": Lucide's loader, a turn a second, at
/// fifteen frames a second while it is on screen.
struct Spinner: View {
    var color: Color
    var size: Float = 11

    var body: some View {
        let color = color, size = size
        return Canvas(label: "spinner", width: .pt(size), height: .pt(size)) { list, frame in
            let turn = Float(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1))
            let cx = frame.x + size / 2, cy = frame.y + size / 2
            let r = size / 2 - 1.2
            let start = turn * 2 * .pi
            let steps = 14
            var previous: (Float, Float)?
            for i in 0...steps {
                // Three quarters of a turn, as the icon's arc is.
                let a = start + Float(i) / Float(steps) * 1.5 * .pi
                let point = (cx + r * cos(a), cy + r * sin(a))
                if let p = previous {
                    list.line(x1: p.0, y1: p.1, x2: point.0, y2: point.1, color: color,
                              width: 3 * size / 24)
                }
                previous = point
            }
            FrameScheduler.requestRedraw(in: 1.0 / 15)
        }
    }
}

/// The network window's rows, each a stated height, so the panel can open
/// the window at the size of its contents; past `maxHeight` it scrolls.
enum NetworkBlock: Identifiable {
    case wifiHeader
    case header(String)
    /// Named after the section it opens: `ForEach` keys must be unique.
    case divider(String)
    case note(String, id: String)
    case error(String)
    case wifi(WifiNetwork)
    /// "All Wi-Fi networks", with how many there are.
    case more(Int)
    /// The pane's own heading.
    case listHeader
    case wired(WiredRow)
    case vpn(VPNRow)

    static let padding: Float = 12
    static let width: Float = 360
    static let maxHeight: Float = 560

    var id: String {
        switch self {
        case .wifiHeader: return "wifi-header"
        case .header(let title): return "header." + title
        case .divider(let name): return "divider." + name
        case .note(_, let id): return "note." + id
        case .error: return "error"
        case .wifi(let wifi): return "wifi." + wifi.ssid
        case .more: return "more"
        case .listHeader: return "list-header"
        case .wired(let wired): return "wired." + wired.device.path
        case .vpn(let vpn): return "vpn." + vpn.connection.path
        }
    }

    var height: Float {
        switch self {
        case .wifiHeader: return 34
        case .header: return 23
        case .divider: return 21
        case .note: return 30
        case .error: return 44
        case .wifi(let wifi): return wifi.isConnected ? 52 : 34
        case .more: return 36
        case .listHeader: return 34
        case .wired, .vpn: return 38
        }
    }

    static func blocks(_ network: NetworkSession) -> [NetworkBlock] {
        let state = network.state
        var out: [NetworkBlock] = []
        if let error = network.recentError { out.append(.error(error)) }
        guard state.running else {
            return out + [.note("NetworkManager is not running", id: "not-running")]
        }
        if state.hasWifi {
            out.append(.wifiHeader)
            out.append(.divider("wifi"))
            if !state.wirelessHardwareEnabled {
                out.append(.note("Wi-Fi is off at the hardware switch", id: "rfkill"))
            } else if !state.wirelessEnabled {
                out.append(.note("Wi-Fi is off", id: "wifi-off"))
            } else {
                let rows = network.wifi
                if rows.isEmpty {
                    out.append(.note(state.scanning ? "Looking for networks…" : "No networks in range",
                                     id: "no-networks"))
                }
                let quick = NetworkRows.quick(rows)
                out += quick.map { .wifi($0) }
                if rows.count > quick.count { out.append(.more(rows.count)) }
            }
        }
        let wired = network.wired
        if !wired.isEmpty {
            if !out.isEmpty { out.append(.divider("wired")) }
            out.append(.header("Wired"))
            out += wired.map { .wired($0) }
        }
        let vpns = network.vpns
        if !vpns.isEmpty {
            if !out.isEmpty { out.append(.divider("vpn")) }
            out.append(.header("VPN"))
            out += vpns.map { .vpn($0) }
        }
        return out
    }

    /// The pane beside the network window: every network in range.
    static func listBlocks(_ network: NetworkSession) -> [NetworkBlock] {
        let rows = network.wifi
        guard !rows.isEmpty else {
            return [.listHeader, .note(network.state.scanning ? "Looking for networks…" : "No networks in range",
                                       id: "no-networks")]
        }
        return [.listHeader] + rows.map { .wifi($0) }
    }

    static let listWidth: Float = 320

    /// The window height for `blocks`, padding included.
    static func height(of blocks: [NetworkBlock]) -> Float {
        min(blocks.reduce(padding * 2) { $0 + $1.height }, maxHeight)
    }
}

/// What the agent asks the user for: a password for a network, the fields
/// a VPN plugin's dialog described. An ordinary window, not a popup — it has
/// to take the keyboard, and the compositor focuses a window that opens.
struct NetworkAuthWindow: View {
    var prompt: NetworkSession.SecretPrompt
    @Bindable var draft: AuthDraft

    static let width: Float = 420

    /// Title, message, each field as a label over its box, the buttons.
    static func height(_ prompt: NetworkSession.SecretPrompt) -> Float {
        let message: Float = prompt.message.isEmpty ? 0 : (prompt.message.count > 52 ? 46 : 24)
        // The header is separate from the form's padding and row spacing.
        let gaps = Float(prompt.asked.count + (prompt.message.isEmpty ? 1 : 2)) * 10
        return 44 + 4 + 24 + message + Float(prompt.asked.count) * 62 + 48 + gaps
    }

    var body: some View {
        let theme = Theme.current
        let asked = prompt.asked
        VStack(flexGrow: 1, padding: 0, spacing: 0) {
            HStack(padding: 0, alignment: .center, spacing: 12) {
                WindowControls([.close])
                Text(prompt.title, color: theme.textPrimary, lineLimit: 1)
                    .agentId("auth.title")
                Spacer()
            }
            .padding(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .frame(height: .pt(44))
            .windowDrag(doubleClickMaximizes: false)
            VStack(flexGrow: 1, padding: 0, spacing: 10) {
                if !prompt.message.isEmpty {
                    Text(prompt.message, color: theme.textSecondary)
                        .agentId("auth.message")
                }
                ForEach(Array(asked.enumerated()), id: \.element.key) { index, field in
                    VStack(padding: 0, spacing: 4) {
                        Text(field.label, color: theme.textSecondary, lineLimit: 1)
                        TextField(
                            text: draft.binding(field.key),
                            autoFocus: index == 0,
                            secure: field.secret,
                            onSubmit: { session.submitAuth(prompt.id) }
                        )
                        .agentId("auth.field." + field.key)
                    }
                }
                Spacer()
                HStack(padding: 0, alignment: .center, spacing: 10) {
                    Spacer()
                    Button("Cancel") { session.cancelAuth(prompt.id) }
                        .agentId("auth.cancel")
                    Button("Connect") { session.submitAuth(prompt.id) }
                        .agentId("auth.connect")
                }
            }
            .padding(EdgeInsets(top: 4, leading: 24, bottom: 24, trailing: 24))
        }
        .background(theme.background)
        .agentId("auth.window")
    }
}

/// What has been typed into one prompt so far.
@Observable
final class AuthDraft {
    var values: [String: String]

    init(_ prompt: NetworkSession.SecretPrompt) {
        values = Dictionary(uniqueKeysWithValues: prompt.fields.map { ($0.key, $0.value) })
    }

    func binding(_ key: String) -> Binding<String> {
        Binding(get: { self.values[key] ?? "" }, set: { self.values[key] = $0 })
    }

    /// Typed passwords do not outlive the prompt in this object.
    func clear() { values = values.mapValues { _ in "" } }
}

/// Wi-Fi arcs, a wired port and a lock, drawn into a `DrawList`.
enum NetworkGlyph {
    static func paintStatus(
        _ status: NetworkStatus, list: DrawList, frame: CanvasFrame, color: Color, accent: Color
    ) {
        let dim = color.opacity(0.3)
        // The whole box, and centred: the fan opens upwards, so its
        // bottom-right corner is empty, and that is where the VPN lock goes.
        let link = frame
        switch status.link {
        case .off:
            paintBars(0, list: list, frame: link, color: dim)
            slash(list: list, frame: link, color: dim)
        case .disconnected:
            paintBars(0, list: list, frame: link, color: dim)
        case .connecting:
            paintBars(4, list: list, frame: link, color: color.opacity(0.55))
        case .wired:
            paintWired(list: list, frame: link, color: color)
        case .wifi(let bars):
            paintBars(bars, list: list, frame: link, color: color, dim: dim)
        }
        if status.limited {
            // "!" at the top right: connected, but not to the internet.
            let x = frame.x + frame.w * 0.86
            list.rect(x: x - 1, y: frame.y + frame.h * 0.12, w: 2, h: frame.h * 0.42, color: accent)
            list.rect(x: x - 1, y: frame.y + frame.h * 0.62, w: 2, h: 2, color: accent)
        }
        if status.vpn {
            let s = min(frame.w, frame.h) * 0.48
            paintLock(
                list: list,
                frame: CanvasFrame(x: frame.x + frame.w - s, y: frame.y + frame.h - s, w: s, h: s),
                color: accent
            )
        }
    }

    /// A fan of four arcs over a dot; `bars` of them lit.
    static func paintBars(
        _ bars: Int, list: DrawList, frame: CanvasFrame, color: Color, dim: Color? = nil
    ) {
        let unlit = dim ?? color.opacity(0.3)
        let s = min(frame.w, frame.h * 1.25)
        let dot = max(1.2, s * 0.07)
        let width = max(1.2, s * 0.08)
        let outer = s * (0.24 + 2 * 0.19)
        // Centred on what is drawn — the top of the outer arc to the bottom
        // of the dot — not on the dot's position, which left the fan low.
        let inkHeight = outer + width * 0.5 + dot
        let cx = frame.x + frame.w * 0.5
        let cy = frame.y + (frame.h + inkHeight) * 0.5 - dot
        list.circle(cx: cx, cy: cy, radius: dot, color: bars > 0 ? color : unlit)
        for i in 0..<3 {
            let r = s * (0.24 + Float(i) * 0.19)
            arc(list: list, cx: cx, cy: cy, r: r, color: i + 2 <= bars ? color : unlit,
                width: width)
        }
    }

    private static func arc(list: DrawList, cx: Float, cy: Float, r: Float, color: Color, width: Float) {
        // From 225° to 315°: a quarter turn opening upwards.
        let steps = 8
        var last: (Float, Float)?
        for i in 0...steps {
            let a = Float.pi * (1.25 + 0.5 * Float(i) / Float(steps))
            let p = (cx + cos(a) * r, cy + sin(a) * r)
            if let last {
                list.line(x1: last.0, y1: last.1, x2: p.0, y2: p.1, color: color, width: width)
            }
            last = p
        }
    }

    private static func slash(list: DrawList, frame: CanvasFrame, color: Color) {
        list.line(
            x1: frame.x + frame.w * 0.2, y1: frame.y + frame.h * 0.85,
            x2: frame.x + frame.w * 0.8, y2: frame.y + frame.h * 0.15,
            color: color, width: 1.6
        )
    }

    /// Three boxes on a tree: what every desktop draws for a wired link.
    static func paintWired(list: DrawList, frame: CanvasFrame, color: Color) {
        let s = min(frame.w, frame.h)
        let cx = frame.x + frame.w * 0.5
        let top = frame.y + (frame.h - s) * 0.5 + s * 0.08
        let box = s * 0.3
        list.roundedRect(x: cx - box * 0.5, y: top, w: box, h: box * 0.8, color: color, radius: 1.5)
        let mid = top + s * 0.48
        list.line(x1: cx, y1: top + box * 0.8, x2: cx, y2: mid, color: color, width: 1.4)
        list.line(x1: cx - s * 0.3, y1: mid, x2: cx + s * 0.3, y2: mid, color: color, width: 1.4)
        for dx in [-s * 0.3, s * 0.3] {
            list.line(x1: cx + dx, y1: mid, x2: cx + dx, y2: mid + s * 0.12, color: color, width: 1.4)
            list.roundedRect(
                x: cx + dx - box * 0.5, y: mid + s * 0.12, w: box, h: box * 0.8,
                color: color, radius: 1.5
            )
        }
    }

    /// A padlock: a body and a shackle.
    static func paintLock(list: DrawList, frame: CanvasFrame, color: Color) {
        let s = min(frame.w, frame.h)
        let cx = frame.x + frame.w * 0.5
        let bodyW = s * 0.72
        let bodyH = s * 0.5
        let bodyY = frame.y + (frame.h + s) * 0.5 - bodyH
        list.roundedRect(x: cx - bodyW * 0.5, y: bodyY, w: bodyW, h: bodyH, color: color,
                         radius: max(1, s * 0.1))
        let r = s * 0.22
        let base = bodyY
        let width = max(1.2, s * 0.12)
        list.line(x1: cx - r, y1: base, x2: cx - r, y2: base - s * 0.12, color: color, width: width)
        list.line(x1: cx + r, y1: base, x2: cx + r, y2: base - s * 0.12, color: color, width: width)
        let top = base - s * 0.12
        var last: (Float, Float)?
        for i in 0...8 {
            let a = Float.pi * (1 + Float(i) / 8)
            let p = (cx + cos(a) * r, top + sin(a) * r)
            if let last {
                list.line(x1: last.0, y1: last.1, x2: p.0, y2: p.1, color: color, width: width)
            }
            last = p
        }
    }
}
