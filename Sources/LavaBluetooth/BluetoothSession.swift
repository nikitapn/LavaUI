import CLavaBluetooth
import Foundation
import LavaBluetoothCore
import LavaUI
import Observation

/// Live view of BlueZ, and the panel's pairing agent.
///
/// `CLavaBluetooth` runs GDBus on a thread of its own; every snapshot is
/// copied into Swift values there and hopped onto `MainQueue` before touching
/// `@Observable` properties, as `NetworkSession` does.
@Observable
public final class BluetoothSession: @unchecked Sendable {
    public private(set) var state = BluetoothState()
    /// What the agent is waiting on the user for, oldest first.
    public private(set) var prompts: [PairingPrompt] = []
    /// The last command that failed, in words, and when — the window shows
    /// it for a while rather than forever.
    public private(set) var lastError: (what: String, message: String, at: Date)?

    /// A new prompt, for the panel to put a window up for.
    @ObservationIgnored public var onPrompt: ((PairingPrompt) -> Void)?
    /// BlueZ no longer needs prompt `id`.
    @ObservationIgnored public var onPromptGone: ((UInt64) -> Void)?
    /// The first snapshot has arrived — `state` is BlueZ's, not the empty
    /// default. Settings opens its page on this.
    @ObservationIgnored public private(set) var isReady = false
    @ObservationIgnored public var onReady: (() -> Void)?

    private var handle: OpaquePointer?
    private var box: Unmanaged<BluetoothSession>?
    /// The search pane is open.
    @ObservationIgnored private var wantsSearch = false
    @ObservationIgnored private var reportedPowered = false

    public struct PairingPrompt: Identifiable, Equatable, Sendable {
        public var id: UInt64
        public var ask: BluetoothRows.Ask
        public var device: String
        public var name: String

        public var text: PairingText { BluetoothRows.text(ask, device: name) }
        /// Typed into: a PIN or a passkey.
        public var wantsInput: Bool { ask == .pin || ask == .passkey }
        /// Shown until pairing ends; the only answer is to stop.
        public var isShown: Bool {
            switch ask {
            case .showPin, .showPasskey: return true
            default: return false
            }
        }
    }

    /// `agent: false` watches and changes BlueZ without answering pairing
    /// requests: one default agent is the rule, and the panel is it.
    public init(agent: Bool = true) {
        let unmanaged = Unmanaged.passRetained(self)
        box = unmanaged
        var callbacks = LavaBtCallbacks()
        callbacks.snapshot = { user, snap in
            guard let user, let snap else { return }
            let session = Unmanaged<BluetoothSession>.fromOpaque(user).takeUnretainedValue()
            let state = BluetoothSession.copy(snap.pointee)
            MainQueue.async { session.adopt(state) }
        }
        callbacks.request = { user, request in
            guard let user, let request else { return }
            let session = Unmanaged<BluetoothSession>.fromOpaque(user).takeUnretainedValue()
            guard let prompt = BluetoothSession.copy(request.pointee) else { return }
            MainQueue.async { session.add(prompt) }
        }
        callbacks.request_gone = { user, id in
            guard let user else { return }
            let session = Unmanaged<BluetoothSession>.fromOpaque(user).takeUnretainedValue()
            MainQueue.async { session.drop(id, notify: true) }
        }
        callbacks.error = { user, what, name, error, message in
            guard let user else { return }
            let session = Unmanaged<BluetoothSession>.fromOpaque(user).takeUnretainedValue()
            let what = what.map { String(cString: $0) } ?? ""
            let name = name.map { String(cString: $0) } ?? ""
            let error = error.map { String(cString: $0) } ?? ""
            let message = message.map { String(cString: $0) } ?? ""
            let words = BluetoothRows.explain(error: error, message: message)
            MainQueue.async {
                session.lastError = (name.isEmpty ? what : "\(what) \(name)", words, Date())
                ViewInvalidation.markNeedsRedraw()
            }
        }
        handle = lava_bt_create(&callbacks, unmanaged.toOpaque(), agent ? 1 : 0)
        if handle == nil {
            unmanaged.release()
            box = nil
        }
    }

    deinit {
        if let handle { lava_bt_destroy(handle) }
        box?.release()
    }

