#if canImport(LavaIDL)
import Foundation
import LavaBluetooth
import LavaBluetoothCore
import LavaUI
import Observation

// ─── Bluetooth ──────────────────────────────────────────────────────────────

/// The half of Bluetooth the panel leaves out: this computer's own name and
/// whether others can find it, every paired device rather than the ones in
/// reach, and what is set on each — its name here, trusted, blocked.
///
/// Its own model, like the Network page's: BlueZ is the truth, and every
/// field is a copy of something bluetoothd holds.
///
/// No pairing agent. The panel is the user's default one, and a pairing
/// started here asks through it: BlueZ turns to the default agent when the
/// process that called Pair has none of its own. So the code to compare
/// comes up in the panel's window, as it does for a pairing started there.
@Observable
final class BluetoothSettings {
    private(set) var session: BluetoothSession?
    /// The device open in the editor, by path.
    private(set) var editing: String?
    /// Typed names not yet saved: this computer's, and the open device's.
    /// nil is "as BlueZ has it".
    var adapterName: String?
    var deviceName: String?
    /// "Forget" asks twice; this is the device the second click forgets.
    private(set) var confirmingForget: String?
    private(set) var message: String?
    /// The page's own search. Stopped on leaving the page, and after
    /// `searchLength` whatever happens — a radio left shouting because a
    /// window was left open is a battery somebody pays for.
    private(set) var searching = false
    @ObservationIgnored private var searchTicket = UUID()
    static let searchLength: TimeInterval = 120

    @ObservationIgnored let editorScroll = ScrollPosition()

    /// Started on the way into the page; `ready` runs once the first
    /// snapshot is in, or after `deadline` — see `NetworkSettings.start`.
    func start(deadline: TimeInterval = 0.3, then ready: @escaping () -> Void) {
        if session == nil { session = BluetoothSession(agent: false) }
        guard let session, !session.isReady else { return ready() }
        let ticket = UUID()
        waiting = (ticket, ready)
        session.onReady = { [weak self] in self?.fire(ticket) }
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
            MainQueue.async { bluetoothSettings.fire(ticket) }
        }
    }

    private func fire(_ ticket: UUID) {
        guard let waiting, waiting.ticket == ticket else { return }
        self.waiting = nil
        waiting.ready()
    }

    @ObservationIgnored private var waiting: (ticket: UUID, ready: () -> Void)?

    var state: BluetoothState { session?.state ?? BluetoothState() }

    /// Another page was picked.
    func leave() { stopSearch() }

    // MARK: Search

    func startSearch() {
        guard let session else { return }
        message = nil
        searching = true
        session.setSearching(true)
        let ticket = UUID()
        searchTicket = ticket
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.searchLength) {
            MainQueue.async {
                guard bluetoothSettings.searchTicket == ticket else { return }
                bluetoothSettings.stopSearch()
            }
        }
    }

    func stopSearch() {
        guard searching else { return }
        searching = false
        searchTicket = UUID()
        session?.setSearching(false)
    }

    func pair(_ device: BtDevice) {
        message = "Pairing with \(device.name). If there is a code to compare or type, "
            + "the panel asks for it."
        session?.pair(device)
    }

    // MARK: This computer

    var adapterDirty: Bool {
        guard let adapterName, let adapter = state.adapter else { return false }
        return adapterName.trimmingCharacters(in: .whitespaces) != adapter.name
    }

    func renameAdapter() {
        guard let session, let adapter = state.adapter, let adapterName, adapterDirty else { return }
        let name = adapterName.trimmingCharacters(in: .whitespaces)
        guard BluetoothRows.nameProblem(name) == nil else { return }
        session.rename(adapter.path, to: name)
        self.adapterName = nil
    }

    var adapterNameBinding: Binding<String> {
        _ = adapterName
        return Binding(
            get: { self.adapterName ?? self.state.adapter?.name ?? "" },
            set: { self.adapterName = $0 }
        )
    }

    // MARK: Editor

    func open(_ device: BtDevice) {
        editing = device.path
        editorScroll.scrollToTop()
        deviceName = nil
        confirmingForget = nil
        message = nil
    }

    func close() {
        editing = nil
        deviceName = nil
        confirmingForget = nil
    }

    func device(_ path: String) -> BtDevice? { state.devices.first { $0.path == path } }

    var deviceDirty: Bool {
        guard let deviceName, let editing, let device = device(editing) else { return false }
        return deviceName.trimmingCharacters(in: .whitespaces) != device.name
    }

    func renameDevice() {
        guard let session, let editing, let deviceName, deviceDirty else { return }
        let name = deviceName.trimmingCharacters(in: .whitespaces)
        guard BluetoothRows.nameProblem(name) == nil else { return }
        session.rename(editing, to: name)
        self.deviceName = nil
    }

    /// Back to what the device calls itself.
    func resetDeviceName() {
        guard let session, let editing else { return }
        session.rename(editing, to: "")
        deviceName = nil
    }

    var deviceNameBinding: Binding<String> {
        _ = deviceName
        return Binding(
            get: {
                self.deviceName ?? self.editing.flatMap { self.device($0)?.name } ?? ""
            },
            set: { self.deviceName = $0 }
        )
    }

    func forget(_ device: BtDevice) {
        guard confirmingForget == device.path else {
            confirmingForget = device.path
            return
        }
        session?.forget(device)
        message = "Forgot \(device.name). Pair it again to use it."
        close()
    }
}

