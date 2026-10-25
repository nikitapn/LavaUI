#if canImport(LavaIDL)
import Foundation
import LavaNetwork
import LavaNetworkCore
import LavaUI
import Observation

// ─── Network ────────────────────────────────────────────────────────────────

/// The half of networking the panel leaves out: what each link was given,
/// every saved profile rather than the ones in range, and changing one.
///
/// Its own model, like the Search page's, because it talks to neither the
/// compositor nor `lava.conf`: NetworkManager is the truth here, and every
/// field on the page is a copy of a profile it holds. Edits are a draft until
/// Save — an address typed a digit at a time is not something to send a digit
/// at a time — and only what changed goes back (`ProfileForm.edit`).
///
/// No secret agent. The panel is the user's one agent, and a second process
/// registering under it would take the job over and then leave with the
/// window. So a profile that needs a password started from here is still
/// asked for by the panel's prompt — which is the right place for it anyway.
@Observable
final class NetworkSettings {
    private(set) var session: NetworkSession?
    /// The profile open in the editor, by path.
    private(set) var editing: String?
    /// The editor's draft, and what it was opened as.
    var form: ProfileForm?
    private(set) var original: ProfileForm?
    /// "Forget" asks twice; this is the profile the second click forgets.
    private(set) var confirmingForget: String?
    private(set) var message: String?
    /// The editor's scroll view. Back at the top for every profile opened:
    /// one view serves them all, and the last one's place means nothing to
    /// the next.
    @ObservationIgnored let editorScroll = ScrollPosition()

    /// Started on the way into the page, as the Keyboard page's catalogue
    /// is: a settings window opened for the wallpaper need not talk to
    /// NetworkManager at all.
    ///
    /// `ready` runs once the first snapshot is in, so the page is shown with
    /// its contents rather than a frame of "Loading…" before them — or after
    /// `deadline`, so a NetworkManager that is slow to answer, or absent,
    /// still lets the click go through.
    func start(deadline: TimeInterval = 0.3, then ready: @escaping () -> Void) {
        if session == nil {
            let session = NetworkSession(agent: false)
            session.onDone = { [weak self] what, path in self?.finished(what, path) }
            self.session = session
        }
        guard let session, !session.isReady else { return ready() }
        // A second click while waiting replaces the first: one page switch.
        let ticket = UUID()
        waiting = (ticket, ready)
        session.onReady = { [weak self] in self?.fire(ticket) }
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
            MainQueue.async { networkSettings.fire(ticket) }
        }
    }

    /// Whichever comes first, the snapshot or the deadline; the other finds
    /// nothing waiting.
    private func fire(_ ticket: UUID) {
        guard let waiting, waiting.ticket == ticket else { return }
        self.waiting = nil
        waiting.ready()
    }

    @ObservationIgnored private var waiting: (ticket: UUID, ready: () -> Void)?

    var state: NetworkState { session?.state ?? NetworkState() }

    // MARK: Editor

    func open(_ connection: NetConnection) {
        editing = connection.path
        editorScroll.scrollToTop()
        form = ProfileForm(connection)
        original = form
        confirmingForget = nil
        message = nil
    }

    func close() {
        editing = nil
        form = nil
        original = nil
        confirmingForget = nil
    }

    var pendingEdit: ProfileEdit? {
        guard let form, let original else { return nil }
        return form.edit(from: original)
    }

    func save() {
        guard let session, let editing, let form, form.isValid, let edit = pendingEdit else { return }
        message = nil
        session.save(editing, edit)
    }

    func revert() {
        form = original
    }

    func forget(_ connection: NetConnection) {
        guard confirmingForget == connection.path else {
            confirmingForget = connection.path
            return
        }
        session?.forget(connection)
        message = "Forgot “\(connection.id)”."
        close()
    }

    func importFile() {
        guard let url = FileDialog.openFile(
            title: "Import a VPN Profile",
            filters: [
                .init(name: "VPN profiles", extensions: ["ovpn", "conf", "pcf", "vpn"]),
                .init(name: "All files", extensions: []),
            ]
        ) else { return }
        message = nil
        lastImport = url.lastPathComponent
        session?.importProfile(url.path)
    }

    @ObservationIgnored private var lastImport = ""

    private func finished(_ what: String, _ path: String) {
        switch what {
        case "Import":
            message = "Imported \(lastImport). It is in the list below; click it to check its settings."
        case "Save" where path == editing:
            let up = session.flatMap { NetworkRows.profile($0.state, path: path) }?.isOn ?? false
            original = form
            message = up ? "Saved. It is still running as it was; reconnect to use the change."
                         : "Saved."
        default:
            break
        }
    }

    // MARK: Bindings

    func field(_ keyPath: WritableKeyPath<ProfileForm, String>) -> Binding<String> {
        _ = form?[keyPath: keyPath]
        return Binding(
            get: { self.form?[keyPath: keyPath] ?? "" },
            set: { self.form?[keyPath: keyPath] = $0 }
        )
    }

    func flag(_ keyPath: WritableKeyPath<ProfileForm, Bool>) -> Binding<Bool> {
        _ = form?[keyPath: keyPath]
        return Binding(
            get: { self.form?[keyPath: keyPath] ?? false },
            set: { self.form?[keyPath: keyPath] = $0 }
        )
    }
}

