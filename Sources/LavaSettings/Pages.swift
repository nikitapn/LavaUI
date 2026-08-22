#if canImport(LavaIDL)
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
        let theme = store.themeName

        return VStack(spacing: 18) {
            SettingGroup("Colours") {
                SettingRow("Theme",
                           "Pushed to every Lava window that uses system "
                           + "colours. A terminal or a player that paints "
                           + "its own paper is left alone.") {
                    VStack(spacing: 2) {
                        ForEach(Theme.builtIns, id: \.name) { entry in
                            PickerRow(
                                title: entry.title,
                                detail: entry.summary,
                                selected: theme == entry.name
                            ) {
                                store.setThemeName(entry.name)
                            }
                        }
                    }
                }
            }

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

// ─── Background ─────────────────────────────────────────────────────────────

/// What the desktop is painted with, behind every window.
///
/// The colour controls stay live in both modes rather than greying out under
/// a picture, because the colour is not the *alternative* to a picture — it is
/// what shows through the letterbox under `Fit`, around the edges under
/// `Centre`, and on any screen the picture has not reached yet. Hiding it in
/// picture mode would hide half of what a letterboxed wallpaper looks like.
struct BackgroundPage: View {
    let store: SettingsStore

    /// Enough to pick from without a colour wheel, and there is a hex field
    /// underneath for everything else. Weighted dark because they sit behind
    /// a desktop of dark windows, with one light entry for the light theme.
    private static let swatches: [(name: String, value: UInt32)] = [
        ("Midnight", 0x0e_13_1f), ("Slate", 0x1e_24_30),
        ("Ink", 0x0b_0f_14), ("Charcoal", 0x17_17_1a),
        ("Teal", 0x0d_2b_2b), ("Plum", 0x24_1a_2e),
        ("Moss", 0x17_25_1a), ("Clay", 0x2b_1f_1a),
        ("Paper", 0xd8_d8_dc),
    ]

    private static let fits: [(name: String, value: String, detail: String)] = [
        ("Fill", "fill", "Covers the screen, crops the overflow"),
        ("Fit", "fit", "Whole picture, colour in the bars"),
        ("Stretch", "stretch", "Covers the screen, ignores the shape"),
        ("Centre", "center", "Actual size, no scaling"),
    ]

    var body: some View {
        // Read once here and passed down, which is the cheaper shape rather
        // than the required one: `ForEach` builds its children during this
        // body, so a read left inside one of its closures would register
        // correctly too. Hoisting still avoids re-reading the same property
        // for every row, and keeps the comparison next to what it compares.
        let mode = store.backgroundMode
        let fit = store.backgroundFit
        let color = store.backgroundColor
        let path = store.picturePath

        return VStack(spacing: 18) {
            SettingGroup("Desktop") {
                SettingRow("What to show",
                           "A picture is fitted to each screen separately, so "
                           + "two monitors of different shapes each get their "
                           + "own crop rather than one stretched across both.") {
                    VStack(spacing: 2) {
                        PickerRow(title: "Solid colour",
                                  detail: "solid",
                                  selected: mode != "picture") {
                            store.setBackgroundMode("solid")
                        }
                        PickerRow(title: "Picture",
                                  detail: path.isEmpty
                                      ? "none chosen yet"
                                      : displayName(path),
                                  selected: mode == "picture") {
                            store.setBackgroundMode("picture")
                        }
                    }
                }
            }

            SettingGroup("Colour") {
                SettingRow("Desktop colour",
                           mode == "picture"
                               ? "Behind the picture: the letterbox bars, the "
                                 + "margins, and any screen the picture has "
                                 + "not been fitted to yet."
                               : "What the desktop is painted with.") {
                    VStack(spacing: 10) {
                        SwatchGrid(store: store, swatches: Self.swatches,
                                   selected: color)
                        ColorPicker(
                            color: Binding(
                                get: { Color(rgb24: color) },
                                set: { store.setBackgroundColor($0.rgb24) }
                            )
                        )
                        TextField(
                            text: Binding(store, \.colorText),
                            placeholder: hexString(color)
                                + " — type a hex colour and press Return",
                            onSubmit: { store.commitColorText() }
                        )
                        .padding(8)
                        .background(Theme.current.inset)
                        .cornerRadius(6)
                    }
                }
            }

            SettingGroup("Picture") {
                SettingRow("Fit",
                           "How the picture is placed on each screen.") {
                    VStack(spacing: 2) {
                        ForEach(Self.fits, id: \.value) { entry in
                            PickerRow(title: entry.name,
                                      detail: entry.detail,
                                      selected: fit == entry.value) {
                                store.setBackgroundFit(entry.value)
                            }
                        }
                    }
                }

                SettingRow(
                    "File",
                    "PNG, JPEG, BMP, GIF or TGA. A path that cannot be read is "
                    + "refused and the desktop is left as it is."
                ) {
                    VStack(spacing: 8) {
                        TextField(
                            text: Binding(store, \.picturePath),
                            placeholder: "~/Pictures/something.png",
                            onSubmit: { store.setPicture(store.picturePath) }
                        )
                        .padding(8)
                        .background(Theme.current.inset)
                        .cornerRadius(6)
                        PictureList(store: store, selected: path,
                                    isPictureMode: mode == "picture")
                    }
                }
            }
        }
    }

    private func displayName(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }
}

/// The colours, as colours. A name in a list would be a worse way to pick one.
private struct SwatchGrid: View {
    let store: SettingsStore
    let swatches: [(name: String, value: UInt32)]
    /// Passed in rather than read from the store: the grid draws a selection
    /// it is given and has no opinion about where the value lives.
    let selected: UInt32

    var body: some View {
        // Two rows rather than one: nine swatches wide enough to hit would
        // overflow the panel at its default width, and wrapping is not
        // something the layout offers.
        let half = (swatches.count + 1) / 2
        return VStack(spacing: 6) {
            row(Array(swatches.prefix(half)))
            row(Array(swatches.dropFirst(half)))
        }
    }

    private func row(_ entries: [(name: String, value: UInt32)]) -> some View {
        let current = selected
        return HStack(spacing: 6) {
            ForEach(entries, id: \.value) { swatch in
                Swatch(
                    color: swatch.value,
                    name: swatch.name,
                    selected: current == swatch.value
                ) {
                    store.setBackgroundColor(swatch.value)
                }
            }
            Spacer()
        }
    }
}

private struct Swatch: View {
    let color: UInt32
    let name: String
    let selected: Bool
    let action: () -> Void

    @DrawState private var hovered = false

    var body: some View {
        // The selection ring is an outer box painted the accent colour with
        // the swatch inset into it. There is no border modifier, and a ring
        // made of padding costs nothing and cannot be half-drawn.
        VStack(
            padding: 3,
            spacing: 0,
            onClick: action,
            onHover: { hovered = $0 }
        ) {
            VStack(spacing: 0) {
                Spacer()
            }
            .frame(width: .pt(46), height: .pt(30))
            .background(colorOf(color))
            .cornerRadius(5)
        }
        .background(
            selected ? Theme.current.accent
                     : (hovered ? Theme.current.hover : .clear)
        )
        .cornerRadius(8)
    }
}

/// Pictures found in the usual directories.
private struct PictureList: View {
    let store: SettingsStore
    /// Both passed in rather than read from the store, so this list draws the
    /// selection the page hands it rather than deciding on one of its own.
    let selected: String
    let isPictureMode: Bool

    private static let visibleLimit = 24

    var body: some View {
        let all = store.pictures
        let shown = Array(all.prefix(Self.visibleLimit))
        let current = selected
        let picked = isPictureMode

        return VStack(spacing: 2) {
            if all.isEmpty {
                Text("No pictures found in ~/Pictures, ~/Wallpapers or "
                     + "/usr/share/backgrounds. Type a path above instead.",
                     color: Theme.current.textDim)
            }
            ForEach(shown, id: \.self) { path in
                PickerRow(
                    title: String(path.split(separator: "/").last ?? ""),
                    detail: folderOf(path),
                    selected: current == path && picked
                ) {
                    store.setPicture(path)
                }
            }
            if all.count > shown.count {
                Text("…and \(all.count - shown.count) more — type a path above.",
                     color: Theme.current.textDim)
            }
        }
    }

    private func folderOf(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count >= 2 ? String(parts[parts.count - 2]) : ""
    }
}

/// `0x00RRGGBB` as a LavaUI colour.
private func colorOf(_ value: UInt32) -> Color {
    Color(
        r: Float((value >> 16) & 0xff) / 255,
        g: Float((value >> 8) & 0xff) / 255,
        b: Float(value & 0xff) / 255
    )
}

private func hexString(_ value: UInt32) -> String {
    String(format: "#%06x", value & 0x00_ff_ff_ff)
}

// ─── Keyboard ───────────────────────────────────────────────────────────────

struct KeyboardPage: View {
    let store: SettingsStore

    var body: some View {
        VStack(spacing: 18) {
            SettingGroup("Layout") {
                SettingRow(
                    "Layouts",
                    "Add every language you type in. A switch key below "
                    + "cycles this list — a single layout has nothing to "
                    + "cycle to, which is how a `grp:` option looked broken."
                ) {
                    VStack(spacing: 8) {
                        if store.sources.isEmpty {
                            Text(
                                "xkb default (usually US). Pick one below "
                                + "to set it, or two to switch between them.",
                                color: Theme.current.textDim
                            )
                        } else {
                            ForEach(store.sources) { source in
                                PickerRow(
                                    title: store.sourceLabel(source),
                                    detail: source.variant.isEmpty
                                        ? source.code
                                        : "\(source.code) · \(source.variant)",
                                    selected: true
                                ) {
                                    store.removeSource(id: source.id)
                                }
                            }
                        }
                        if store.sources.count < 2 && store.layoutSwitch.hasPrefix("grp:") {
                            Text(
                                "Switch key is set, but there is only one "
                                + "layout. Add another — clicking the list "
                                + "used to replace this one.",
                                color: Theme.current.accent
                            )
                        }
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
                    "Switch layouts",
                    "Needs two layouts above. `grp:ctrls_toggle` is both "
                    + "Ctrl keys together; there is no `grp:ctrl_toggle`."
                ) {
                    VStack(spacing: 2) {
                        ForEach(Self.layoutSwitches, id: \.option) { item in
                            PickerRow(
                                title: item.title,
                                detail: item.option.isEmpty ? "off" : item.option,
                                selected: store.layoutSwitch == item.option
                            ) {
                                store.setLayoutSwitch(item.option)
                            }
                        }
                    }
                }

                SettingRow(
                    "Other options",
                    "Anything that is not a layout switch: ctrl:nocaps, "
                    + "compose:ralt. Applied when you press Return."
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
                    "Modifier",
                    "Which key the compositor's own shortcuts use, and which "
                    + "one holds a window for drag-to-move. Alt is the "
                    + "default; Super is the Win key."
                ) {
                    HStack(spacing: 8) {
                        PickerRow(
                            title: "Alt",
                            detail: "Left/Right Alt",
                            selected: store.modKey != "super"
                        ) {
                            store.setModKey("alt")
                        }
                        PickerRow(
                            title: "Super",
                            detail: "Win / Meta",
                            selected: store.modKey == "super"
                        ) {
                            store.setModKey("super")
                        }
                    }
                }

                SettingRow(
                    "Compositor shortcuts",
                    "Taken before any application sees the key. Alt+Tab cycles "
                    + "windows; Super+M (or Alt+M) hides every window and "
                    + "Super+Shift+M brings them back; Super+D shows the "
                    + "desktop. Compiled in for now — this list comes from the "
                    + "same table that dispatches them, so what is here is "
                    + "what works."
                ) {
                    VStack(spacing: 2) {
                        ForEach(store.bindings, id: \.action) { binding in
                            HStack(padding: 4, alignment: .center, spacing: 10) {
                                Text("\(binding.modifiers)+\(binding.key)",
                                     color: Theme.current.accent)
                                    .frame(width: .pt(160))
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

    /// Common `grp:` options. Names from evdev.lst — a typo is silently
    /// ignored by xkb, which is how `grp:ctrl_toggle` appeared to work
    /// and then did nothing.
    private static let layoutSwitches: [(title: String, option: String)] = [
        ("None", ""),
        ("Alt+Shift", "grp:alt_shift_toggle"),
        ("Ctrl+Shift", "grp:ctrl_shift_toggle"),
        ("Both Ctrl keys", "grp:ctrls_toggle"),
        ("Super+Space", "grp:win_space_toggle"),
        ("Left Ctrl", "grp:lctrl_toggle"),
        ("Right Ctrl", "grp:rctrl_toggle"),
        ("Caps Lock", "grp:caps_toggle"),
        ("Both Shifts", "grp:shifts_toggle"),
    ]

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
                    selected: store.containsSource(
                        code: entry.layout.code, variant: entry.layout.variant
                    )
                ) {
                    store.toggleSource(
                        code: entry.layout.code, variant: entry.layout.variant
                    )
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
            let aCurrent = store.containsSource(
                code: a.layout.code, variant: a.layout.variant
            )
            let bCurrent = store.containsSource(
                code: b.layout.code, variant: b.layout.variant
            )
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
                let enabled = store.outputs.filter(\.enabled)
                if enabled.count >= 2 {
                    SettingGroup("Arrangement") {
                        SettingRow(
                            "How screens work together",
                            "Extend gives each screen its own desktop. "
                            + "Mirror shows the same picture on every screen."
                        ) {
                            VStack(spacing: 2) {
                                PickerRow(
                                    title: "Extend",
                                    detail: "side by side",
                                    selected: store.arrangement != "mirror"
                                ) {
                                    store.setArrangement("extend")
                                }
                                PickerRow(
                                    title: "Mirror",
                                    detail: "same picture",
                                    selected: store.arrangement == "mirror"
                                ) {
                                    store.setArrangement("mirror")
                                }
                            }
                        }
                    }

                    SettingGroup("Primary") {
                        SettingRow(
                            "Panel screen",
                            "The panel lives here, and new windows open here. "
                            + "Unplugging it does not forget the choice — "
                            + "another screen stands in until it comes back."
                        ) {
                            VStack(spacing: 2) {
                                ForEach(enabled, id: \.name) { output in
                                    PickerRow(
                                        title: output.description.isEmpty
                                            ? output.name
                                            : "\(output.name) — \(output.description)",
                                        detail: output.primary ? "panel" : "",
                                        selected: output.primary
                                    ) {
                                        store.setPrimary(output.name)
                                    }
                                }
                            }
                        }
                    }
                }

                SettingGroup("Screens") {
                    VStack(spacing: 2) {
                        ForEach(store.outputs, id: \.name) { output in
                            PickerRow(
                                title: output.description.isEmpty
                                    ? output.name
                                    : "\(output.name) — \(output.description)",
                                detail: screenDetail(output),
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

    private func screenDetail(_ output: OutputInfo) -> String {
        if !output.enabled { return "off" }
        var text = output.refresh > 0
            ? "\(output.width)×\(output.height) · \(hz(output.refresh))"
            : "\(output.width)×\(output.height)"
        if output.primary { text += " · primary" }
        return text
    }
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