nonisolated(unsafe) let bluetoothSettings = BluetoothSettings()

/// Two scroll views with one showing, as `NetworkPage` has, for the same
/// reason: the list keeps its place, and a device opens at the top.
struct BluetoothPage: View {
    var body: some View {
        let model = bluetoothSettings
        let state = model.state
        let editing = model.editing
        let available = state.running && state.adapter != nil
        return HStack(flexGrow: 1, alignment: .stretch, spacing: 0) {
            ScrollView {
                BluetoothColumn {
                    if model.session == nil {
                        Text("Loading…", color: Theme.current.textDim)
                    } else if !state.running {
                        SettingRow(
                            "Bluetooth is not running",
                            "Everything on this page is bluetoothd's. Start it with: "
                            + "systemctl start bluetooth"
                        ) { EmptyView() }
                    } else if state.adapter == nil {
                        SettingRow(
                            "No Bluetooth adapter",
                            "bluetoothd is running, but sees no radio. A USB adapter "
                            + "appears here as soon as it is plugged in."
                        ) { EmptyView() }
                    } else {
                        BluetoothOverview(model: model, state: state)
                    }
                }
            }
            .flexGrow(1)
            .hidden(editing != nil && available)

            ScrollView(position: model.editorScroll) {
                BluetoothColumn {
                    if let editing {
                        DeviceEditor(model: model, path: editing)
                    }
                }
            }
            .flexGrow(1)
            .hidden(editing == nil || !available)
        }
    }
}

private struct BluetoothColumn<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(padding: 26, spacing: 22) {
            Text(SettingsSection.bluetooth.title, color: Theme.current.textPrimary)
            content
            Spacer()
        }
    }
}

// MARK: - Overview

private struct BluetoothOverview: View {
    let model: BluetoothSettings
    let state: BluetoothState

