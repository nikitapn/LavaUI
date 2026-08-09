#if canImport(LavaIDL)
import Foundation
import LavaClient
import LavaIDL
import LavaUI
import Observation

/// Which page is showing.
enum SettingsSection: String, CaseIterable, Sendable {
    case appearance
    case keyboard
    case display

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .keyboard: return "Keyboard"
        case .display: return "Display"
        }
    }

    /// A one-line word about what lives on the page, under its name in the
    /// sidebar. Cheap, and it turns three nouns into three answers.
    var subtitle: String {
        switch self {
        case .appearance: return "Corners and shadows"
        case .keyboard: return "Layout, repeat, shortcuts"
        case .display: return "Screens and modes"
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

            let keyboard = try DesktopSettings.keyboard()
            apply(keyboard)

            bindings = try DesktopSettings.keyBindings()
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

    func pushKeyboard() {
        guard connected else { return }
        let wanted = KeyboardSettings(
            layout: layout,
            variant: variant,
            options: options,
            model: model,
            rules: rules,
            repeatRate: Int32(repeatRate.rounded()),
            repeatDelay: Int32(repeatDelay.rounded())
        )
        do {
            try DesktopSettings.setKeyboard(wanted)
            clearStatus()
            if let taken = try? DesktopSettings.keyboard() { apply(taken) }
        } catch {
            report(error)
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

    private func apply(_ keyboard: KeyboardSettings) {
        layout = keyboard.layout
        variant = keyboard.variant
        options = keyboard.options
        model = keyboard.model
        rules = keyboard.rules
        repeatRate = Float(keyboard.repeatRate)
        repeatDelay = Float(keyboard.repeatDelay)
    }

    private func report(_ error: Error) {
        // The one failure worth its own wording: the change is on screen and
        // will not be after a restart, which no amount of looking at the
        // desktop would reveal.
        if let failure = error as? SettingsWriteFailed {
            note("Applied, but not saved to \(failure.path): \(failure.reason)",
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
