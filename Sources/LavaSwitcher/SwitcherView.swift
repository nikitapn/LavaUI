import Foundation
import LavaIDL
import LavaUI

/// Full-screen dimmer, a Scene3D shelf of live window posters, and the
/// selected window's name. The layout is the poster catalog from HelloWorld
/// with window-shaped cards instead of album covers.
struct SwitcherView: View {
    var body: some View {
        let windows = model.windows
        let selected = model.selected
        let current = model.selectedWindow
        let ready = model.ready
        let showCards = ready && !windows.isEmpty
        let layout = CatalogLayout3D.focusedShelf(
            spacing: 1.85,
            focusDepth: 0.78,
            focusLift: 0.14,
            focusScale: 1.18,
            fanAngle: .degrees(16)
        )
        let distance = layout.recommendedMinimumCameraDistance(
            itemCount: max(windows.count, 1),
            itemWidth: Switcher.cardWidth,
            itemHeight: Switcher.cardHeight,
            clearance: 2.4
        )

        // Stretch, not center: Scene3D is a Yoga leaf with no intrinsic size,
        // and a centered column leaves that leaf at 0×N — the projector then
        // refuses to emit, which is exactly "labels and no cards".
        VStack(flexGrow: 1, padding: 36, spacing: 18) {
            HeaderLine(text: headerLine(
                empty: windows.isEmpty, ready: ready
            ))
            Scene3D(
                camera: .perspective(
                    position: [0, 0.42, distance],
                    target: [0, -0.08, 0],
                    fieldOfView: .degrees(38)
                ),
                width: .pct(100),
                height: .pt(320),
                flexGrow: 1
            ) {
                AmbientLight3D(intensity: 0.32)
                DirectionalLight3D(
                    direction: [-0.28, -0.55, -1], intensity: 1.12
                )
                if showCards {
                    ForEach3D(
                        Array(windows.enumerated()), id: \.element.surfaceId
                    ) { item in
                        WindowCard3D(
                            index: item.offset,
                            count: windows.count,
                            window: item.element,
                            selected: selected,
                            layout: layout
                        )
                    }
                }
            }
            Footer(
                title: titleLine(current: current, empty: windows.isEmpty),
                subtitle: current?.appId ?? ""
            )
        }
        .background(Color(r: 0.015, g: 0.012, b: 0.04, a: 0.58))
    }

    private func headerLine(empty: Bool, ready: Bool) -> String {
        if empty { return "No windows" }
        if !ready { return "Gathering windows…" }
        return "Switch windows"
    }

    private func titleLine(current: WindowInfo?, empty: Bool) -> String {
        if empty { return "Nothing is open on this workspace." }
        if let title = current?.title, !title.isEmpty { return title }
        return "Untitled"
    }
}

/// Centered caption. An HStack of spacers rather than a column with a stated
/// width — that column would paint `theme.panel` over the dimmer.
private struct HeaderLine: View {
    let text: String
    var body: some View {
        HStack(alignment: .center) {
            Spacer()
            Text(text, color: Theme.current.textDim)
            Spacer()
        }
    }
}

private struct Footer: View {
    let title: String
    let subtitle: String
    var body: some View {
        HStack(alignment: .center) {
            Spacer()
            VStack(alignment: .center, spacing: 6) {
                Text(title, color: Theme.current.textPrimary)
                if !subtitle.isEmpty {
                    Text(subtitle, color: Theme.current.textSecondary)
                }
                Text(
                    "Ctrl+Tab to cycle  ·  release to switch  ·  Esc to cancel",
                    color: Theme.current.textDim
                )
            }
            Spacer()
        }
    }
}

private struct WindowCard3D: View3D {
    let index: Int
    let count: Int
    let window: WindowInfo
    let selected: Int
    let layout: CatalogLayout3D

    func spatialElements() -> [SpatialElement] {
        let preview = model.preview(for: window)
        let card = Box3D(
            id: window.surfaceId,
            width: Switcher.cardWidth,
            height: Switcher.cardHeight,
            depth: Switcher.cardDepth,
            color: preview == nil
                ? (index == selected ? Theme.current.selected : cardTint(for: window))
                : Color(r: 1, g: 1, b: 1)
        )
        if let preview {
            return applyChrome(
                card.material3D(
                    .albumCover(
                        front: preview,
                        edgeColor: Color(r: 0.08, g: 0.07, b: 0.12)
                    )
                )
            )
        }
        return applyChrome(card)
    }

    private func applyChrome<V: View3D>(_ card: V) -> [SpatialElement] {
        card
            .shadow3D(radius: 18, offsetX: 8, offsetY: 14, opacity: 0.62)
            .reflection3D(
                planeY: -Switcher.cardHeight * 0.5 - 0.04,
                opacity: 0.30,
                fadeDistance: 1.55,
                blurRadius: 1.35
            )
            .catalog3D(
                index: index, itemCount: count, focusedIndex: selected,
                layout: layout
            )
            .animation3D(.spring(response: 0.28, dampingFraction: 0.72))
            .onHover3D { inside in
                if inside { model.select(surfaceId: window.surfaceId) }
            }
            .onTap3D {
                model.select(surfaceId: window.surfaceId)
                model.commit()
            }
            .spatialElements()
    }

    /// Stable colour for a window that has no screenshot yet, hashed from
    /// the app id so two terminals do not share a grey slab.
    private func cardTint(for window: WindowInfo) -> Color {
        var hash: UInt64 = 0xcbf29ce484222325
        let seed = window.appId.isEmpty ? window.title : window.appId
        for byte in seed.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return Color(
            hue: Float(hash % 3600) / 3600,
            saturation: 0.42,
            lightness: 0.16
        )
    }
}