    var body: some View {
        let session = model.session
        let adapter = state.adapter
        let powered = adapter?.powered == true
        let blocked = adapter?.isBlocked == true
        let devices = BluetoothRows.settingsDevices(state)
        let found = BluetoothRows.discovered(state)
        let nameProblem = BluetoothRows.nameProblem(model.adapterName ?? "")

        return VStack(spacing: 18) {
            if let message = model.message {
                Text(message, color: Theme.current.textSecondary)
            }
            if let error = session?.recentError {
                Text(error, color: Theme.current.accent)
            }

            SettingGroup("This computer") {
                SettingRow(
                    "Bluetooth",
                    blocked
                        ? "Switched off in hardware — a key or a switch on the machine, "
                          + "or airplane mode."
                        : "Off powers the radio down, and every device on it is dropped."
                ) {
                    if let session {
                        Toggle(powered ? "On" : "Off", isOn: session.poweredBinding,
                               isEnabled: !blocked)
                    }
                }
                if powered, let adapter {
                    SettingRow(
                        "Name",
                        "What a phone or another computer lists this one as. "
                        + "Its address is \(adapter.address)."
                    ) {
                        VStack(spacing: 6) {
                            Field(text: model.adapterNameBinding, placeholder: adapter.name)
                            Problem(nameProblem)
                            HStack {
                                ActionButton("Rename",
                                             isEnabled: model.adapterDirty && nameProblem == nil) {
                                    model.renameAdapter()
                                }
                                Spacer()
                            }
                        }
                    }
                    SettingRow("Visible to other devices", BluetoothRows.visibility(adapter)) {
                        if let session {
                            Toggle(adapter.discoverable ? "Visible" : "Hidden", isOn: Binding(
                                get: { session.state.adapter?.discoverable ?? false },
                                set: { session.setDiscoverable($0) }
                            ))
                        }
                    }
                }
            }

            SettingGroup("Devices") {
                SettingRow(
                    "Paired devices",
                    "Click one to rename it, trust or block it, or forget it. Connecting "
                    + "and disconnecting is also the panel's: click the Bluetooth icon."
                ) {
                    VStack(spacing: 2) {
                        if devices.isEmpty {
                            Text("None yet.", color: Theme.current.textDim).padding(8)
                        }
                        ForEach(devices, id: \.id) { device in
                            DeviceListRow(
                                title: device.name, detail: BluetoothRows.detail(device),
                                showsChevron: true
                            ) { model.open(device) }
                        }
                    }
                }
            }

            if powered {
                SettingGroup("Add a device") {
                    SettingRow(
                        "Search",
                        model.searching
                            ? "Searching. Put the device in pairing mode and it appears "
                              + "below; click it to pair."
                            : "Looks for devices in pairing mode, for two minutes."
                    ) {
                        VStack(spacing: 2) {
                            HStack {
                                ActionButton(model.searching ? "Stop" : "Search") {
                                    if model.searching { model.stopSearch() } else { model.startSearch() }
                                }
                                Spacer()
                            }
                            .padding(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
                            if model.searching && found.isEmpty {
                                Text("Nothing yet.", color: Theme.current.textDim).padding(8)
                            }
                            if model.searching || !found.isEmpty {
                                ForEach(found, id: \.id) { device in
                                    DeviceListRow(
                                        title: device.name, detail: foundDetail(device),
                                        showsChevron: false
                                    ) {
                                        if device.busy == .idle { model.pair(device) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func foundDetail(_ device: BtDevice) -> String {
        let status = BluetoothRows.status(device)
        if !status.isEmpty { return status }
        // "Speaker" under "Speaker" says nothing.
        let name = BluetoothRows.kindName(device.kind)
        let kind = name == device.name ? [] : [name]
        let distance: [String]
        switch BluetoothRows.bars(device.rssi) {
        case 4: distance = ["Close by"]
        case 3: distance = ["Nearby"]
        case 0: distance = []
        default: distance = ["Far away"]
        }
        return (kind + distance).joined(separator: " · ")
    }
}

/// A device in a list: its name, a line about it, and a click.
private struct DeviceListRow: View {
    let title: String
    let detail: String
    let showsChevron: Bool
    let action: () -> Void

    var body: some View {
        HStack(padding: 0, alignment: .center, spacing: 12, onClick: action) {
            VStack(spacing: 2) {
                Text(title, color: Theme.current.textPrimary)
                if !detail.isEmpty {
                    Text(detail, color: Theme.current.textDim)
                }
            }
            .flexShrink(1)
            Spacer()
            if showsChevron {
                Chevron(pointing: .right, color: Theme.current.textDim)
            } else {
                Text("Pair", color: Theme.current.textSecondary)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .hoverBackground(Theme.current.hover)
        .cornerRadius(6)
    }
}

// MARK: - Editor

private struct DeviceEditor: View {
    let model: BluetoothSettings
    let path: String

    var body: some View {
        let device = model.device(path)
        return VStack(spacing: 18) {
            HStack {
                BackButton(title: "All devices") { model.close() }
                Spacer()
            }
            if let device, let session = model.session {
                DeviceEditorBody(model: model, session: session, device: device)
            } else {
                Text("This device is no longer there — forgotten, perhaps, from "
                     + "somewhere else.", color: Theme.current.textDim)
            }
        }
    }
}

private struct DeviceEditorBody: View {
    let model: BluetoothSettings
    let session: BluetoothSession
    let device: BtDevice

    var body: some View {
        let device = device
        let session = session
        let renamed = !device.ownName.isEmpty && device.ownName != device.name
        let nameProblem = BluetoothRows.nameProblem(model.deviceName ?? "")

        return VStack(spacing: 18) {
            SettingGroup(BluetoothRows.kindName(device.kind)) {
                SettingRow(
                    "Name",
                    renamed
                        ? "It calls itself “\(device.ownName)”. The name here is this computer's only."
                        : "The name here is this computer's only; the device keeps its own."
                ) {
                    VStack(spacing: 6) {
                        Field(text: model.deviceNameBinding, placeholder: device.ownName)
                        Problem(nameProblem)
                        HStack(spacing: 8) {
                            ActionButton("Rename", isEnabled: model.deviceDirty && nameProblem == nil) {
                                model.renameDevice()
                            }
                            if renamed {
                                ActionButton("Use Its Own Name") { model.resetDeviceName() }
                            }
                            Spacer()
                        }
                    }
                }
                SettingRow("Details", "") {
                    VStack(spacing: 4) {
                        DetailLine("Status", status(device))
                        if let battery = device.battery {
                            DetailLine("Battery", "\(battery)%")
                        }
                        DetailLine("Address", device.address)
                        DetailLine("Paired", device.paired ? "Yes" : "No")
                    }
                }
                SettingRow(
                    "Trusted",
                    "Connects by itself — a headset switched on, a keyboard woken — "
                    + "and uses what it offers without being asked about each."
                ) {
                    Toggle(device.trusted ? "On" : "Off", isOn: Binding(
                        get: { model.device(device.path)?.trusted ?? false },
                        set: { session.setTrusted(device, $0) }
                    ))
                }
                SettingRow(
                    "Blocked",
                    "Every connection from it is refused until it is unblocked here. "
                    + "It stays paired."
                ) {
                    Toggle(device.blocked ? "On" : "Off", isOn: Binding(
                        get: { model.device(device.path)?.blocked ?? false },
                        set: { session.setBlocked(device, $0) }
                    ))
                }
            }

            if let message = model.message {
                Text(message, color: Theme.current.textSecondary)
            }
            if let error = session.recentError {
                Text(error, color: Theme.current.accent)
            }

            HStack(spacing: 8) {
                if !device.blocked {
                    if device.connected {
                        ActionButton("Disconnect", isEnabled: device.busy == .idle) {
                            session.disconnect(device)
                        }
                    } else {
                        ActionButton(device.busy == .connecting ? "Connecting…" : "Connect",
                                     isEnabled: device.busy == .idle) {
                            session.connect(device)
                        }
                    }
                }
                Spacer()
                ActionButton(model.confirmingForget == device.path
                             ? "Click again to forget" : "Forget") {
                    model.forget(device)
                }
            }
        }
    }

    private func status(_ device: BtDevice) -> String {
        let s = BluetoothRows.status(device)
        if device.blocked { return "Blocked" }
        return s.isEmpty ? "Not connected" : s
    }
}
#endif