nonisolated(unsafe) let networkSettings = NetworkSettings()

/// The page, as two scroll views of its own with one showing — the shape
/// `SettingsContent` gives whole pages, and for the same reason.
///
/// One scroll view holding first the list and then an editor kept the list's
/// offset for the editor: a VPN opened from the bottom of the page opened at
/// the bottom of its settings, after a frame drawn at the top. Two keep two
/// places — the list is where it was on the way back, and the editor starts
/// at the top (`NetworkSettings.editorScroll`).
struct NetworkPage: View {
    var body: some View {
        let model = networkSettings
        let state = model.state
        let editing = model.editing
        return HStack(flexGrow: 1, alignment: .stretch, spacing: 0) {
            ScrollView {
                NetworkColumn {
                    if model.session == nil {
                        Text("Loading…", color: Theme.current.textDim)
                    } else if !state.running {
                        SettingRow(
                            "NetworkManager is not running",
                            "Everything on this page is NetworkManager's. Start it with: "
                            + "systemctl start NetworkManager"
                        ) { EmptyView() }
                    } else {
                        NetworkOverview(model: model, state: state)
                    }
                }
            }
            .flexGrow(1)
            .hidden(editing != nil && state.running)

            ScrollView(position: model.editorScroll) {
                NetworkColumn {
                    if let editing {
                        ProfileEditor(model: model, path: editing)
                    }
                }
            }
            .flexGrow(1)
            .hidden(editing == nil || !state.running)
        }
    }
}

/// What every settings page is inside its scroll view: the title, then the
/// page. See `SettingsContent.scrolled`.
private struct NetworkColumn<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(padding: 26, spacing: 22) {
            Text(SettingsSection.network.title, color: Theme.current.textPrimary)
            content
            Spacer()
        }
    }
}

// MARK: - Overview

private struct NetworkOverview: View {
    let model: NetworkSettings
    let state: NetworkState

