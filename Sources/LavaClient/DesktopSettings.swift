import Foundation
import LavaIDL
import LavaUI
import NPRPC

/// The desktop's own preferences, for the app that exists to change them.
///
/// Everything here is a round trip to the compositor, because everything here
/// is the compositor's: which screens are on, what the keyboard is, how round
/// the windows are. A client cannot see any of it from inside its own window,
/// and the config file is not the answer either — a settings app that edited
/// `lava.conf` and sent SIGHUP would be typing on the user's behalf, with no
/// idea what the running session actually has.
///
/// **These throw, unlike the rest of `LavaClient`.** A window that would not
/// maximize is a bad frame worth logging and forgetting; a setting that did
/// not take is something the user asked for and has to be told about. In
/// particular a `SettingsWriteFailed` means the change *is* on screen and will
/// not be after a restart, which is a sentence a settings app should be able
/// to say.
///
/// Synchronous on purpose. Every call lands on the compositor's event loop and
/// answers in microseconds, and a settings panel that awaited them would need
/// an async story for every switch and slider in it to no visible benefit.
public enum DesktopSettings {
    /// Whether there is a compositor to ask. False in a windowed app, where
    /// none of this exists and the panel should say so rather than show
    /// controls that do nothing.
    public static var isAvailable: Bool { LavaClient.compositor != nil }

    // MARK: - Appearance

    /// The desktop's corner radius and the shadow it puts under a window.
    public static func appearance() throws -> Appearance {
        try call { try await $0.getAppearance() }
    }

    /// Sets both, immediately and for the next session.
    ///
    /// Immediately is the point: these are numbers the compositor reads per
    /// frame, so every window on screen takes the new ones before this call
    /// returns. That is what makes a slider here honest — the preview is the
    /// result.
    ///
    /// Values out of range are clamped by the compositor rather than refused;
    /// read `appearance()` back to see what was taken.
    public static func setAppearance(_ appearance: Appearance) throws {
        try call { try await $0.setAppearance(appearance: appearance) }
    }

    /// The system colour theme name (`dark` / `light` / `nebula`).
    public static func systemTheme() throws -> SystemTheme {
        try call { try await $0.getSystemTheme() }
    }

    /// Pushes the name; every subscribed Lava window retints.
    public static func setSystemTheme(_ theme: SystemTheme) throws {
        try call { try await $0.setSystemTheme(theme: theme) }
    }

    // MARK: - Keyboard

    public static func keyboard() throws -> KeyboardSettings {
        try call { try await $0.getKeyboard() }
    }

    /// Changes the keyboard, immediately and for the next session.
    ///
    /// wlroots hands the new keymap to every connected client as a side
    /// effect, so this reaches applications that are already running — which
    /// is the difference between this and editing the config file.
    public static func setKeyboard(_ settings: KeyboardSettings) throws {
        try call { try await $0.setKeyboard(settings: settings) }
    }

    /// Every layout and variant this machine's xkb offers.
    ///
    /// Flat: an entry whose `variant` is empty is a layout, and the rest are
    /// its variants. `layoutsByCode()` is the grouped form, which is what a
    /// picker actually wants.
    ///
    /// Slow enough to be worth caching — it is a parse of the whole xkb rules
    /// file, a few thousand entries — and constant for the life of the
    /// session, so it is cached here rather than in every caller.
    public static func keyboardLayouts() throws -> [KeyboardLayout] {
        if let cached = cachedLayouts { return cached }
        let layouts = try call { try await $0.listKeyboardLayouts() }
        cachedLayouts = layouts
        return layouts
    }

    /// The same list, grouped: each base layout with its variants after it,
    /// in the order xkb reports them.
    public static func layoutsByCode() throws -> [(code: String, name: String,
                                                   variants: [KeyboardLayout])] {
        var order: [String] = []
        var grouped: [String: [KeyboardLayout]] = [:]
        for layout in try keyboardLayouts() {
            if grouped[layout.code] == nil { order.append(layout.code) }
            grouped[layout.code, default: []].append(layout)
        }
        return order.map { code in
            let entries = grouped[code] ?? []
            // The base layout names the group; a rules file that somehow has
            // only variants for a code still gets a name rather than a blank.
            let name = entries.first(where: { $0.variant.isEmpty })?.description
                ?? entries.first?.description ?? code
            return (code, name, entries)
        }
    }

    /// Every shortcut the compositor takes before a client sees the key.
    ///
    /// Read-only, and that is the honest shape today: the bindings are
    /// compiled in. Listing them is still worth doing — a desktop whose
    /// shortcuts can only be found by reading its source has no shortcuts, as
    /// far as most people are concerned.
    public static func keyBindings() throws -> [KeyBinding] {
        try call { try await $0.listKeyBindings() }
    }

    // MARK: - Display

    public static func outputs() throws -> [OutputInfo] {
        try call { try await $0.listOutputs() }
    }

    /// Every mode a screen can run at, biggest first then fastest.
    public static func outputModes(_ name: String) throws -> [OutputMode] {
        try call { try await $0.listOutputModes(name: name) }
    }

    /// Reconfigures a screen, immediately and for the next session.
    ///
    /// The whole state rather than one field, because applying it is one
    /// commit: a screen asked to change mode and then position would be
    /// re-laid-out twice, through an arrangement nobody asked for.
    ///
    /// A mode the display refuses does not cost the session — the compositor
    /// falls back to the preferred one rather than leaving a screen showing
    /// nothing. Read `outputs()` back to find out whether what you asked for
    /// is what you got.
    public static func setOutput(_ request: OutputRequest) throws {
        try call { try await $0.setOutput(request: request) }
    }

    /// A request pre-filled from what a screen is doing now, so a caller
    /// changing one field does not have to restate the other six.
    public static func request(from output: OutputInfo) -> OutputRequest {
        OutputRequest(
            name: output.name,
            enabled: output.enabled,
            width: output.width,
            height: output.height,
            refresh: output.refresh,
            scale: output.scale,
            x: output.x,
            y: output.y,
            transform: output.transform
        )
    }

    // MARK: - Plumbing

    nonisolated(unsafe) private static var cachedLayouts: [KeyboardLayout]?

    private static func call<T>(
        _ body: @escaping @Sendable (Compositor) async throws -> T
    ) throws -> T {
        guard let compositor = LavaClient.compositor else {
            throw SettingsError.noCompositor
        }
        // Longer than the default two seconds: `ListKeyboardLayouts` parses
        // the xkb rules on the compositor's own loop, and a cold page cache
        // makes that the slowest call in this interface by a wide margin.
        return try blockingCall(timeout: 10) { try await body(compositor) }
    }
}

/// What a settings call can fail with that is worth showing a user.
public enum SettingsError: Error, CustomStringConvertible {
    case noCompositor

    public var description: String {
        switch self {
        case .noCompositor:
            return "not running under the Lava compositor"
        }
    }
}
