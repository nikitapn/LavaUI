import CLavaNet
import Foundation
import LavaNetworkCore
import LavaUI
import Observation

/// Live view of NetworkManager, and the panel's secret agent.
///
/// `CLavaNet` runs libnm on a thread of its own; every snapshot is copied
/// into Swift values there and hopped onto `MainQueue` before touching
/// `@Observable` properties, as `PulseSession` and `MprisSession` do.
@Observable
public final class NetworkSession: @unchecked Sendable {
    public private(set) var state = NetworkState()
    /// What the agent is waiting on the user for, oldest first.
    public private(set) var prompts: [SecretPrompt] = []
    /// The last command that failed, and when — the popup shows it for a
    /// while rather than forever.
    public private(set) var lastError: (what: String, message: String, at: Date)?

    /// A new prompt, for the panel to put a window up for.
    @ObservationIgnored public var onPrompt: ((SecretPrompt) -> Void)?
    /// NetworkManager no longer needs prompt `id`.
    @ObservationIgnored public var onPromptGone: ((UInt64) -> Void)?
    /// A save or an import went through: what, and the profile's path.
    @ObservationIgnored public var onDone: ((String, String) -> Void)?

    private var handle: OpaquePointer?
    private var box: Unmanaged<NetworkSession>?

    public struct SecretPrompt: Identifiable, Equatable, Sendable {
        public struct Field: Equatable, Sendable {
            public var key: String
            public var label: String
            public var value: String
            public var secret: Bool
            /// Only these are shown; the rest go back with the plugin's value.
            public var ask: Bool
        }

        public var id: UInt64
        public var connection: String
        public var title: String
        public var message: String
        public var fields: [Field]

        public var asked: [Field] { fields.filter(\.ask) }
    }

    /// `agent: false` watches and changes NetworkManager without answering
    /// for secrets. There is one agent per user and the panel is it; a
    /// second process registering would take that over from the panel.
    public init(agent: Bool = true) {
        let unmanaged = Unmanaged.passRetained(self)
        box = unmanaged
        var callbacks = LavaNetCallbacks()
        callbacks.snapshot = { user, snap in
            guard let user, let snap else { return }
            let session = Unmanaged<NetworkSession>.fromOpaque(user).takeUnretainedValue()
            let state = NetworkSession.copy(snap.pointee)
            MainQueue.async { session.adopt(state) }
        }
        callbacks.secret_request = { user, request in
            guard let user, let request else { return }
            let session = Unmanaged<NetworkSession>.fromOpaque(user).takeUnretainedValue()
            let prompt = NetworkSession.copy(request.pointee)
            MainQueue.async { session.add(prompt) }
        }
        callbacks.secret_cancelled = { user, id in
            guard let user else { return }
            let session = Unmanaged<NetworkSession>.fromOpaque(user).takeUnretainedValue()
            MainQueue.async { session.drop(id, notify: true) }
        }
        callbacks.error = { user, what, message in
            guard let user else { return }
            let session = Unmanaged<NetworkSession>.fromOpaque(user).takeUnretainedValue()
            let what = what.map { String(cString: $0) } ?? ""
            let message = message.map { String(cString: $0) } ?? ""
            MainQueue.async {
                session.lastError = (what, message, Date())
                ViewInvalidation.markNeedsRedraw()
            }
        }
        callbacks.done = { user, what, path in
            guard let user else { return }
            let session = Unmanaged<NetworkSession>.fromOpaque(user).takeUnretainedValue()
            let what = what.map { String(cString: $0) } ?? ""
            let path = path.map { String(cString: $0) } ?? ""
            MainQueue.async { session.onDone?(what, path) }
        }
        handle = lava_net_create(&callbacks, unmanaged.toOpaque(), agent ? 1 : 0)
        if handle == nil {
            unmanaged.release()
            box = nil
        }
    }

    deinit {
        if let handle { lava_net_destroy(handle) }
        box?.release()
    }

    private func adopt(_ next: NetworkState) {
        guard next != state else { return }
        state = next
        // Paint closures are not observation-tracked; the strip glyph is one.
        ViewInvalidation.markNeedsRedraw()
    }

    private func add(_ prompt: SecretPrompt) {
        prompts.append(prompt)
        onPrompt?(prompt)
    }

    private func drop(_ id: UInt64, notify: Bool) {
        guard prompts.contains(where: { $0.id == id }) else { return }
        prompts.removeAll { $0.id == id }
        if notify { onPromptGone?(id) }
    }

    // MARK: - Reading

    public var wifi: [WifiNetwork] { NetworkRows.wifi(state) }
    public var vpns: [VPNRow] { NetworkRows.vpns(state) }
    public var wired: [WiredRow] { NetworkRows.wired(state) }
    public var status: NetworkStatus { NetworkRows.status(state) }
    public var summary: String { NetworkRows.summary(state) }

