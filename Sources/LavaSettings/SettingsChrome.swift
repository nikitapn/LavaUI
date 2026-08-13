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

            VStack(padding: 10, spacing: 3) {
                ForEach(SettingsSection.allCases, id: \.self) { section in
                    SidebarRow(section: section, store: store)
                }
            }

            Spacer()
        }
        .background(Theme.current.panel)
    }
}

private struct SidebarRow: View {
    let section: SettingsSection
    let store: SettingsStore

    @DrawState private var hovered = false

    var body: some View {
        let selected = store.section == section
        return VStack(
            padding: 9,
            spacing: 2,
            onClick: {
                store.section = section
                // The layout catalogue is a parse of the xkb rules on the
                // compositor's loop. Paid for on the way into the page that
                // needs it, rather than at startup for a page nobody may
                // open — and here rather than in that page's `body`, which
                // must not be the thing that changes what it is drawing.
                if section == .keyboard { store.ensureLayouts() }
            },
            onHover: { hovered = $0 }
        ) {
            Text(section.title,
                 color: selected ? Theme.current.textPrimary
                                 : Theme.current.textSecondary)
            Text(section.subtitle, color: Theme.current.textDim)
        }
        .background(
            // `selectionFill`, not `selected`: the latter is the bright
            // highlight a menu draws behind *dark* text, and light text on it
            // is unreadable — which is what it looked like.
            selected ? Theme.current.selectionFill
                     : (hovered ? Theme.current.hover : .clear)
        )
        .cornerRadius(8)
    }
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
        // Read here, not inside the `ForEach` closure. Observation records a
        // dependency on what a `body` reads *while it runs*, and the closure
        // runs later, when the list mounts its children — so reading it in
        // there registers nothing, and changing the page updated the sidebar
        // (whose own body does read it) while the content sat still.
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
        ScrollView {
            VStack(padding: 26, spacing: 22) {
                Text(section.title, color: Theme.current.textPrimary)

                switch section {
                case .appearance:
                    AppearancePage(store: store)
                case .keyboard:
                    KeyboardPage(store: store)
                case .display:
                    DisplayPage(store: store)
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
                message.isEmpty ? "Changes apply immediately and are saved to lava.conf."
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
        VStack(padding: 14, spacing: 8) {
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

    @DrawState private var hovered = false

    var body: some View {
        HStack(
            padding: 8,
            alignment: .center,
            spacing: 10,
            onClick: action,
            onHover: { hovered = $0 }
        ) {
            // A dot rather than a tick: it is the same width in both states,
            // so a list does not shift sideways as the selection moves.
            Text(selected ? "●" : "○",
                 color: selected ? Theme.current.accent : Theme.current.textDim)
            Text(title, color: Theme.current.textPrimary)
            Spacer()
            if !detail.isEmpty {
                Text(detail, color: Theme.current.textDim)
            }
        }
        .background(
            selected ? Theme.current.selectionFill
                     : (hovered ? Theme.current.hover : .clear)
        )
        .cornerRadius(6)
    }
}
#endif