    private func adopt(_ next: BluetoothState) {
        if !isReady {
            isReady = true
            do { onReady?(); onReady = nil }
        }
        // What BlueZ said last, not `state`: a toggle writes its answer
        // there before BlueZ has given it, and the snapshot that confirms it
        // then compares equal.
        let wasPowered = reportedPowered
        reportedPowered = next.adapter?.powered == true
        // Switching the radio off ends a search; switched back on with the
        // pane still open, it starts again.
        if wantsSearch, !wasPowered, reportedPowered, next.adapter?.discovering == false {
            setSearching(true)
        }
        guard next != state else { return }
        state = next
        // Paint closures are not observation-tracked; the strip glyph is one.
        ViewInvalidation.markNeedsRedraw()
    }

    private func add(_ prompt: PairingPrompt) {
        // A passkey being typed on a keyboard comes again per digit.
        if let i = prompts.firstIndex(where: { $0.id == prompt.id }) {
            prompts[i] = prompt
            return
        }
        prompts.append(prompt)
        onPrompt?(prompt)
    }

    private func drop(_ id: UInt64, notify: Bool) {
        guard prompts.contains(where: { $0.id == id }) else { return }
        prompts.removeAll { $0.id == id }
        if notify { onPromptGone?(id) }
    }

    // MARK: - Reading

    public var known: [BtDevice] { BluetoothRows.known(state) }
    public var discovered: [BtDevice] { BluetoothRows.discovered(state) }
    public var status: BluetoothStatus { BluetoothRows.status(state) }
    public var summary: String { BluetoothRows.summary(state) }

    public func prompt(_ id: UInt64) -> PairingPrompt? { prompts.first { $0.id == id } }

    /// The last error, if it is recent enough to still be news.
    public var recentError: String? {
        guard let lastError, Date().timeIntervalSince(lastError.at) < 15 else { return nil }
        return "\(lastError.what): \(lastError.message)"
    }

    // MARK: - Commands

    public func setPowered(_ on: Bool) {
        guard let handle, let adapter = state.adapter else { return }
        lastError = nil
        if let i = state.adapters.firstIndex(where: { $0.path == adapter.path }) {
            state.adapters[i].powered = on
        }
        lava_bt_set_powered(handle, adapter.path, on ? 1 : 0)
    }

    public var poweredBinding: Binding<Bool> {
        Binding(get: { self.state.adapter?.powered ?? false }, set: { self.setPowered($0) })
    }

    /// Looks for devices while `on`. The pane that lists them turns it on
    /// when it opens and off when it closes; BlueZ stops it anyway if this
    /// process goes.
    public func setSearching(_ on: Bool) {
        wantsSearch = on
        guard let handle, let adapter = state.adapter else { return }
        lava_bt_set_discovering(handle, adapter.path, on ? 1 : 0)
    }

    /// Pairs, trusts and connects a found device.
    public func pair(_ device: BtDevice) {
        guard let handle else { return }
        lastError = nil
        lava_bt_pair(handle, device.path)
    }

    public func connect(_ device: BtDevice) {
        guard let handle else { return }
        lastError = nil
        lava_bt_connect(handle, device.path)
    }

    public func disconnect(_ device: BtDevice) {
        guard let handle else { return }
        lava_bt_disconnect(handle, device.path)
    }

    /// The click on a known device: whichever of the two it is not doing.
    public func toggle(_ device: BtDevice) {
        guard device.busy == .idle else { return }
        if device.connected { disconnect(device) } else { connect(device) }
    }

    public func forget(_ device: BtDevice) {
        guard let handle else { return }
        lava_bt_forget(handle, device.path)
    }

    public func setTrusted(_ device: BtDevice, _ on: Bool) {
        guard let handle else { return }
        // Written ahead of BlueZ's answer, so a switch does not slide back
        // for the snapshot's 50 ms; a refusal shows up as the error.
        if let i = state.devices.firstIndex(where: { $0.path == device.path }) {
            state.devices[i].trusted = on
        }
        lava_bt_set_trusted(handle, device.path, on ? 1 : 0)
    }

    public func setBlocked(_ device: BtDevice, _ on: Bool) {
        guard let handle else { return }
        lastError = nil
        if let i = state.devices.firstIndex(where: { $0.path == device.path }) {
            state.devices[i].blocked = on
        }
        lava_bt_set_blocked(handle, device.path, on ? 1 : 0)
    }

    public func setDiscoverable(_ on: Bool) {
        guard let handle, let adapter = state.adapter else { return }
        lastError = nil
        if let i = state.adapters.firstIndex(where: { $0.path == adapter.path }) {
            state.adapters[i].discoverable = on
        }
        lava_bt_set_discoverable(handle, adapter.path, on ? 1 : 0)
    }

    /// Renames a device, or the adapter when `path` is its; "" goes back to
    /// the name it gave itself.
    public func rename(_ path: String, to name: String) {
        guard let handle else { return }
        lastError = nil
        lava_bt_set_alias(handle, path, name)
    }

