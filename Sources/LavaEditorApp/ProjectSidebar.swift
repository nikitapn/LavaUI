import Foundation
import LavaProjectCore
import LavaUI

/// Colours for what git says about a row.
struct GitMarkColors {
    let modified: Color
    let added: Color
    let deleted: Color
    let conflicted: Color

    init(_ appearance: EditorAppearance) {
        if appearance.usesPaper {
            modified = Color(rgb24: 0xa8_6a_14)
            added = Color(rgb24: 0x4d_8a_2c)
            deleted = Color(rgb24: 0xc4_3d_2f)
            conflicted = Color(rgb24: 0xb0_2f_86)
        } else {
            modified = Color(rgb24: 0xe2_b4_5c)
            added = Color(rgb24: 0x7c_c4_63)
            deleted = Color(rgb24: 0xe0_6c_67)
            conflicted = Color(rgb24: 0xd5_7c_d0)
        }
    }

    func color(_ mark: GitMark?, theme: Theme) -> Color {
        switch mark {
        case nil: return theme.textPrimary
        case .ignored?: return theme.textDim
        case .untracked?, .added?: return added
        case .modified?, .renamed?: return modified
        case .deleted?: return deleted
        case .conflicted?: return conflicted
        }
    }
}

/// What the sidebar is showing — VS Code's activity bar, as a row of icons
/// under the window's buttons.
enum SidebarView: String, CaseIterable {
    case explorer, search, sourceControl

    var title: String {
        switch self {
        case .explorer: return "Explorer"
        case .search: return "Search"
        case .sourceControl: return "Source Control"
        }
    }
}

/// The left of the window: the window's buttons, the row of views, and
/// whichever view is chosen. Each view is its own type in its own file —
/// `ProjectExplorer` below, `SearchPanel`, `SourceControlPanel`.
struct ProjectSidebar: View {
    @Bindable var session: EditorSession
    let project: ProjectSession
    let appearance: EditorAppearance

    var body: some View {
        VStack(flexGrow: 1, spacing: 0) {
            titleStrip
            ActivityBar(session: session, project: project, appearance: appearance)
            switch session.sidebarView {
            case .explorer:
                ProjectExplorer(session: session, project: project, appearance: appearance)
            case .search:
                SearchPanel(session: session, project: project, appearance: appearance)
            case .sourceControl:
                SourceControlPanel(session: session, project: project, appearance: appearance)
            }
        }
        .background(appearance.theme.panel)
    }

    /// The window's buttons and somewhere to drag it by, at the height of
    /// the tab strip beside it so the two read as one bar.
    private var titleStrip: some View {
        HStack(height: .pt(EditorTabs.stripHeight), padding: 0, alignment: .end, spacing: 0) {
            if WindowBridge.drawsOwnChrome {
                WindowControls(style: appearance.windowControls)
                    .padding(EdgeInsets(top: 0, leading: 20, bottom: 15, trailing: 14))
                    .flexShrink(0)
            }
            Spacer()
                .frame(height: .pt(EditorTabs.stripHeight), minWidth: 16)
                .windowDrag()
        }
    }
}

/// The folder's files: a header with the folder (or workspace) and branch,
/// then the tree.
struct ProjectExplorer: View {
    @Bindable var session: EditorSession
    let project: ProjectSession
    let appearance: EditorAppearance

    var body: some View {
        let theme = appearance.theme
        let font = session.fonts.tab ?? FontStore.default
        let rowH = ((font?.lineHeight ?? 18) + 8).rounded()
        let colors = GitMarkColors(appearance)
        return VStack(flexGrow: 1, spacing: 0) {
            header(theme: theme)
            ScrollView(.vertical, position: project.scroll) {
                LazyVStack(project.rows.indices, rowHeight: rowH) { index in
                    row(index, font: font, rowH: rowH, colors: colors, theme: theme)
                }
            }
            .flexGrow(1)
            .agentId("project-rows")
        }
    }

    private func header(theme: Theme) -> some View {
        HStack(padding: 0, alignment: .center, spacing: 8) {
            // The workspace when one is open — it is what the user named this
            // window's contents — and the folder otherwise.
            Text(session.workspaceName ?? project.name, color: .primary,
                 font: session.fonts.tabSelected, lineLimit: 1)
                .flexShrink(1)
                .agentId("project-name")
            Spacer()
            if let branch = project.branch {
                Text(branch, color: appearance.languageText, font: session.fonts.status, lineLimit: 1)
                    .padding(EdgeInsets(top: 3, leading: 9, bottom: 3, trailing: 9))
                    .background(appearance.languageFill)
                    .cornerRadius(10)
                    .flexShrink(1)
                    .agentId("project-branch")
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 10))
    }

    private func row(
        _ index: Int, font: UIFont?, rowH: Float, colors: GitMarkColors, theme: Theme
    ) -> some View {
        let row = project.rows[index]
        let mark = project.decorations.mark(for: row.node)
        let isSelected = project.selected == row.node.path
        let session = self.session
        let project = self.project
        return Canvas(
            label: "project-row",
            width: .pct(100), height: .pt(rowH),
            onTap: {
                if row.node.isDirectory {
                    project.selected = row.node.path
                    project.toggle(row.node.path)
                } else {
                    session.openFromTree(row.node.path)
                }
            }
        ) { list, frame in
            guard let font else { return }
            if isSelected {
                list.roundedRect(
                    x: frame.x + 6, y: frame.y + 1, w: frame.w - 12, h: frame.h - 2,
                    color: theme.selectionFill, radius: 5
                )
            }
            let indent = frame.x + 12 + Float(row.depth) * 14
            let midY = frame.y + frame.h / 2
            let ink = colors.color(mark, theme: theme)
            if row.node.isDirectory {
                // A chevron: right when closed, down when open.
                let c = theme.textSecondary
                if row.isExpanded {
                    list.line(x1: indent, y1: midY - 2, x2: indent + 4, y2: midY + 2, color: c)
                    list.line(x1: indent + 4, y1: midY + 2, x2: indent + 8, y2: midY - 2, color: c)
                } else {
                    list.line(x1: indent + 2, y1: midY - 4, x2: indent + 6, y2: midY, color: c)
                    list.line(x1: indent + 6, y1: midY, x2: indent + 2, y2: midY + 4, color: c)
                }
            }
            let textX = indent + 14
            let textY = frame.y + (frame.h - font.lineHeight) / 2
            var right = frame.x + frame.w - 14
            if let letter = mark?.letter, !row.node.isDirectory {
                let w = font.shapedRun(letter).width
                right -= w
                list.text(letter, x: right - 4, y: textY, w: w + 8, h: font.lineHeight,
                          color: ink, font: font)
                right -= 8
            } else if mark != nil, mark != .ignored, row.node.isDirectory {
                // A folder says only that something below it changed.
                list.roundedRect(x: right - 6, y: midY - 3, w: 6, h: 6, color: ink, radius: 3)
                right -= 12
            }
            list.pushClip(x: textX, y: frame.y, w: max(0, right - textX), h: frame.h)
            list.text(row.node.name, x: textX - 4, y: textY, w: right - textX, h: font.lineHeight,
                      color: ink, font: font)
            list.popClip()
        }
        .hoverBackground(theme.hover)
        .cursor(.pointer)
    }
}
