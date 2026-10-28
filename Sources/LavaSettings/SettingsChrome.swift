#if canImport(LavaIDL)
import Foundation
import LavaClient
import LavaIDL
import LavaUI

/// The window: a list of pages on the left, the open one on the right.
///
/// The whole thing is a drag handle. This window has no title bar — it asked
/// for `WindowFrame.client`, so the compositor draws nothing around it — and
/// the usual answer, a strip along the top to grab, would be a title bar drawn
/// by hand with the pixels the app just reclaimed. Making the window itself
/// the handle costs nothing instead: the hit test reaches children first, so
/// every control still gets its click and only the space between them moves
/// the window.
struct SettingsWindow: View {
    let store: SettingsStore

    var body: some View {
        VStack(flexGrow: 1, spacing: 0) {
            HStack(flexGrow: 1, spacing: 0) {
                SettingsSidebar(store: store)
                SettingsContent(store: store)
            }
            StatusBar(store: store)
        }
        .background(Theme.current.background)
        .windowDrag()
    }
}

/// The page list, and the window's controls above it.
///
/// The controls go top-left, over the sidebar rather than over the content:
/// that corner is the one part of this window with nothing in it, and a
/// cluster there reads as belonging to the window instead of to the page.
struct SettingsSidebar: View {
    let store: SettingsStore
    /// Starts true: the sidebar has the keyboard from the first frame, so
    /// the arrows move between pages without a click first. A click into a
    /// page's field takes it, and sets this back.
    @State private var focused = true

    var body: some View {
        VStack(width: .pt(212), spacing: 0) {
            HStack(padding: 14, alignment: .center, spacing: 0) {
                // Only where the app owns its chrome. Under a window manager
                // the real frame already has these, and a second set below it
                // is a decoration nobody asked for.
                if WindowBridge.drawsOwnChrome {
                    WindowControls()
                }
                Spacer()
            }
            .frame(height: .pt(40))
            .windowChrome()

            // Scrolls, because six pages with two-line subtitles are taller
            // than the window can be made, and the compositor reopens it at
            // whatever size it was last left — so no opening size settles it.
            List(
                SettingsSection.allCases, id: \.self,
                selection: Binding(
                    get: { store.section },
                    set: { show($0, store: store) }
                ),
                spacing: 3, padding: 10,
                rowInsets: EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13)
            ) { section, selected in
                VStack(spacing: 4) {
                    Text(section.title,
                         color: selected ? Theme.current.textPrimary
                                         : Theme.current.textSecondary)
                    Text(section.subtitle, color: Theme.current.textDim)
                }
            }
            .focused($focused)
            .flexGrow(1)
        }
        .background(Theme.current.panel)
    }
}

/// Goes to `section`: the sidebar's click, and `--section` at startup.
func show(_ section: SettingsSection, store: SettingsStore) {
    // A search runs for the page that started it, not for whichever page
    // is looked at next.
    if section != .bluetooth { bluetoothSettings.leave() }
    // Shown when its data is in, not a frame before: see
    // `NetworkSettings.start`.
    if section == .network {
        networkSettings.start { store.section = .network }
        return
    }
    if section == .bluetooth {
        bluetoothSettings.start { store.section = .bluetooth }
        return
    }
    store.section = section
    // The layout catalogue is a parse of the xkb rules on the compositor's
    // loop. Paid for on the way into the page that needs it, rather than at
    // startup for a page nobody may open — and here rather than in that
    // page's `body`, which must not be the thing that changes what it is
    // drawing.
    if section == .keyboard { store.ensureLayouts() }
    if section == .background { store.ensurePictures() }
}

/// The pages, all of them, with one showing.
///
/// All three stay mounted and the two you are not looking at are `hidden` —
/// rather than the obvious `switch`, which would build only the open one.
///
/// The reason is scroll position. It is held by the renderer against a node
/// id, so a page destroyed on the way out comes back as a different node with
/// nothing remembered about it: leave the Keyboard page halfway down its layout
/// list, go to Appearance, come back, and you are at the top again. Keeping the
/// nodes alive is what lets each page keep its own place. The cost is three
/// mounted trees instead of one, which for three settings pages is nothing —
/// Yoga skips a hidden one entirely, and a page whose state nobody is changing
/// does not recompute its body either.
struct SettingsContent: View {
    let store: SettingsStore