    /// The last error, if it is recent enough to still be news.
    public var recentError: String? {
        guard let lastError, Date().timeIntervalSince(lastError.at) < 15 else { return nil }
        return "\(lastError.what): \(lastError.message)"
    }

    // MARK: - Commands

    public func setWirelessEnabled(_ on: Bool) {
        guard let handle else { return }
        state.wirelessEnabled = on
        lava_net_set_wireless_enabled(handle, on ? 1 : 0)
    }

    public var wirelessBinding: Binding<Bool> {
        Binding(get: { self.state.wirelessEnabled }, set: { self.setWirelessEnabled($0) })
    }

    public func scan() {
        guard let handle else { return }
        lava_net_request_scan(handle)
    }

    /// A saved network starts its saved connection, on the access point in
    /// the row; a new one is joined, and the agent asks for its password.
    public func connect(_ network: WifiNetwork) {
        guard let handle else { return }
        lastError = nil
        if let saved = network.saved {
            lava_net_activate(handle, saved.path, network.device, network.accessPoint)
        } else {
            lava_net_connect_access_point(handle, network.device, network.accessPoint, nil)
        }
    }

    public func disconnect(_ active: NetActive) {
        guard let handle else { return }
        lava_net_deactivate(handle, active.path)
    }

    public func setVPN(_ vpn: VPNRow, on: Bool) {
        guard let handle else { return }
        lastError = nil
        if on {
            guard !vpn.isOn else { return }
            lava_net_activate(handle, vpn.connection.path, nil, nil)
        } else if let active = vpn.active {
            lava_net_deactivate(handle, active.path)
        }
    }

    public func vpnBinding(_ vpn: VPNRow) -> Binding<Bool> {
        Binding(
            get: { self.vpns.first { $0.id == vpn.id }?.isOn ?? vpn.isOn },
            set: { self.setVPN(vpn, on: $0) }
        )
    }

    public func forget(_ connection: NetConnection) {
        guard let handle else { return }
        lava_net_forget(handle, connection.path)
    }

    /// Writes `edit` into the profile at `path`. The answer comes back as
    /// `onDone("Save", path)` or as `lastError`.
    public func save(_ path: String, _ edit: ProfileEdit) {
        guard let handle else { return }
        lastError = nil
        let ip4 = edit.ip4
        let strings = [
            edit.name, ip4?.method, ip4.map { $0.addresses.joined(separator: ",") },
            ip4?.gateway, ip4.map { $0.dns.joined(separator: ",") },
        ]
        // NULL for a field the edit leaves alone.
        let copies = strings.map { $0.map { strdup($0) } ?? nil }
        defer { copies.forEach { free($0) } }
        var c = LavaNetEdit()
        c.id = UnsafePointer(copies[0])
        c.autoconnect = edit.autoconnect.map { $0 ? 1 : 0 } ?? -1
        c.ip4_method = UnsafePointer(copies[1])
        c.ip4_addresses = UnsafePointer(copies[2])
        c.ip4_gateway = UnsafePointer(copies[3])
        c.ip4_dns = UnsafePointer(copies[4])
        c.ip4_ignore_auto_dns = ip4.map { $0.ignoreAutoDNS ? 1 : 0 } ?? -1
        c.ip4_never_default = edit.neverDefault.map { $0 ? 1 : 0 } ?? -1
        lava_net_update(handle, path, &c)
    }

    public func setAutoconnect(_ connection: NetConnection, _ on: Bool) {
        save(connection.path, ProfileEdit(autoconnect: on))
    }

    /// Adds a profile from a WireGuard `.conf` or anything a VPN plugin
    /// imports; `onDone("Import", path)` names the new one.
    public func importProfile(_ file: String) {
        guard let handle else { return }
        lastError = nil
        lava_net_import(handle, file)
    }

    /// Starts a saved profile wherever NetworkManager sees fit.
    public func activate(_ connection: NetConnection) {
        guard let handle else { return }
        lastError = nil
        lava_net_activate(handle, connection.path, nil, nil)
    }

    /// Answers prompt `id`. `values` is keyed by field key.
    public func answer(_ id: UInt64, values: [String: String]) {
        guard let handle else { return }
        drop(id, notify: false)
        let keys = Array(values.keys)
        withCStrings(keys) { k in
            withCStrings(keys.map { values[$0] ?? "" }) { v in
                lava_net_secret_reply(handle, id, k, v, keys.count)
            }
        }
    }

    public func decline(_ id: UInt64) {
        guard let handle else { return }
        drop(id, notify: false)
        lava_net_secret_cancel(handle, id)
    }

    // MARK: - Tests

    /// The agent's GetSecrets on `connection` (GVariant text), as if
    /// NetworkManager had asked; see `lava_net_test_get_secrets`. `done` runs
    /// on the main queue.
    func testGetSecrets(
        connection: String, setting: String, flags: UInt32,
        done: @escaping @Sendable (String) -> Void
    ) {
        guard let handle else { return done("error no session") }
        let box = Unmanaged.passRetained(TestReply(done)).toOpaque()
        lava_net_test_get_secrets(handle, connection, setting, flags, { user, result in
            guard let user else { return }
            let reply = Unmanaged<TestReply>.fromOpaque(user).takeRetainedValue()
            let text = result.map { String(cString: $0) } ?? ""
            MainQueue.async { reply.done(text) }
        }, box)
    }

