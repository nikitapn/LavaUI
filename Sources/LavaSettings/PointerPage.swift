#if canImport(LavaIDL)
import Foundation
import LavaClient
import LavaIDL
import LavaUI

// ─── Mouse & Touchpad ───────────────────────────────────────────────────────

/// `[mouse]`, `[touchpad]` and how a scroll settles.
///
/// Two halves with the same settings in both because people want them
/// different — a touchpad that scrolls like a phone beside a wheel that
/// scrolls the old way is the usual laptop-on-a-desk — and libinput keeps
/// them per device anyway. Each half shows whether one is plugged in, and
/// applies to one plugged in later whether or not it is.
struct PointerPage: View {
    let store: SettingsStore

    static let accels: [(value: String, title: String, detail: String)] = [
        ("adaptive", "Adaptive", "Faster hand, further pointer. Right for most people."),
        ("flat", "Flat", "The same distance however fast: games, trackballs, drawing."),
    ]
    static let scrolls: [(value: String, title: String, detail: String)] = [
        ("two-finger", "Two fingers", "Drag two fingers anywhere on the pad."),
        ("edge", "Edge", "Drag one finger down the right-hand edge."),
        ("off", "Off", ""),
    ]
    static let clicks: [(value: String, title: String, detail: String)] = [
        ("", "The touchpad's own", "Whatever the pad was made for."),
        ("areas", "Bottom corners", "Pressing the bottom right of the pad is a right click."),
        ("fingers", "Number of fingers", "One finger left, two right, three middle."),
    ]

    var body: some View {
        let p = store.pointer
        return VStack(spacing: 18) {
            SettingGroup("Mouse") {
                if !p.hasMouse {
                    absent("No mouse is connected now. These apply to one as soon as it is.")
                }
                SettingRow("Pointer speed", "How far the pointer goes for a move of the hand.") {
                    Slider(
                        value: speed(\.mouseSpeed), in: -1...1, step: 0.05,
                        format: Self.speedText
                    )
                }
                SettingRow("Acceleration", "") {
                    picker(Self.accels, selected: p.mouseAccel) { store.setPointer(\.mouseAccel, $0) }
                }
                SettingRow(
                    "Natural scrolling",
                    "The wheel moves the page rather than the view, as a finger on a "
                    + "phone does: rolling it towards you pulls the page down."
                ) {
                    toggle(p.mouseNaturalScroll) { store.setPointer(\.mouseNaturalScroll, $0) }
                }
            }

            SettingGroup("Touchpad") {
                if !p.hasTouchpad {
                    absent("No touchpad is connected now. These apply to one as soon as it is.")
                }
                SettingRow("Pointer speed", "How far the pointer goes for a move of the finger.") {
                    Slider(
                        value: speed(\.touchpadSpeed), in: -1...1, step: 0.05,
                        format: Self.speedText
                    )
                }
                SettingRow("Tap to click", "A light tap is a click, two fingers a right click.") {
                    toggle(p.tapToClick) { store.setPointer(\.tapToClick, $0) }
                }
                SettingRow(
                    "Natural scrolling",
                    "The page follows the fingers, as on a phone: moving them up moves "
                    + "the page up."
                ) {
                    toggle(p.touchpadNaturalScroll) { store.setPointer(\.touchpadNaturalScroll, $0) }
                }
                SettingRow("Scroll with", "") {
                    picker(Self.scrolls, selected: p.touchpadScroll) {
                        store.setPointer(\.touchpadScroll, $0)
                    }
                }
                SettingRow("Right click", "On a pad that is pressed down to click.") {
                    picker(Self.clicks, selected: p.touchpadClick) {
                        store.setPointer(\.touchpadClick, $0)
                    }
                }
                SettingRow(
                    "Ignore while typing",
                    "The pad does nothing for a moment after a key, so a palm does not "
                    + "move the pointer mid-sentence."
                ) {
                    toggle(p.disableWhileTyping) { store.setPointer(\.disableWhileTyping, $0) }
                }
            }

            SettingGroup("Scrolling") {
                SettingRow(
                    "Smooth scrolling",
                    p.scrollEasingOverridden
                        ? "LAVA_SCROLL_EASING is set where the compositor was started, and "
                          + "wins over this until it is not. The setting is still saved."
                        : "How long a wheel notch takes to glide into place. Off, each "
                          + "notch lands at once. A touchpad scrolls with the fingers either way."
                ) {
                    Slider(
                        value: Binding(
                            get: { Float(store.pointer.scrollEasingMs) },
                            set: { store.setPointer(\.scrollEasingMs, Int32($0.rounded())) }
                        ),
                        in: 0...300, step: 5,
                        format: { $0 < 1 ? "Off" : "\(Int($0)) ms" }
                    )
                }
            }
        }
    }

    /// "Default" in the middle, slower and faster either side as a percent
    /// of the way to the end: libinput's number means nothing on its own.
    static func speedText(_ v: Float) -> String {
        let percent = Int((v * 100).rounded())
        if percent == 0 { return "Default" }
        return percent > 0 ? "Faster \(percent)%" : "Slower \(-percent)%"
    }

    private func speed(_ keyPath: WritableKeyPath<PointerSettings, Float>) -> Binding<Float> {
        _ = store.pointer[keyPath: keyPath]
        return Binding(
            get: { store.pointer[keyPath: keyPath] },
            set: { store.setPointer(keyPath, $0) }
        )
    }

    private func toggle(_ on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        HStack {
            Toggle(on ? "On" : "Off", isOn: Binding(get: { on }, set: set))
            Spacer()
        }
    }

    private func picker(
        _ choices: [(value: String, title: String, detail: String)], selected: String,
        _ choose: @escaping (String) -> Void
    ) -> some View {
        VStack(spacing: 2) {
            ForEach(choices, id: \.value) { choice in
                PickerRow(title: choice.title, detail: choice.detail,
                          selected: choice.value == selected) { choose(choice.value) }
            }
        }
    }

    private func absent(_ text: String) -> some View {
        Text(text, color: Theme.current.textDim)
    }
}
#endif
