import Foundation
import LavaNetwork
import LavaNetworkCore
import LavaUI
import Observation

/// Panel network control: a glyph for the link in use — Wi-Fi bars, a wired
/// port, nothing — with a lock when a VPN is up, and a click for the network
/// window. Talks to NetworkManager through `NetworkSession`, which is also
/// the session's secret agent.
struct NetworkApplet: View {
    var network: NetworkSession

    var body: some View {
        // Read on the body path so Observation invalidates when the link
        // changes (the paint closure alone is not tracked).
        let status = network.status
        let theme = Theme.current
        HStack(
            height: .pt(36),
            padding: 0,
            alignment: .center,
            onPointer: { _, button in
                guard button == PointerButton.left else { return }
                session.toggleNetwork()
            }) {
            Canvas(
                label: "network",
                width: .pt(PanelChrome.statusGlyph),
                height: .pt(PanelChrome.statusGlyph),
                paint: { list, frame in
                    NetworkGlyph.paintStatus(
                        status, list: list, frame: frame,
                        color: theme.textPrimary, accent: theme.accent
                    )
                }
            )
        }
        .padding(2)
        .hoverBackground(PanelChrome.style.titleHover)
        .cornerRadius(6)
        .agentId("applet.network")
    }
}

/// The network window: Wi-Fi on or off and the networks in range, wired
/// ports, then VPNs. A popup of this process, like the sound window, and
/// sized the same way — from rows of stated heights.
struct NetworkWindow: View {
    var network: NetworkSession
    /// The pane beside it: every network in range, instead of the window's
    /// own short list, wired ports and VPNs.
    var isList = false

    var body: some View {
        let blocks = isList ? NetworkBlock.listBlocks(network) : NetworkBlock.blocks(network)
        ScrollView(showsIndicator: true) {
            VStack(padding: NetworkBlock.padding, spacing: 0) {
                ForEach(blocks) { block in
                    row(block).frame(height: .pt(block.height))
                }
            }
        }
        .background(PanelChrome.popupWash)
        .agentId(isList ? "network.list" : "network.window")
    }