    var body: some View {
        let session = model.session
        let vpns = NetworkRows.vpns(state)
        let saved = NetworkRows.savedWifi(state)
        let wiredPorts = NetworkRows.wired(state)
        let wiredProfiles = NetworkRows.wiredProfiles(state)
        let error = session?.recentError

        return VStack(spacing: 18) {
            if let message = model.message {
                Text(message, color: Theme.current.textSecondary)
            }
            if let error {
                Text(error, color: Theme.current.accent)
            }

            SettingGroup("Status") {
                SettingRow(NetworkRows.summary(state), connectivity) {
                    LinkCards(state: state)
                }
            }

            if state.hasWifi || !saved.isEmpty {
                SettingGroup("Wi-Fi") {
                    if state.hasWifi {
                        SettingRow(
                            "Wi-Fi",
                            state.wirelessHardwareEnabled
                                ? "Off powers the radio down. Joining a new network is "
                                  + "the panel's: click the network icon."
                                : "The radio is switched off in hardware — a key or a "
                                  + "switch on the machine, or airplane mode."
                        ) {
                            if let session {
                                Toggle(state.wirelessEnabled ? "On" : "Off",
                                       isOn: session.wirelessBinding,
                                       isEnabled: state.wirelessHardwareEnabled)
                            }
                        }
                    }
                    SettingRow(
                        "Saved networks",
                        "Every network this machine remembers, in range or not. "
                        + "Click one to change how it connects, or to forget it."
                    ) {
                        VStack(spacing: 2) {
                            if saved.isEmpty {
                                Text("None yet.", color: Theme.current.textDim).padding(8)
                            }
                            ForEach(saved, id: \.id) { row in
                                ProfileListRow(
                                    title: row.connection.id,
                                    detail: wifiDetail(row),
                                    model: model, connection: row.connection
                                )
                            }
                        }
                    }
                }
            }

            if !wiredPorts.isEmpty || !wiredProfiles.isEmpty {
                SettingGroup("Wired") {
                    SettingRow(
                        "Profiles",
                        wiredPorts.isEmpty
                            ? "There is no wired port NetworkManager manages."
                            : wiredPorts.map { "\($0.device.iface): \($0.status)" }
                                .joined(separator: " · ")
                    ) {
                        VStack(spacing: 2) {
                            if wiredProfiles.isEmpty {
                                Text("None. NetworkManager makes one the first time a "
                                     + "cable is plugged in.", color: Theme.current.textDim)
                                    .padding(8)
                            }
                            ForEach(wiredProfiles, id: \.id) { row in
                                ProfileListRow(
                                    title: row.connection.id,
                                    detail: row.isOn ? "Connected" : "",
                                    model: model, connection: row.connection
                                )
                            }
                        }
                    }
                }
            }

            SettingGroup("VPN") {
                SettingRow(
                    "Connections",
                    "OpenVPN and the other plugins, and WireGuard. A password the "
                    + "profile does not keep is asked for by the panel."
                ) {
                    VStack(spacing: 2) {
                        if vpns.isEmpty {
                            Text("None yet. Import a file your provider gave you.",
                                 color: Theme.current.textDim)
                                .padding(8)
                        }
                        ForEach(vpns, id: \.id) { vpn in
                            ProfileListRow(
                                title: vpn.connection.id,
                                detail: vpnDetail(vpn),
                                model: model, connection: vpn.connection,
                                isOn: session.map { $0.vpnBinding(vpn) }
                            )
                        }
                        HStack {
                            ActionButton("Import from File…") { model.importFile() }
                            Spacer()
                        }
                        .padding(EdgeInsets(top: 6, leading: 0, bottom: 0, trailing: 0))
                    }
                }
            }
        }
    }

    private var connectivity: String {
        switch state.connectivity {
        case 4: return "Online."
        case 3: return "Connected, but the internet is not reachable from here."
        case 2: return "Behind a sign-in page: open a browser to get online."
        case 1: return "No network."
        default: return ""
        }
    }

    private func wifiDetail(_ row: ProfileRow) -> String {
        if row.isConnecting { return "Connecting…" }
        if row.isOn { return "Connected" }
        let used = NetworkRows.lastUsed(row.connection.timestamp)
        return row.inRange ? "In range · \(used)" : used
    }

    private func vpnDetail(_ vpn: VPNRow) -> String {
        if vpn.isConnecting { return "Connecting…" }
        if vpn.isOn, let ip = vpn.active?.ip4, !ip.isEmpty { return ip }
        return vpn.connection.remote
    }
}

/// What each link that is up was given — the card someone opens Settings
/// to read an address off.
private struct LinkCards: View {
    let state: NetworkState

