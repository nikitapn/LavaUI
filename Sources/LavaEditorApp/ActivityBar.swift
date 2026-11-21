import Foundation
import LavaUI

/// The row of views at the top of the sidebar — VS Code's activity bar,
/// laid across rather than down, as VS Code itself does once the sidebar is
/// the only thing on that side.
struct ActivityBar: View {
    @Bindable var session: EditorSession
    let project: ProjectSession
    let appearance: EditorAppearance

    /// Glyphs as SVG path data in a 24-unit box — Lucide's `files`, `search`
    /// and `git-branch` (ISC licence). Strings rather than hand-placed
    /// lines, so a glyph can be swapped for a design's without redrawing it.
    static func glyph(_ view: SidebarView) -> [IconShape] {
        switch view {
        case .explorer:
            return [
                .path("M15 2h-4a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V8"),
                .path("M16.706 2.706A2.4 2.4 0 0 0 15 2v5a1 1 0 0 0 1 1h5a2.4 2.4 0 0 0-.706-1.706z"),
                .path("M5 7a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h8a2 2 0 0 0 1.732-1"),
            ]
        case .search:
            return [.path("m21 21-4.34-4.34"), .circle(cx: 11, cy: 11, r: 8)]
        case .sourceControl:
            return [
                .path("M6 3v12"),
                .circle(cx: 18, cy: 6, r: 3),
                .circle(cx: 6, cy: 18, r: 3),
                .path("M18 9a9 9 0 0 1-9 9"),
            ]
        }
    }

    var body: some View {
        let theme = appearance.theme
        return HStack(height: .pt(38), padding: 0, alignment: .center, spacing: 4) {
            ForEach(SidebarView.allCases, id: \.self) { view in
                item(view, theme: theme)
            }
            Spacer()
        }
        .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
    }

    private func item(_ view: SidebarView, theme: Theme) -> some View {
        let selected = session.sidebarView == view
        let badge = view == .sourceControl ? project.changes.count : 0
        let session = self.session
        let shapes = Self.glyph(view)
        let accent = theme.accent
        let ink = selected ? theme.textPrimary : theme.textSecondary
        let badgeFont = session.fonts.status ?? FontStore.default
        return Canvas(
            label: "activity-\(view.rawValue)", width: .pt(36), height: .pt(32),
            onTap: { session.showSidebar(view) }
        ) { list, frame in
            if selected {
                list.roundedRect(x: frame.x, y: frame.y, w: frame.w, h: frame.h,
                                 color: theme.selectionFill, radius: 7)
            }
            let size: Float = 18
            list.strokeIcon(
                shapes, x: frame.x + (frame.w - size) / 2, y: frame.y + (frame.h - size) / 2,
                size: size, color: ink, strokeWidth: 2
            )
            // How many files have changes, on the git glyph — the number
            // that says whether there is anything to commit.
            if badge > 0, let font = badgeFont {
                let label = badge > 99 ? "99+" : String(badge)
                let w = max(14, font.shapedRun(label).width + 8)
                let h: Float = 14
                let bx = frame.x + frame.w - w + 2, by = frame.y + frame.h - h + 1
                list.roundedRect(x: bx, y: by, w: w, h: h, color: accent, radius: h / 2)
                let tw = font.shapedRun(label).width
                list.text(label, x: bx + (w - tw) / 2 - 4, y: by + (h - font.lineHeight) / 2,
                          w: w, h: font.lineHeight, color: .white, font: font)
            }
        }
        .hoverBackground(theme.hover)
        .cornerRadius(7)
        .cursor(.pointer)
        .tooltip(view.title)
        .agentId("activity-\(view.rawValue)")
    }
}