    @ViewBuilder
    private func row(_ block: NetworkBlock) -> some View {
        let theme = Theme.current
        switch block {
        case .wifiHeader:
            HStack(padding: 0, alignment: .center, spacing: 8) {
                Text("Wi-Fi", color: theme.textSecondary)
                    .padding(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
                if network.state.scanning {
                    Text("Scanning…", color: theme.textDim)
                }
                Spacer()
                Toggle(isOn: network.wirelessBinding, isEnabled: network.state.wirelessHardwareEnabled)
                    .agentId("network.wifi-toggle")
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
                Text(text, color: theme.textDim, lineLimit: 1)
                    .padding(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
                    .flexShrink(1)
            }
        case .error(let text):
            HStack(padding: 0, alignment: .center) {
                Text(text, color: theme.accent, lineLimit: 2)
                    .padding(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
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
            moreRow(count)
        case .listHeader:
            HStack(padding: 0, alignment: .center, spacing: 8) {
                Text("Wi-Fi networks", color: theme.textSecondary)
                    .padding(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
                if network.state.scanning {
                    Text("Scanning…", color: theme.textDim)
                }
                Spacer()
            }
        case .wired(let wired):
            wiredRow(wired)
        case .vpn(let vpn):
            vpnRow(vpn)
        }
    }

    /// Every network in range, in the pane beside this one. A scan in a
    /// city is dozens of names, and listed here they pushed the wired port
    /// and the VPNs — what a click here is usually for — off the bottom.
    private func moreRow(_ count: Int) -> some View {
        let theme = Theme.current
        let open = session.networkListWindow.map { LavaApp.isWindowOpen($0) } ?? false
        return HStack(
            padding: 0, alignment: .center, spacing: 8,
            onClick: { session.toggleNetworkList() }
        ) {
            Text("All Wi-Fi networks", color: theme.textPrimary, lineLimit: 1)
                .flexShrink(1)
            Spacer()
            Text("\(count)", color: theme.textDim, lineLimit: 1)
                .flexShrink(0)
            Text("‹", color: open ? theme.accent : theme.textDim)
                .flexShrink(0)
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .hoverBackground(theme.hover)
        .cornerRadius(6)
        .cursor(.pointer)
        .tooltip("Every network in range, beside this window")
        .agentId("network.all")
    }

    private func wiredRow(_ wired: WiredRow) -> some View {
        let theme = Theme.current
        return HStack(padding: 0, alignment: .center, spacing: 8) {
            Canvas(label: "port", width: .pt(18), height: .pt(16)) { list, frame in
                NetworkGlyph.paintWired(
                    list: list, frame: frame,
                    color: wired.device.isConnected ? theme.accent : theme.textDim
                )
            }
            .flexShrink(0)
            Text(wired.active?.id ?? wired.device.iface, color: theme.textPrimary, lineLimit: 1)
                .flexShrink(1)
            Spacer()
            Text(wired.status, color: theme.textDim, lineLimit: 1)
                .flexShrink(0)
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .agentId("network.wired." + wired.device.iface)
    }

    private func vpnRow(_ vpn: VPNRow) -> some View {
        let theme = Theme.current
        return HStack(padding: 0, alignment: .center, spacing: 8) {
            Canvas(label: "lock", width: .pt(18), height: .pt(16)) { list, frame in
                NetworkGlyph.paintLock(
                    list: list, frame: frame, color: vpn.isOn ? theme.accent : theme.textDim
                )
            }
            .flexShrink(0)
            Text(vpn.connection.id, color: theme.textPrimary, lineLimit: 1)
                .flexShrink(1)
            Spacer()
            if vpn.isConnecting {
                Text("Connecting…", color: theme.textDim, lineLimit: 1)
                    .flexShrink(0)
            }
            Toggle(isOn: network.vpnBinding(vpn))
                .agentId("network.vpn-toggle." + vpn.connection.id)
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .agentId("network.vpn." + vpn.connection.id)
    }
}

/// One Wi-Fi network: bars, name, lock, what it is doing. In the network
/// window and in the pane of every network beside it.
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
        let theme = Theme.current
        let wifi = wifi
        let network = network
        let onConnect = onConnect
        let showsDisconnect = showsDisconnect
        let enterprise = wifi.security == .enterprise
        let busy = wifi.isConnected || wifi.isConnecting
        let colour = enterprise ? theme.textDim : theme.textPrimary
        let status = wifi.isConnected ? "Connected" : wifi.isConnecting ? "Connecting…" : ""
        let bars = NetworkRows.bars(wifi.strength)
        return HStack(
            padding: 0, alignment: .center, spacing: 8,
            onClick: busy || enterprise ? nil : {
                network.connect(wifi)
                onConnect?()
            }
        ) {
            Canvas(label: "bars", width: .pt(18), height: .pt(16)) { list, frame in
                NetworkGlyph.paintBars(
                    bars, list: list, frame: frame,
                    color: wifi.isConnected ? theme.accent : colour
                )
            }
            .flexShrink(0)
            Text(wifi.ssid, color: colour, lineLimit: 1)
                .flexShrink(1)
            Spacer()
            if !status.isEmpty {
                Text(status, color: theme.textDim, lineLimit: 1)
                    .flexShrink(0)
            }
            if wifi.security.showsLock {
                Canvas(label: "lock", width: .pt(10), height: .pt(12)) { list, frame in
                    NetworkGlyph.paintLock(list: list, frame: frame, color: theme.textDim)
                }
                .flexShrink(0)
            }
            if showsDisconnect, let active = wifi.active {
                Text(
                    "Disconnect", color: theme.textSecondary,
                    hoverFill: theme.hover, cornerRadius: 4,
                    onClick: { network.disconnect(active) }
                )
                .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                .flexShrink(0)
                .agentId("network.disconnect")
            }
        }
        .padding(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .hoverBackground(busy || enterprise ? Color.clear : theme.hover)
        .cornerRadius(6)
        .cursor(busy || enterprise ? .arrow : .pointer)
        .tooltip(enterprise ? "Enterprise network — set it up with nm-connection-editor" : wifi.ssid)
        .agentId("network.wifi." + wifi.ssid)
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
        case .wifiHeader: return 32
        case .header: return 26
        case .divider: return 13
        case .note: return 28
        case .error: return 44
        case .wifi, .more, .listHeader, .wired, .vpn: return 32
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
        return 24 * 2 + 26 + message + Float(prompt.asked.count) * 62 + 48
    }

    var body: some View {
        let theme = Theme.current
        let asked = prompt.asked
        VStack(flexGrow: 1, padding: 24, spacing: 10) {
            Text(prompt.title, color: theme.textPrimary, lineLimit: 1)
                .agentId("auth.title")
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