    var body: some View {
        let devices = state.devices.filter { $0.managed && $0.isConnected && $0.kind != .other }
        let tunnels = state.active.filter {
            ($0.vpn || $0.type == "wireguard") && $0.state == .activated
        }
        return VStack(spacing: 12) {
            if devices.isEmpty && tunnels.isEmpty {
                Text("Nothing is connected.", color: Theme.current.textDim)
            }
            ForEach(devices, id: \.path) { device in
                VStack(spacing: 4) {
                    Text(title(device), color: Theme.current.textSecondary)
                    ForEach(NetworkRows.details(device), id: \.label) { detail in
                        DetailLine(detail: detail)
                    }
                }
            }
            ForEach(tunnels, id: \.path) { tunnel in
                VStack(spacing: 4) {
                    Text("VPN — \(tunnel.id)", color: Theme.current.textSecondary)
                    if !tunnel.ip4.isEmpty {
                        DetailLine(detail: LinkDetail("Tunnel address", tunnel.ip4))
                    }
                    if let server = state.connections.first(where: { $0.path == tunnel.connection })?
                        .remote, !server.isEmpty {
                        DetailLine(detail: LinkDetail("Server", server))
                    }
                    DetailLine(detail: LinkDetail(
                        "Traffic", tunnel.isDefault ? "Everything" : "Only its own networks"))
                }
            }
        }
    }

    private func title(_ device: NetDevice) -> String {
        let kind = device.kind == .wifi ? "Wi-Fi" : "Wired"
        let name = state.active.first { $0.path == device.activeConnection }?.id
        return name.map { "\(kind) — \($0) (\(device.iface))" } ?? "\(kind) (\(device.iface))"
    }
}

/// A label and its value, in columns. The Bluetooth page's device card
/// uses it too.
struct DetailLine: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    init(detail: LinkDetail) { self.init(detail.label, detail.value) }

    var body: some View {
        HStack(spacing: 12) {
            Text(label, color: Theme.current.textDim)
                .frame(width: .pt(140))
            Text(value, color: Theme.current.textPrimary)
                .flexShrink(1)
        }
    }
}

/// A saved profile in a list: click to edit, and for a VPN a switch.
private struct ProfileListRow: View {
    let title: String
    let detail: String
    let model: NetworkSettings
    let connection: NetConnection
    var isOn: Binding<Bool>?

    var body: some View {
        HStack(
            padding: 0,
            alignment: .center,
            spacing: 12,
            onClick: { model.open(connection) }
        ) {
            VStack(spacing: 2) {
                Text(title, color: Theme.current.textPrimary)
                if !detail.isEmpty {
                    Text(detail, color: Theme.current.textDim)
                }
            }
            .flexShrink(1)
            Spacer()
            if let isOn {
                Toggle(isOn: isOn)
            }
            Chevron(pointing: .right, color: Theme.current.textDim)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .hoverBackground(Theme.current.hover)
        .cornerRadius(6)
    }
}

// MARK: - Editor

private struct ProfileEditor: View {
    let model: NetworkSettings
    let path: String

    var body: some View {
        let state = model.state
        let row = NetworkRows.profile(state, path: path)
        let form = model.form
        return VStack(spacing: 18) {
            HStack {
                BackButton(title: "All networks") { model.close() }
                Spacer()
            }
            if let row, let form {
                EditorBody(model: model, row: row, form: form)
            } else {
                Text("This profile is no longer there — deleted, perhaps, from "
                     + "somewhere else.", color: Theme.current.textDim)
            }
        }
    }
}

private struct EditorBody: View {
    let model: NetworkSettings
    let row: ProfileRow
    let form: ProfileForm