    /// Yes to prompt `id`, with the PIN or passkey typed when it asked for
    /// one.
    public func accept(_ id: UInt64, text: String? = nil) {
        guard let handle else { return }
        drop(id, notify: false)
        if let text {
            text.withCString { lava_bt_agent_reply(handle, id, 1, $0) }
        } else {
            lava_bt_agent_reply(handle, id, 1, nil)
        }
    }

    /// No to prompt `id` — or, on a code being shown, stop pairing.
    public func decline(_ id: UInt64) {
        guard let handle else { return }
        drop(id, notify: false)
        lava_bt_agent_reply(handle, id, 0, nil)
    }

    // MARK: - Tests

    /// Calls the agent's `method` through the bus, as bluetoothd would; see
    /// `lava_bt_test_call_agent`. `done` runs on the main queue.
    func testCallAgent(
        _ method: String, device: String, number: UInt32 = 0, text: String = "",
        done: @escaping @Sendable (String) -> Void
    ) {
        guard let handle else { return done("error no session") }
        let box = Unmanaged.passRetained(TestReply(done)).toOpaque()
        lava_bt_test_call_agent(handle, method, device, number, text, { user, result in
            guard let user else { return }
            let reply = Unmanaged<TestReply>.fromOpaque(user).takeRetainedValue()
            let text = result.map { String(cString: $0) } ?? ""
            MainQueue.async { reply.done(text) }
        }, box)
    }

    private final class TestReply: @unchecked Sendable {
        let done: @Sendable (String) -> Void
        init(_ done: @escaping @Sendable (String) -> Void) { self.done = done }
    }

    // MARK: - Copying out of C

    private static func text(_ p: UnsafePointer<CChar>?) -> String {
        p.map { String(cString: $0) } ?? ""
    }

    private static func buffer<T>(_ base: UnsafePointer<T>?, _ count: Int) -> UnsafeBufferPointer<T> {
        guard let base, count > 0 else { return UnsafeBufferPointer(start: nil, count: 0) }
        return UnsafeBufferPointer(start: base, count: count)
    }

    static func copy(_ s: LavaBtSnapshot) -> BluetoothState {
        var state = BluetoothState()
        state.running = s.running != 0
        state.agent = s.agent != 0
        state.adapters = buffer(s.adapters, s.adapter_count).map { a in
            BtAdapter(
                path: text(a.path), address: text(a.address), name: text(a.name),
                powered: a.powered != 0, powerState: text(a.power_state),
                discovering: a.discovering != 0, discoverable: a.discoverable != 0,
                discoverableTimeout: a.discoverable_timeout, pairable: a.pairable != 0
            )
        }
        state.devices = buffer(s.devices, s.device_count).map { d in
            BtDevice(
                path: text(d.path), adapter: text(d.adapter), address: text(d.address),
                name: text(d.name), hasName: d.has_name != 0, ownName: text(d.own_name),
                icon: text(d.icon),
                deviceClass: d.device_class, appearance: d.appearance, paired: d.paired != 0,
                trusted: d.trusted != 0, blocked: d.blocked != 0, connected: d.connected != 0,
                battery: d.battery >= 0 ? Int(d.battery) : nil,
                rssi: d.rssi != 0 ? Int(d.rssi) : nil,
                busy: BtDevice.Busy(rawValue: Int(d.busy)) ?? .idle
            )
        }
        // Paths are BlueZ's order of discovery; sort once so equal trees
        // compare equal.
        state.devices.sort { $0.path < $1.path }
        return state
    }

    static func copy(_ r: LavaBtRequest) -> PairingPrompt? {
        let ask: BluetoothRows.Ask
        switch Int32(r.kind) {
        case Int32(LAVA_BT_ASK_PIN): ask = .pin
        case Int32(LAVA_BT_ASK_PASSKEY): ask = .passkey
        case Int32(LAVA_BT_SHOW_PIN): ask = .showPin(text(r.pin))
        case Int32(LAVA_BT_SHOW_PASSKEY): ask = .showPasskey(r.passkey, entered: Int(r.entered))
        case Int32(LAVA_BT_CONFIRM): ask = .confirm(r.passkey)
        case Int32(LAVA_BT_AUTHORIZE): ask = .authorize
        case Int32(LAVA_BT_AUTHORIZE_SERVICE): ask = .authorizeService(text(r.service))
        default: return nil
        }
        return PairingPrompt(id: r.id, ask: ask, device: text(r.device), name: text(r.name))
    }
}
