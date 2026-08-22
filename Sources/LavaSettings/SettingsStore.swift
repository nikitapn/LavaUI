#if canImport(LavaIDL)
import Foundation
import LavaClient
import LavaIDL
import LavaUI
import Observation

/// Which page is showing.
enum SettingsSection: String, CaseIterable, Sendable {
    case appearance
    case background
    case keyboard
    case display

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .background: return "Background"
        case .keyboard: return "Keyboard"
        case .display: return "Display"
        }
    }

    /// A one-line word about what lives on the page, under its name in the
    /// sidebar. Cheap, and it turns four nouns into four answers.
    var subtitle: String {
        switch self {
        case .appearance: return "Colours, corners, shadows"
        case .background: return "Picture or colour"
        case .keyboard: return "Layout, repeat, shortcuts"
        case .display: return "Screens, arrangement, primary"
        }
    }
}

/// Everything the panel shows, and the only thing that talks to the compositor.
///
/// Two rules hold this together, and both come from what a settings app is.
///
/// **The compositor is the truth.** Nothing here is a preference this process
/// owns; every field is a copy of something the desktop already has, read once
/// and written back on change. So a setter pushes first and updates the local
/// copy from what came back — a value the compositor clamped shows up as the
/// clamped value, and the slider snaps to what actually happened rather than
/// to what was asked for.
///
/// **Failures are shown, not swallowed.** `status` is the one line at the
/// bottom of the window, and the case that matters is a change that applied
/// and did not save: the user can see it worked, so silently losing it at the
/// next login is the worst of the available outcomes.
@Observable
final class SettingsStore {
    var section: SettingsSection = .appearance

    /// False in a windowed build, or if the compositor went away. The panel
    /// says so rather than showing controls that quietly do nothing.
    var connected = false
    var status = ""
    var statusIsError = false

    // MARK: Appearance

    var cornerRadius: Float = 0
    var shadowBlur: Float = 0
    var shadowOpacity: Float = 0.35
    var shadowOffsetY: Float = 4
    /// A `Theme.builtIns` name. What Lava windows that wear
    /// `Theme.current` will paint.
    var themeName = "dark"

    // MARK: Background

    /// `solid` or `picture`.
    var backgroundMode = "solid"
    /// `0x00RRGGBB`. Meaningful in both modes — in `picture` it is what shows
    /// through the letterbox, so the colour controls stay live there.
    var backgroundColor: UInt32 = 0x0e_13_1f
    var picturePath = ""
    /// `fill`, `fit`, `stretch` or `center`.
    var backgroundFit = "fill"
    /// What is typed into the hex field, which is not the same thing as the
    /// colour: half-typed hex is not a colour yet, and echoing the applied
    /// value back into the field would fight the person typing it.
    var colorText = ""

    /// Pictures found in the usual places, offered so the common case does not
    /// need a path typed by hand. Not a file browser and not trying to be —
    /// there is a text field beside it for everything else.
    var pictures: [String] = []
    var picturesLoaded = false

    // MARK: Keyboard

    var layout = ""
    var variant = ""
    var options = ""
    /// Not editable here, and carried anyway. The compositor takes the whole
    /// keyboard in one call, so sending an empty `model` would *clear* a model
    /// the user set by hand in `lava.conf` — a settings app quietly deleting
    /// the settings it does not show.
    var model = ""
    var rules = ""
    var repeatRate: Float = 25
    var repeatDelay: Float = 600
    /// Compositor shortcut modifier: `"alt"` or `"super"`. Same vocabulary
    /// as `lava.conf`'s `mod-key` and the IDL field.
    var modKey = "alt"
    /// Filter over the layout list, which is a few hundred entries long on a
    /// normal install and unusable without one.
    var layoutFilter = ""
    var layoutGroups: [LayoutGroup] = []
    var layoutsLoaded = false
    var bindings: [KeyBinding] = []

    struct LayoutGroup: Identifiable, Sendable {
        var code: String
        var name: String
        var entries: [KeyboardLayout]
        var id: String { code }
    }

    // MARK: Display

    var outputs: [OutputInfo] = []
    var selectedOutput = ""
    var modes: [OutputMode] = []
    /// `"extend"` or `"mirror"`.
    var arrangement = "extend"

    var currentOutput: OutputInfo? {
        outputs.first { $0.name == selectedOutput } ?? outputs.first
    }

    // MARK: - Loading