    var body: some View {
        let connection = row.connection
        let isVPN = connection.isVPN
        let problems = form.problems
        let dirty = model.pendingEdit != nil
        let error = model.session?.recentError

        return VStack(spacing: 18) {
            SettingGroup(kind(connection)) {
                SettingRow("Name", subtitle(row)) {
                    VStack(spacing: 6) {
                        Field(text: model.field(\.name), placeholder: "Name")
                        Problem(problems[.name])
                    }
                }
                SettingRow(
                    "Connect automatically",
                    isVPN ? "Whenever the network under it is up."
                          : "Whenever it is in range or plugged in."
                ) {
                    Toggle(form.autoconnect ? "On" : "Off", isOn: model.flag(\.autoconnect))
                }
                if isVPN {
                    SettingRow(
                        "Send all traffic through it",
                        "Off, only the VPN's own networks go through it and "
                        + "everything else leaves as it would without one."
                    ) {
                        Toggle(form.neverDefault ? "Off" : "On", isOn: Binding(
                            get: { !(model.form?.neverDefault ?? false) },
                            set: { model.form?.neverDefault = !$0 }
                        ))
                    }
                }
            }

            SettingGroup("IPv4") {
                SettingRow("Addresses", methodDetail(connection)) {
                    VStack(spacing: 2) {
                        ForEach(methods(connection, current: form.method), id: \.self) { method in
                            PickerRow(title: label(method, vpn: isVPN), detail: "",
                                      selected: form.method == method) {
                                model.form?.method = method
                            }
                        }
                    }
                }
                if form.method == "manual" {
                    SettingRow("Address", "With its prefix: 192.168.1.20/24. "
                               + "Several are separated by commas.") {
                        VStack(spacing: 6) {
                            Field(text: model.field(\.addresses), placeholder: "192.168.1.20/24")
                            Problem(problems[.addresses])
                        }
                    }
                    SettingRow("Gateway", "Where traffic for everything else goes. "
                               + "Empty for a network that leads nowhere further.") {
                        VStack(spacing: 6) {
                            Field(text: model.field(\.gateway), placeholder: "192.168.1.1")
                            Problem(problems[.gateway])
                        }
                    }
                }
                if form.method != "disabled" {
                    SettingRow(
                        "DNS servers",
                        form.method == "manual"
                            ? "Comma-separated."
                            : "Comma-separated, and used beside the ones the "
                              + (isVPN ? "VPN" : "network") + " offers unless the "
                              + "switch says otherwise."
                    ) {
                        VStack(spacing: 8) {
                            Field(text: model.field(\.dns), placeholder: "1.1.1.1, 9.9.9.9")
                            Problem(problems[.dns])
                            if form.method != "manual" {
                                Toggle("Only these", isOn: model.flag(\.ignoreAutoDNS))
                            }
                        }
                    }
                }
            }

            if let message = model.message {
                Text(message, color: Theme.current.textSecondary)
            }
            if let error {
                Text(error, color: Theme.current.accent)
            }

            HStack(spacing: 8) {
                ActionButton("Save", isEnabled: dirty && problems.isEmpty) { model.save() }
                if dirty {
                    ActionButton("Revert") { model.revert() }
                }
                Spacer()
                if let session = model.session {
                    if let active = row.active, row.isOn {
                        ActionButton("Disconnect") { session.disconnect(active) }
                    } else if row.inRange {
                        ActionButton("Connect") { session.activate(connection) }
                    }
                }
                ActionButton(model.confirmingForget == connection.path
                             ? "Click again to forget" : "Forget") {
                    model.forget(connection)
                }
            }
        }
    }

    private func kind(_ c: NetConnection) -> String {
        switch c.type {
        case NetConnection.wifiType: return "Wi-Fi network"
        case NetConnection.ethernetType: return "Wired profile"
        case "wireguard": return "WireGuard tunnel"
        case "vpn": return vpnKind(c.vpnService)
        default: return c.type
        }
    }

    private func vpnKind(_ service: String) -> String {
        // "org.freedesktop.NetworkManager.openvpn" → "OpenVPN"
        let last = service.split(separator: ".").last.map(String.init) ?? ""
        let known = ["openvpn": "OpenVPN", "vpnc": "Cisco VPN (vpnc)",
                     "openconnect": "OpenConnect", "l2tp": "L2TP", "pptp": "PPTP",
                     "strongswan": "IPsec (strongSwan)", "libreswan": "IPsec (Libreswan)",
                     "fortisslvpn": "Fortinet SSL VPN", "sstp": "SSTP"]
        return known[last] ?? (last.isEmpty ? "VPN" : "VPN (\(last))")
    }