    /// NetworkManager's CancelGetSecrets for a `testGetSecrets` request.
    func testCancelSecrets(setting: String) {
        guard let handle else { return }
        lava_net_test_cancel_secrets(handle, setting)
    }

    private final class TestReply: @unchecked Sendable {
        let done: @Sendable (String) -> Void
        init(_ done: @escaping @Sendable (String) -> Void) { self.done = done }
    }

    // MARK: - Copying out of C

    private static func text(_ p: UnsafePointer<CChar>?) -> String {
        p.map { String(cString: $0) } ?? ""
    }

    /// "a, b" → ["a", "b"]: how the C side joins a list.
    private static func list(_ p: UnsafePointer<CChar>?) -> [String] {
        text(p).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func buffer<T>(_ base: UnsafePointer<T>?, _ count: Int) -> UnsafeBufferPointer<T> {
        guard let base, count > 0 else { return UnsafeBufferPointer(start: nil, count: 0) }
        return UnsafeBufferPointer(start: base, count: count)
    }

    static func copy(_ s: LavaNetSnapshot) -> NetworkState {
        var state = NetworkState()
        state.running = s.running != 0
        state.networkingEnabled = s.networking_enabled != 0
        state.wirelessEnabled = s.wireless_enabled != 0
        state.wirelessHardwareEnabled = s.wireless_hardware_enabled != 0
        state.state = Int(s.state)
        state.connectivity = Int(s.connectivity)
        state.primary = text(s.primary)
        state.scanning = s.scanning != 0
        state.devices = buffer(s.devices, s.device_count).map { d in
            NetDevice(
                path: text(d.path), iface: text(d.iface),
                kind: NetDevice.Kind(rawValue: Int(d.type)) ?? .other, state: Int(d.state),
                activeConnection: text(d.active_connection),
                activeAccessPoint: text(d.active_access_point), managed: d.managed != 0,
                ip4: text(d.ip4), gateway: text(d.ip4_gateway), dns: list(d.ip4_dns),
                ip6: text(d.ip6), hwAddress: text(d.hw_address), speed: d.speed
            )
        }
        state.accessPoints = buffer(s.access_points, s.access_point_count).map { a in
            NetAccessPoint(
                path: text(a.path), device: text(a.device), ssid: text(a.ssid),
                bssid: text(a.bssid), strength: Int(a.strength),
                security: NetSecurity(rawValue: Int(a.security)) ?? .open, frequency: a.frequency
            )
        }
        state.active = buffer(s.active, s.active_count).map { a in
            NetActive(
                path: text(a.path), id: text(a.id), uuid: text(a.uuid), type: text(a.type),
                state: NetActive.State(rawValue: Int(a.state)) ?? .unknown, vpn: a.vpn != 0,
                connection: text(a.connection), specificObject: text(a.specific_object),
                device: text(a.device), isDefault: a.is_default != 0, ip4: text(a.ip4)
            )
        }
        state.connections = buffer(s.connections, s.connection_count).map { c in
            NetConnection(
                path: text(c.path), id: text(c.id), uuid: text(c.uuid), type: text(c.type),
                ssid: text(c.ssid), vpnService: text(c.vpn_service),
                autoconnect: c.autoconnect != 0, timestamp: c.timestamp,
                ip4: IPv4Settings(
                    method: text(c.ip4_method), addresses: list(c.ip4_addresses),
                    gateway: text(c.ip4_gateway), dns: list(c.ip4_dns),
                    ignoreAutoDNS: c.ip4_ignore_auto_dns != 0,
                    neverDefault: c.ip4_never_default != 0
                ),
                remote: text(c.remote)
            )
        }
        return state
    }

    static func copy(_ r: LavaNetSecretRequest) -> SecretPrompt {
        SecretPrompt(
            id: r.id, connection: text(r.connection), title: text(r.title),
            message: text(r.message),
            fields: buffer(r.fields, r.field_count).map { f in
                SecretPrompt.Field(
                    key: text(f.key), label: text(f.label), value: text(f.value),
                    secret: f.secret != 0, ask: f.ask != 0
                )
            }
        )
    }
}

/// `strings` as a `const char *const *` for the length of `body`.
private func withCStrings<R>(
    _ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R
) -> R {
    let copies = strings.map { strdup($0) }
    defer {
        for p in copies {
            // A typed password: zero it before it goes back to the heap.
            if let p { memset(p, 0, strlen(p)); free(p) }
        }
    }
    // Never an empty array: its buffer has no base address to hand over.
    let pointers = copies.isEmpty ? [nil] : copies.map { UnsafePointer<CChar>($0) }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
