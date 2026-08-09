#if canImport(CxxCanvas) && canImport(LavaIDL)
import Foundation
import LavaClient
import LavaIDL
import LavaUI

// ─── Appearance ─────────────────────────────────────────────────────────────

/// Corners and shadows, live.
///
/// There is deliberately no preview swatch on this page. The preview is the
/// window the page is in: every slider here changes what the compositor draws
/// around *this* window while the pointer is still on the knob, and a small
/// rectangle imitating that alongside would be a worse copy of something
/// already on screen.
struct AppearancePage: View {
    let store: SettingsStore

    var body: some View {
        VStack(spacing: 18) {
            SettingGroup("Windows") {
                SettingRow("Corner radius",
                           "Rounds every window the compositor draws, and the "
                           + "title bars above them. 0 is square.") {
                    Slider(
                        value: pushed(\.cornerRadius),
                        in: 0...32,
                        step: 1,
                        format: { "\(Int($0)) px" }
                    )
                }
            }

            SettingGroup("Shadow") {
                SettingRow("Reach",
                           "How far the focused window's shadow spreads. 0 turns "
                           + "shadows off — only the focused window casts one, "
                           + "which is how the desktop says which it is.") {
                    Slider(
                        value: pushed(\.shadowBlur),
                        in: 0...64,
                        step: 1,
                        format: { "\(Int($0)) px" }
                    )
                }

                SettingRow("Depth", "How dark it is directly under the window.") {
                    Slider(
                        value: pushed(\.shadowOpacity),
                        in: 0...1,
                        step: 0.01,
                        format: { String(format: "%.0f%%", $0 * 100) }
                    )
                }

                SettingRow("Offset",
                           "How far down the shadow is pushed. Light comes from "
                           + "above, and a shadow centred on its window reads as "
                           + "a glow.") {
                    Slider(
                        value: pushed(\.shadowOffsetY),
                        in: -16...32,
                        step: 1,
                        format: { "\(Int($0)) px" }
                    )
                }
            }
        }
    }

    /// A binding that writes through to the compositor.
    ///
    /// Reading the property here, inside `body`, is what registers the
    /// Observation dependency — the same reason `Binding(_:_:)` does it. The
    /// setter pushes on every step rather than on release, which is the whole
    /// point of the page; the compositor rate-limits what reaches the config
    /// file so a drag does not rewrite it sixty times a second.
    private func pushed(
        _ keyPath: ReferenceWritableKeyPath<SettingsStore, Float>
    ) -> Binding<Float> {
        _ = store[keyPath: keyPath]
        return Binding(
            get: { store[keyPath: keyPath] },
            set: { newValue in
                store[keyPath: keyPath] = newValue
                store.pushAppearance()
            }
        )
    }
}

// ─── Keyboard ───────────────────────────────────────────────────────────────

struct KeyboardPage: View {
    let store: SettingsStore