    private func subtitle(_ row: ProfileRow) -> String {
        var parts: [String] = []
        let c = row.connection
        if c.type == NetConnection.wifiType, c.ssid != c.id { parts.append("Network “\(c.ssid)”") }
        if !c.remote.isEmpty { parts.append("Server \(c.remote)") }
        parts.append(row.isOn ? "Connected now" : NetworkRows.lastUsed(c.timestamp))
        return parts.joined(separator: " · ")
    }

    private func methods(_ c: NetConnection, current: String) -> [String] {
        var list: [String]
        switch c.type {
        case "vpn": list = ["auto", "manual"]
        case "wireguard": list = ["manual", "disabled"]
        default: list = ["auto", "manual", "disabled"]
        }
        if !list.contains(current) { list.append(current) }
        return list
    }

    private func label(_ method: String, vpn: Bool) -> String {
        switch method {
        case "auto": return vpn ? "Automatic, from the VPN" : "Automatic (DHCP)"
        case "manual": return "Manual"
        case "disabled": return "Off"
        case "shared": return "Shared to other computers"
        case "link-local": return "Link-local only"
        default: return method
        }
    }

    private func methodDetail(_ c: NetConnection) -> String {
        c.type == "wireguard"
            ? "A WireGuard tunnel's address is its own; the file it came from names it."
            : "Automatic is right for nearly every network. Manual is for a "
              + "network with no DHCP, or a machine that must keep one address."
    }
}

/// "›" and "‹" drawn rather than typed. The font's are a third of the
/// line's height, and sit on the baseline rather than in the middle of the
/// row; this is `DisclosureChevron`'s stroke, turned whichever way is asked.
struct Chevron: View {
    enum Direction { case left, right }

    let pointing: Direction
    var size: Float = 16
    var color: Color

    var body: some View {
        let left = pointing == .left
        let color = color
        return Canvas(label: "Chevron", width: .pt(size), height: .pt(size)) { list, frame in
            let cx = frame.x + frame.w * 0.5
            let cy = frame.y + frame.h * 0.5
            let arm = min(frame.w, frame.h) * (4.5 / 16.0)
            // The tip, and the two ends it is drawn back to.
            let tip = left ? cx - arm * 0.5 : cx + arm * 0.5
            let back = left ? cx + arm * 0.5 : cx - arm * 0.5
            list.line(x1: back, y1: cy - arm, x2: tip, y2: cy, color: color, width: 1.75)
            list.line(x1: tip, y1: cy, x2: back, y2: cy + arm, color: color, width: 1.75)
        }
    }
}

/// `ActionButton` with a drawn chevron in front. The whole pill is the
/// target: the click is the stack's, padded first so it is one node.
struct BackButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        HStack(padding: 0, alignment: .center, spacing: 4, onClick: action) {
            Chevron(pointing: .left, color: Theme.current.textPrimary)
            Text(title, color: Theme.current.textPrimary)
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 14))
        .background(Theme.current.selectionFill)
        .hoverBackground(Theme.current.accent)
        .cornerRadius(6)
    }
}

/// A text box on a card, in the inset colour the other pages use.
struct Field: View {
    let text: Binding<String>
    let placeholder: String

    var body: some View {
        TextField(text: text, placeholder: placeholder)
            .padding(8)
            .background(Theme.current.inset)
            .cornerRadius(6)
    }
}

struct Problem: View {
    let text: String?

    init(_ text: String?) { self.text = text }

    var body: some View {
        if let text {
            Text(text, color: Theme.current.accent)
        }
    }
}

/// The Lock page's filled, clickable text, with a dimmed state for a Save
/// with nothing to save.
struct ActionButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    init(_ title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Text(
            title,
            color: isEnabled ? Theme.current.textPrimary : Theme.current.textDim,
            hoverFill: isEnabled ? Theme.current.accent : nil,
            cornerRadius: 6,
            onClick: isEnabled ? action : nil
        )
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
        .background(Theme.current.selectionFill)
        .cornerRadius(6)
    }
}
#endif
