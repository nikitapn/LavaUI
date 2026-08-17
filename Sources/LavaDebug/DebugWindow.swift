#if canImport(LavaIDL)
import Foundation
import LavaClient
import LavaIDL
import LavaUI

/// The window: sections on the left, the open one on the right.
///
/// Laid out like Settings on purpose — same sidebar, same status line — because
/// it is the same kind of window (a tool that reads the compositor) and a
/// second layout for it would be a second thing to learn.
struct DebugWindow: View {
    let store: GpuStore
    let mono: UIFont
    let small: UIFont

    var body: some View {
        // The poll lives here rather than on a timer: the frame loop already
        // runs, and `tick` decides for itself whether the interval is up.
        store.tick()

        return VStack(flexGrow: 1, spacing: 0) {
            HStack(flexGrow: 1, spacing: 0) {
                Sidebar(store: store)
                Content(store: store, mono: mono, small: small)
            }
            StatusLine(store: store, small: small)
        }
        .background(Theme.current.background)
        .windowDrag()
    }
}

private struct Sidebar: View {
    let store: GpuStore

    var body: some View {
        VStack(width: .pt(208), spacing: 0) {
            HStack(padding: 14, alignment: .center, spacing: 0) {
                if WindowBridge.drawsOwnChrome { WindowControls() }
                Spacer()
            }
            .frame(height: .pt(40))
            .windowChrome()

            VStack(padding: 10, spacing: 3) {
                ForEach(DebugSection.allCases, id: \.self) { section in
                    SidebarRow(section: section, store: store)
                }
            }

            // Explicit background: the default style paints `panel`, which is
            // what the sidebar itself is, and three invisible buttons is what
            // that looked like.
            VStack(padding: 10, spacing: 6) {
                let style = ButtonStyle(background: Theme.current.background,
                                        hover: Theme.current.hover,
                                        cornerRadius: 8, padding: 9)
                Button(store.live ? "Pause" : "Resume", style: style) {
                    store.live.toggle()
                }
                Button("Refresh now", style: style) { store.refresh() }
                Button(store.dumping ? "Writing…" : "Write atlas PNGs",
                       style: style) {
                    store.dumpAtlases()
                }
            }

            Spacer()
        }
        .background(Theme.current.panel)
    }
}

private struct SidebarRow: View {
    let section: DebugSection
    let store: GpuStore

    @DrawState private var hovered = false

    var body: some View {
        let selected = store.section == section
        return VStack(
            padding: 9, spacing: 2,
            onClick: { store.section = section },
            onHover: { hovered = $0 }
        ) {
            Text(section.title,
                 color: selected ? Theme.current.textPrimary
                                 : Theme.current.textSecondary)
            Text(section.subtitle, color: Theme.current.textDim)
        }
        .background(selected ? Theme.current.selectionFill
                             : (hovered ? Theme.current.hover : .clear))
        .cornerRadius(8)
    }
}

/// All pages mounted, one visible — so each keeps its own scroll position.
/// Same reasoning as `SettingsContent`.
private struct Content: View {
    let store: GpuStore
    let mono: UIFont
    let small: UIFont

    var body: some View {
        VStack(flexGrow: 1, padding: 16, spacing: 0) {
            OverviewPage(store: store, small: small)
                .hidden(store.section != .overview)
            WindowsPage(store: store, mono: mono, small: small)
                .hidden(store.section != .windows)
            AtlasPage(store: store, mono: mono, small: small)
                .hidden(store.section != .atlases)
            TexturePage(store: store, mono: mono, small: small)
                .hidden(store.section != .textures)
            AllocationPage(store: store, mono: mono, small: small)
                .hidden(store.section != .allocations)
        }
    }
}

private struct StatusLine: View {
    let store: GpuStore
    let small: UIFont

    var body: some View {
        HStack(padding: 8, alignment: .center, spacing: 8) {
            Text(store.status.isEmpty ? statusIdle : store.status,
                 color: store.statusIsError ? Theme.current.accent
                                            : Theme.current.textDim)
            Spacer()
            Text(store.live ? "live, every \(Int(store.interval))s" : "paused",
                 color: Theme.current.textDim)
        }
        .font(small)
        .frame(height: .pt(28))
        .background(Theme.current.panel)
    }

    private var statusIdle: String {
        guard let last = store.lastRefresh else { return "waiting for the first report…" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "read at \(formatter.string(from: last))"
    }
}
#endif