    /// The cheap half, at startup: three calls that answer immediately.
    ///
    /// The layout catalogue is deliberately not here — it is a parse of the
    /// whole xkb rules file on the compositor's own loop, and paying for it
    /// before the first frame would make the window slow to appear in service
    /// of a page the user may never open.
    func loadCore() {
        guard DesktopSettings.isAvailable else {
            connected = false
            note("Not running under the Lava compositor — nothing to change here.",
                 isError: true)
            return
        }
        connected = true

        do {
            let appearance = try DesktopSettings.appearance()
            apply(appearance)

            if let theme = try? DesktopSettings.systemTheme() {
                themeName = theme.name
            }

            if let wallpaper = try? DesktopSettings.wallpaper() {
                apply(wallpaper)
            }

            let keyboard = try DesktopSettings.keyboard()
            apply(keyboard)

            bindings = try DesktopSettings.keyBindings()
            if let mode = try? DesktopSettings.arrangement() {
                arrangement = mode
            }
            reloadOutputs()
        } catch {
            note("Could not read the desktop's settings: \(error)", isError: true)
        }
    }

    /// The layout catalogue, the first time the Keyboard page is opened.
    func ensureLayouts() {
        guard connected, !layoutsLoaded else { return }
        layoutsLoaded = true
        do {
            layoutGroups = try DesktopSettings.layoutsByCode().map {
                LayoutGroup(code: $0.code, name: $0.name, entries: $0.variants)
            }
        } catch {
            note("Could not read the keyboard layouts: \(error)", isError: true)
        }
    }

    /// Scans the usual picture directories, the first time the page is opened.
    ///
    /// Done here rather than at startup for the same reason as the keyboard
    /// layouts: it touches the disk, and a user who never opens this page
    /// should not wait for it behind their first frame.
    func ensurePictures() {
        guard !picturesLoaded else { return }
        picturesLoaded = true

        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent("Pictures"),
            home.appendingPathComponent("Pictures/Wallpapers"),
            home.appendingPathComponent("Wallpapers"),
            URL(fileURLWithPath: "/usr/share/backgrounds"),
            URL(fileURLWithPath: "/usr/share/wallpapers"),
        ]
        // What the compositor's decoder actually reads. Listing an SVG here
        // would offer the user a file that is guaranteed to be refused.
        let extensions: Set<String> = ["png", "jpg", "jpeg", "bmp", "gif", "tga"]