    var body: some View {
        // Read once here rather than per page in the `ForEach` below. This
        // used to be load-bearing: the closure ran at mount time, outside the
        // tracking scope, so reading it in there registered nothing and
        // changing the page updated the sidebar while the content sat still.
        // `ForEach` builds its children during this body now, so either
        // spelling works and this is only the tidier one.
        let active = store.section
        // Side by side rather than stacked, though only one is ever shown. In
        // a column each page's height would be its *content* height — flex
        // grows free space and there is none when the content is four screens
        // tall — and a scroll view whose height equals its content has nothing
        // to scroll. Across, height is the cross axis: `stretch` gives every
        // page exactly the window's height, which is the viewport it needs.
        return HStack(flexGrow: 1, alignment: .stretch, spacing: 0) {
            ForEach(SettingsSection.allCases, id: \.self) { section in
                page(section)
                    .flexGrow(1)
                    .hidden(section != active)
            }
        }
        .flexGrow(1)
    }

    @ViewBuilder
    private func page(_ section: SettingsSection) -> some View {
        if section == .network {
            // Scrolls itself: an overview and an editor, each with its own
            // place — see `NetworkPage`.
            NetworkPage()
        } else if section == .bluetooth {
            BluetoothPage()
        } else {
            scrolled(section)
        }
    }

    private func scrolled(_ section: SettingsSection) -> some View {
        ScrollView {
            VStack(padding: 26, spacing: 22) {
                Text(section.title, color: Theme.current.textPrimary)

                switch section {
                case .appearance:
                    AppearancePage(store: store)
                case .background:
                    BackgroundPage(store: store)
                case .keyboard:
                    KeyboardPage(store: store)
                case .pointer:
                    PointerPage(store: store)
                case .display:
                    DisplayPage(store: store)
                case .network, .bluetooth:
                    EmptyView()
                case .lock:
                    LockPage(store: store)
                case .search:
                    SearchPage(store: store)
                }

                Spacer()
            }
        }
    }
}

/// One line at the bottom, for the things a settings app has to be able to
/// say: that it is not connected, or that a change applied and did not save.
struct StatusBar: View {
    let store: SettingsStore

    var body: some View {
        let message = store.status
        return HStack(padding: 12, alignment: .center, spacing: 8) {
            Text(
                message.isEmpty
                    ? (store.section == .search
                        ? "Changes apply immediately and are saved to index.conf."
                        : store.section == .network
                        ? "Profiles are NetworkManager's, and saved by it."
                        : store.section == .bluetooth
                        ? "Pairings are bluetoothd's, and kept by it."
                        : "Changes apply immediately and are saved to lava.conf.")
                    : message,
                color: message.isEmpty
                    ? Theme.current.textDim
                    : (store.statusIsError ? Theme.current.accent
                                           : Theme.current.textSecondary)
            )
            Spacer()
        }
        .background(Theme.current.panel)
    }
}

// ─── Shared pieces ──────────────────────────────────────────────────────────

/// A titled row: what the setting is on the left, the control under it.
///
/// One shape for every setting on every page, because the alternative — each
/// page laying its own out — is three pages that drift into looking like three
/// applications.
struct SettingRow<Content: View>: View {
    let title: String
    let detail: String
    let content: Content

    init(_ title: String, _ detail: String = "", @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(padding: 16, spacing: 10) {
            Text(title, color: Theme.current.textPrimary)
            if !detail.isEmpty {
                Text(detail, color: Theme.current.textDim)
            }
            content
        }
        // `panel`, not `inset`: in the dark theme `inset` is within a
        // hundredth of `background`, so a card drawn in it is a card nobody
        // can see. The page behind these is `background`, so the card has to
        // be the lighter of the two.
        .background(Theme.current.panel)
        .cornerRadius(10)
    }
}

/// A card of rows under one heading.
struct SettingGroup<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(title.uppercased(), color: Theme.current.textDim)
            content
        }
    }
}

/// A row in a list that can be picked: a mode, a layout, a screen.
struct PickerRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        HStack(
            padding: 0,
            alignment: .center,
            spacing: 12,
            onClick: action
        ) {
            // A dot rather than a tick: it is the same width in both states,
            // so a list does not shift sideways as the selection moves.
            Text(selected ? "●" : "○",
                 color: selected ? Theme.current.accent : Theme.current.textDim)
            Text(title, color: Theme.current.textPrimary)
            Spacer()
            // The one child that may give way. Nothing in a row shrinks
            // unless it says so (`LayoutNode.flexShrink`), so a detail longer
            // than the card had left ran out past its edge, one line long,
            // instead of wrapping.
            if !detail.isEmpty {
                Text(detail, color: Theme.current.textDim)
                    .flexShrink(1)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(selected ? Theme.current.selectionFill : .clear)
        .hoverBackground(selected ? Theme.current.selectionFill : Theme.current.hover)
        .cornerRadius(6)
    }
}
#endif