    var body: some View {
        VStack(spacing: 18) {
            SettingGroup("Layout") {
                SettingRow(
                    "Current",
                    store.variant.isEmpty
                        ? "\(store.layout.isEmpty ? "xkb default" : store.layout)"
                        : "\(store.layout) · \(store.variant)"
                ) {
                    VStack(spacing: 8) {
                        TextField(
                            text: Binding(store, \.layoutFilter),
                            placeholder: "Search layouts — \"german\", \"dvorak\", \"ru\""
                        )
                        .padding(8)
                        .background(Theme.current.inset)
                        .cornerRadius(6)
                        LayoutList(store: store)
                    }
                }

                SettingRow(
                    "Options",
                    "xkb options, comma separated: ctrl:nocaps, "
                    + "grp:alt_shift_toggle. Applied when you press Return."
                ) {
                    TextField(
                        text: Binding(store, \.options),
                        placeholder: "none",
                        onSubmit: { store.pushKeyboard() }
                    )
                    .padding(8)
                    .background(Theme.current.inset)
                    .cornerRadius(6)
                }
            }

            SettingGroup("Repeat") {
                SettingRow("Rate", "Keys per second once repeating starts.") {
                    Slider(
                        value: pushed(\.repeatRate),
                        in: 1...100,
                        step: 1,
                        format: { "\(Int($0))/s" }
                    )
                }
                SettingRow("Delay", "How long a key is held before it repeats.") {
                    Slider(
                        value: pushed(\.repeatDelay),
                        in: 100...2000,
                        step: 10,
                        format: { "\(Int($0)) ms" }
                    )
                }
            }

            SettingGroup("Shortcuts") {
                SettingRow(
                    "Compositor shortcuts",
                    "Taken before any application sees the key. Compiled in for "
                    + "now — this list comes from the same table that dispatches "
                    + "them, so what is here is what works."
                ) {
                    VStack(spacing: 2) {
                        ForEach(store.bindings, id: \.action) { binding in
                            HStack(padding: 4, alignment: .center, spacing: 10) {
                                Text("\(binding.modifiers)+\(binding.key)",
                                     color: Theme.current.accent)
                                    .frame(width: .pt(140))
                                Text(binding.description,
                                     color: Theme.current.textSecondary)
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
    }

    private func pushed(
        _ keyPath: ReferenceWritableKeyPath<SettingsStore, Float>
    ) -> Binding<Float> {
        _ = store[keyPath: keyPath]
        return Binding(
            get: { store[keyPath: keyPath] },
            set: { newValue in
                store[keyPath: keyPath] = newValue
                store.pushKeyboard()
            }
        )
    }
}

/// The filtered layout list.
///
/// Capped rather than scrolled to the end: a normal install has a few hundred
/// layouts and around a thousand variants, and a list that long is not a list
/// anyone reads — it is something they filter. Saying how many were left out
/// is what tells them to keep typing.
private struct LayoutList: View {
    let store: SettingsStore

    private static let visibleLimit = 40

    var body: some View {
        let matches = filtered()
        let shown = Array(matches.prefix(Self.visibleLimit))

        return VStack(spacing: 2) {
            if !store.layoutsLoaded {
                Text("Reading the layouts…", color: Theme.current.textDim)
            } else if matches.isEmpty {
                Text("No layout matches “\(store.layoutFilter)”.",
                     color: Theme.current.textDim)
            }

            ForEach(shown, id: \.id) { entry in
                PickerRow(
                    title: entry.layout.description,
                    detail: entry.layout.variant.isEmpty
                        ? entry.layout.code
                        : "\(entry.layout.code) · \(entry.layout.variant)",
                    selected: entry.layout.code == store.layout
                        && entry.layout.variant == store.variant
                ) {
                    store.layout = entry.layout.code
                    store.variant = entry.layout.variant
                    store.pushKeyboard()
                }
            }

            if matches.count > shown.count {
                Text("…and \(matches.count - shown.count) more — keep typing to narrow it.",
                     color: Theme.current.textDim)
            }
        }
    }

    /// One entry per layout or variant, with a stable id for `ForEach`.
    private struct Entry: Identifiable {
        let layout: KeyboardLayout
        var id: String { "\(layout.code)/\(layout.variant)" }
    }

    private func filtered() -> [Entry] {
        let needle = store.layoutFilter
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        var out: [Entry] = []
        for group in store.layoutGroups {
            for layout in group.entries {
                guard needle.isEmpty
                    || layout.code.lowercased().contains(needle)
                    || layout.variant.lowercased().contains(needle)
                    || layout.description.lowercased().contains(needle)
                else { continue }
                out.append(Entry(layout: layout))
            }
        }
        // What is already in use first, so the list opens on the answer to
        // "what am I running now" rather than on whatever sorts first.
        return out.sorted { a, b in
            let aCurrent = a.layout.code == store.layout
            let bCurrent = b.layout.code == store.layout
            if aCurrent != bCurrent { return aCurrent }
            return false
        }
    }
}

// ─── Display ────────────────────────────────────────────────────────────────

struct DisplayPage: View {
    let store: SettingsStore

    var body: some View {
        VStack(spacing: 18) {
            if store.outputs.isEmpty {
                Text("No screens reported.", color: Theme.current.textDim)
            } else {
                SettingGroup("Screens") {
                    VStack(spacing: 2) {
                        ForEach(store.outputs, id: \.name) { output in
                            PickerRow(
                                title: output.description.isEmpty
                                    ? output.name
                                    : "\(output.name) — \(output.description)",
                                detail: output.enabled
                                    ? (output.refresh > 0
                                        ? "\(output.width)×\(output.height) · \(hz(output.refresh))"
                                        : "\(output.width)×\(output.height)")
                                    : "off",
                                selected: output.name == store.selectedOutput
                            ) {
                                store.selectedOutput = output.name
                                store.reloadModes()
                            }
                        }
                    }
                }

                if let output = store.currentOutput {
                    ScreenSettings(store: store, output: output)
                }
            }
        }
    }

    private func hz(_ mHz: UInt32) -> String { formatHz(mHz) }
}

private struct ScreenSettings: View {
    let store: SettingsStore
    let output: OutputInfo

    var body: some View {
        VStack(spacing: 18) {
            SettingGroup(output.name) {
                SettingRow(
                    "Enabled",
                    "A screen turned off here is removed from the desktop's "
                    + "layout; its windows move to what is left."
                ) {
                    Toggle(
                        output.enabled ? "On" : "Off",
                        isOn: Binding(
                            get: { output.enabled },
                            set: { on in store.pushOutput { $0.enabled = on } }
                        )
                    )
                }

                SettingRow(
                    "Mode",
                    "A mode the display refuses falls back to the one it "
                    + "prefers, rather than leaving you looking at nothing."
                ) {
                    ModeList(store: store, output: output)
                }

                SettingRow(
                    "Scale",
                    "How large everything is drawn. 2 is the usual answer for "
                    + "a high-density panel."
                ) {
                    Slider(
                        value: Binding(
                            get: { output.scale },
                            set: { value in store.pushOutput { $0.scale = value } }
                        ),
                        in: 0.5...3,
                        step: 0.25,
                        format: { String(format: "%.2f×", $0) }
                    )
                }

                SettingRow(
                    "Rotation",
                    "Position is \(output.x), \(output.y) in the desktop's layout."
                ) {
                    HStack(spacing: 6) {
                        ForEach(Self.rotations, id: \.value) { rotation in
                            Button(rotation.label) {
                                store.pushOutput { $0.transform = rotation.value }
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private static let rotations: [(label: String, value: UInt32)] = [
        ("Normal", 0), ("90°", 1), ("180°", 2), ("270°", 3),
    ]
}

private struct ModeList: View {
    let store: SettingsStore
    let output: OutputInfo

    var body: some View {
        VStack(spacing: 2) {
            if store.modes.isEmpty {
                // A nested or headless backend has no mode list at all, which
                // is a fact about the backend rather than a failure.
                Text("This backend reports no modes.", color: Theme.current.textDim)
            }
            ForEach(store.modes, id: \.id) { mode in
                PickerRow(
                    title: "\(mode.width) × \(mode.height)",
                    detail: label(for: mode),
                    selected: mode.current
                ) {
                    store.pushOutput {
                        $0.width = mode.width
                        $0.height = mode.height
                        $0.refresh = mode.refresh
                    }
                }
            }
        }
    }

    private func label(for mode: OutputMode) -> String {
        var text = formatHz(mode.refresh)
        if mode.preferred { text += " · preferred" }
        return text
    }
}

/// A refresh rate as a person reads it.
///
/// Rates are carried in mHz because that is what modes are matched in — 74.973
/// Hz is a real rate and rounding it to 75 matches nothing — but three decimal
/// places on a flat 60 Hz is noise. So: the fraction only when there is one,
/// and no rate at all when the backend does not report one, which a nested or
/// headless output genuinely does not.
func formatHz(_ mHz: UInt32) -> String {
    guard mHz > 0 else { return "no rate reported" }
    if mHz % 1000 == 0 { return "\(mHz / 1000) Hz" }
    var text = String(format: "%.3f", Double(mHz) / 1000.0)
    while text.hasSuffix("0") { text.removeLast() }
    return text + " Hz"
}

/// `ForEach` needs a stable id, and a mode is identified by what it is.
extension OutputMode: Identifiable {
    public var id: String { "\(width)x\(height)@\(refresh)" }
}
#endif