        var found: [String] = []
        var seen: Set<String> = []
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil
            ) else { continue }
            for entry in entries.sorted(by: { $0.path < $1.path }) {
                guard extensions.contains(entry.pathExtension.lowercased()),
                      seen.insert(entry.path).inserted
                else { continue }
                found.append(entry.path)
            }
        }
        pictures = found
    }

    // MARK: - Writing the background

    /// Pushes the background and takes back what the compositor kept.
    ///
    /// The failure here is the interesting one, and it is why this does not
    /// look like `pushAppearance`. A picture that will not decode changes
    /// nothing at all, so the local copy is reloaded from the compositor
    /// rather than left holding the path that was refused — otherwise the page
    /// would keep showing a selection the desktop does not have.
    func pushWallpaper() {
        guard connected else { return }
        let wanted = Wallpaper(
            mode: backgroundMode,
            color: backgroundColor,
            path: picturePath,
            fit: backgroundFit
        )
        do {
            try DesktopSettings.setWallpaper(wanted)
            clearStatus()
            if let taken = try? DesktopSettings.wallpaper() { apply(taken) }
        } catch {
            report(error)
            if let actual = try? DesktopSettings.wallpaper() { apply(actual) }
        }
    }

    func setBackgroundMode(_ mode: String) {
        backgroundMode = mode
        pushWallpaper()
    }

    func setBackgroundFit(_ fit: String) {
        backgroundFit = fit
        pushWallpaper()
    }

    func setBackgroundColor(_ color: UInt32) {
        backgroundColor = color & 0x00_ff_ff_ff
        pushWallpaper()
    }

    /// Picks a picture, switching to `picture` mode in the same push.
    ///
    /// One call rather than two: setting a path and then setting the mode
    /// would put a picture on screen in two steps, and the first of them is a
    /// state nobody asked for.
    func setPicture(_ path: String) {
        picturePath = path
        backgroundMode = path.isEmpty ? "solid" : "picture"
        pushWallpaper()
    }

    /// Applies whatever is in the hex field, if it is a colour yet.
    func commitColorText() {
        guard let parsed = Self.parseHex(colorText) else {
            note("“\(colorText)” is not a colour — try something like #1e2430.",
                 isError: true)
            return
        }
        colorText = ""
        setBackgroundColor(parsed)
    }

    /// `#rrggbb`, `rrggbb`, or the three-digit short form. Nil if it is not
    /// one of those, which includes the half-typed states.
    static func parseHex(_ text: String) -> UInt32? {
        var digits = text.trimmingCharacters(in: .whitespaces).lowercased()
        if digits.hasPrefix("#") { digits.removeFirst() }
        else if digits.hasPrefix("0x") { digits.removeFirst(2) }
        if digits.count == 3 {
            // `abc` is `aabbcc`: each digit is a nibble repeated, which is what
            // makes `#fff` white rather than a very dark blue.
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            return nil
        }
        return value & 0x00_ff_ff_ff
    }

    func reloadOutputs() {
        guard connected else { return }
        do {
            outputs = try DesktopSettings.outputs()
            if outputs.first(where: { $0.name == selectedOutput }) == nil {
                selectedOutput = outputs.first?.name ?? ""
            }
            reloadModes()
        } catch {
            note("Could not read the screens: \(error)", isError: true)
        }
    }

    /// Extend or mirror, then reloads so the listed positions match.
    func setArrangement(_ mode: String) {
        guard connected else { return }
        do {
            try DesktopSettings.setArrangement(mode)
            arrangement = mode == "mirror" ? "mirror" : "extend"
            clearStatus()
        } catch {
            report(error)
        }
        if let taken = try? DesktopSettings.arrangement() {
            arrangement = taken
        }
        reloadOutputs()
    }

    /// Moves the panel onto this screen and remembers the name.
    func setPrimary(_ name: String) {
        guard connected else { return }
        do {
            try DesktopSettings.setPrimaryOutput(name)
            clearStatus()
        } catch {
            report(error)
        }
        reloadOutputs()
    }

    func reloadModes() {
        guard connected, !selectedOutput.isEmpty else {
            modes = []
            return
        }
        do {
            modes = try DesktopSettings.outputModes(selectedOutput)
        } catch {
            modes = []
            note("Could not read the modes for \(selectedOutput): \(error)",
                 isError: true)
        }
    }

    // MARK: - Writing

    /// Pushes the appearance and takes back whatever the compositor kept.
    ///
    /// Reading it back is not paranoia: the values are clamped on the far side,
    /// so a slider dragged past the limit would otherwise sit somewhere the
    /// desktop is not.
    func pushAppearance() {
        guard connected else { return }
        let wanted = Appearance(
            cornerRadius: cornerRadius,
            shadowBlur: shadowBlur,
            shadowOpacity: shadowOpacity,
            shadowOffsetY: shadowOffsetY
        )
        do {
            try DesktopSettings.setAppearance(wanted)
            clearStatus()
            if let taken = try? DesktopSettings.appearance() { apply(taken) }
        } catch {
            report(error)
        }
    }

    func pushSystemTheme() {
        guard connected else { return }
        do {
            try DesktopSettings.setSystemTheme(
                SystemTheme(serial: 0, name: themeName)
            )
            clearStatus()
            if let taken = try? DesktopSettings.systemTheme() {
                themeName = taken.name
            }
        } catch {
            report(error)
        }
    }

    func setThemeName(_ name: String) {
        themeName = name
        pushSystemTheme()
    }

    func pushKeyboard() {
        guard connected else { return }
        let wanted = KeyboardSettings(
            layout: layout,
            variant: variant,
            options: options,
            model: model,
            rules: rules,
            repeatRate: Int32(repeatRate.rounded()),
            repeatDelay: Int32(repeatDelay.rounded()),
            modKey: modKey
        )
        do {
            try DesktopSettings.setKeyboard(wanted)
            clearStatus()
            if let taken = try? DesktopSettings.keyboard() { apply(taken) }
            // Bindings list the live mod name; refresh so the table matches.
            if let listed = try? DesktopSettings.keyBindings() {
                bindings = listed
            }
        } catch {
            report(error)
        }
    }

    /// Switches the compositor shortcut modifier and pushes it.
    func setModKey(_ value: String) {
        modKey = value == "super" ? "super" : "alt"
        pushKeyboard()
    }

    /// One xkb group: a `layout` slot and the matching `variant` slot.
    ///
    /// `us,ru` with an empty variant is two groups; `us,ru` with `dvorak,`
    /// is US-Dvorak then default Russian. The picker used to write a single
    /// code, which is why `grp:…` appeared to do nothing — there was only
    /// one group to toggle.
    struct InputSource: Equatable, Identifiable {
        var code: String
        var variant: String
        var id: String { variant.isEmpty ? code : "\(code):\(variant)" }
    }

    var sources: [InputSource] {
        Self.parseSources(layout: layout, variant: variant)
    }

    func containsSource(code: String, variant: String) -> Bool {
        sources.contains { $0.code == code && $0.variant == variant }
    }

    func toggleSource(code: String, variant: String) {
        var next = sources
        if let idx = next.firstIndex(where: { $0.code == code && $0.variant == variant }) {
            guard next.count > 1 else { return }
            next.remove(at: idx)
        } else {
            next.append(InputSource(code: code, variant: variant))
        }
        applySources(next)
        pushKeyboard()
    }

    func removeSource(id: String) {
        var next = sources
        next.removeAll { $0.id == id }
        guard !next.isEmpty else { return }
        applySources(next)
        pushKeyboard()
    }

    /// The `grp:` option, if any. Switching keys only work with two layouts.
    var layoutSwitch: String {
        optionParts().first { $0.hasPrefix("grp:") } ?? ""
    }

    func setLayoutSwitch(_ option: String) {
        var parts = optionParts().filter { !$0.hasPrefix("grp:") }
        let trimmed = option.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { parts.append(trimmed) }
        options = parts.joined(separator: ", ")
        pushKeyboard()
    }

    func sourceLabel(_ source: InputSource) -> String {
        for group in layoutGroups {
            for entry in group.entries
            where entry.code == source.code && entry.variant == source.variant {
                return entry.description
            }
        }
        return source.variant.isEmpty
            ? source.code
            : "\(source.code) · \(source.variant)"
    }

    private func optionParts() -> [String] {
        options
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func applySources(_ sources: [InputSource]) {
        layout = sources.map(\.code).joined(separator: ",")
        if sources.allSatisfy(\.variant.isEmpty) {
            variant = ""
        } else {
            variant = sources.map(\.variant).joined(separator: ",")
        }
    }

    static func parseSources(layout: String, variant: String) -> [InputSource] {
        let codes = layout
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !codes.isEmpty else { return [] }
        let variants = variant
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return codes.enumerated().map { index, code in
            let slot = index < variants.count ? variants[index] : ""
            return InputSource(code: String(code), variant: slot)
        }
    }

    /// Applies one change to the selected screen, leaving its other fields as
    /// they are — `edit` is handed the screen's current state to modify.
    func pushOutput(_ edit: (inout OutputRequest) -> Void) {
        guard connected, let output = currentOutput else { return }
        var request = DesktopSettings.request(from: output)
        edit(&request)
        do {
            try DesktopSettings.setOutput(request)
            clearStatus()
        } catch {
            report(error)
        }
        // Either way: a mode the display refused leaves the screen on its
        // preferred one, and the list has to show what happened rather than
        // what was asked for.
        reloadOutputs()
    }

    // MARK: - Plumbing

    private func apply(_ appearance: Appearance) {
        cornerRadius = appearance.cornerRadius
        shadowBlur = appearance.shadowBlur
        shadowOpacity = appearance.shadowOpacity
        shadowOffsetY = appearance.shadowOffsetY
    }

    private func apply(_ wallpaper: Wallpaper) {
        backgroundMode = wallpaper.mode == "picture" ? "picture" : "solid"
        backgroundColor = wallpaper.color & 0x00_ff_ff_ff
        picturePath = wallpaper.path
        backgroundFit = wallpaper.fit.isEmpty ? "fill" : wallpaper.fit
    }

    private func apply(_ keyboard: KeyboardSettings) {
        layout = keyboard.layout
        variant = keyboard.variant
        options = keyboard.options
        model = keyboard.model
        rules = keyboard.rules
        repeatRate = Float(keyboard.repeatRate)
        repeatDelay = Float(keyboard.repeatDelay)
        modKey = keyboard.modKey == "super" ? "super" : "alt"
    }

    private func report(_ error: Error) {
        // Two failures worth their own wording, and they are opposites. The
        // first says the change is on screen and will not survive a restart;
        // the second says nothing happened and the old background is intact.
        // Neither is something looking at the desktop would reveal, and a
        // panel that showed the same sentence for both would be wrong half
        // the time.
        if let failure = error as? SettingsWriteFailed {
            note("Applied, but not saved to \(failure.path): \(failure.reason)",
                 isError: true)
        } else if let failure = error as? WallpaperUnreadable {
            note("Could not read \(failure.path): \(failure.reason). "
                 + "The background is unchanged.",
                 isError: true)
        } else {
            note("\(error)", isError: true)
        }
    }

    private func note(_ message: String, isError: Bool) {
        status = message
        statusIsError = isError
    }

    private func clearStatus() {
        if !status.isEmpty { status = "" }
        statusIsError = false
    }
}
#endif
