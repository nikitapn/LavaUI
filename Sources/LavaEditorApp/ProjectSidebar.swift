import Foundation
import LavaExplorerCore
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
    case explorer, search, sourceControl, agents

    var title: String {
        switch self {
        case .explorer: return "Explorer"
        case .search: return "Search"
        case .sourceControl: return "Source Control"
        case .agents: return "Agents"
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
            case .agents:
                AgentsPanel(session: session, project: project, appearance: appearance)
            }
        }
        .background(appearance.theme.panel)
    }

    /// The window's buttons and somewhere to drag it by, at the height of
    /// the tab strip beside it so the two read as one bar.
    private var titleStrip: some View {
        HStack(alignment: .center, spacing: 0) {
            if WindowBridge.drawsOwnChrome {
                WindowControls(style: appearance.windowControls)
                .flexShrink(0)
            }
            Spacer()
                .frame(minWidth: 32)
            BranchChip(session: session, project: project, appearance: appearance)
                .agentId("project-branch")
        }
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
        .windowDrag()
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
        let rowH = session.projectRowHeight
        let colors = GitMarkColors(appearance)
        // Read here, in the body, and handed to the rows: they are built by
        // the lazy list as it lays out, outside this body's observation, so
        // a selection read only there was never observed — the arrows moved
        // it and the highlight stayed where it was until something else
        // rebuilt the tree.
        let selected = project.selected
        // The same for the row being renamed, which swaps that row for a field.
        let renaming = project.renaming
        return VStack(flexGrow: 1, spacing: 0) {
            header(theme: theme)
            ScrollView(.vertical, position: project.scroll) {
                LazyVStack(project.rows, rowHeight: rowH) { entry in
                    row(entry, isSelected: entry.node.path == selected,
                        isRenaming: entry.node.path == renaming,
                        font: font, rowH: rowH, colors: colors, theme: theme)
                }
            }
            .flexGrow(1)
            .onFrame { [project] frame in project.viewportHeight = frame.h }
            // A click on a row gives the tree the keyboard, as in any file
            // tree; the arrows then walk it (`ProjectTree.step`).
            .focusable(onKey: { [session, project] event in
                Self.handleKey(event, session: session, project: project, rowHeight: rowH)
            }, onChar: { [session, project] character in
                Self.jump(character, session: session, project: project, rowHeight: rowH)
            })
            .focused(Binding(get: { project.treeFocused }, set: { project.treeFocused = $0 }))
            .agentId("project-rows")
        }
    }

    /// Arrows, Home/End and the page keys move and fold (`ProjectTree.step`),
    /// and a file they land on opens in the preview tab. Enter keeps that
    /// file (the tab stops being a preview) and hands the keyboard to it, or
    /// folds a folder; Space folds a folder too.
    private static func handleKey(
        _ event: KeyEvent, session: EditorSession, project: ProjectSession, rowHeight: Float
    ) -> Bool {
        // Anything held with the key is somebody else's shortcut.
        guard event.mods == 0 else { return false }
        switch event.key {
        case KeyCode.f2:
            session.beginRename()
            return true
        case KeyCode.delete:
            session.trashSelected()
            // The row that took its place is shown, as one the arrows reach is.
            if let path = project.selected,
               project.rows.contains(where: { $0.node.path == path && !$0.node.isDirectory }) {
                session.open([project.tree.url(of: path)], mode: .treeClick)
            }
            return true
        default:
            break
        }
        // A key that moves the selection ends a typed-name run.
        project.typeAhead.reset()
        let page = max(1, Int(project.viewportHeight / max(1, rowHeight)) - 1)
        let key: ProjectTreeKey
        switch event.key {
        case KeyCode.up: key = .up
        case KeyCode.down: key = .down
        case KeyCode.left: key = .left
        case KeyCode.right: key = .right
        case KeyCode.home: key = .home
        case KeyCode.end: key = .end
        case KeyCode.pageUp: key = .pageUp(rows: page)
        case KeyCode.pageDown: key = .pageDown(rows: page)
        case KeyCode.enter, KeyCode.space:
            guard let path = project.selected,
                  let row = project.rows.first(where: { $0.node.path == path })
            else { return true }
            if row.node.isDirectory {
                project.toggle(path)
            } else if event.key == KeyCode.enter {
                session.open([project.tree.url(of: path)], mode: .treeDoubleClick)
                session.controller.focus()
            }
            return true
        default:
            return false
        }
        let step = ProjectTree.step(key, from: project.selected, in: project.rows)
        project.apply(step, rowHeight: rowHeight)
        // A file the arrows land on is shown at once, in the preview tab, so
        // the editor beside the tree always says which row the keys are on —
        // no second "keyboard is here" outline to tell apart from the
        // selection. The keyboard stays on the tree.
        if case .select(let path) = step,
           project.rows.contains(where: { $0.node.path == path && !$0.node.isDirectory }) {
            session.open([project.tree.url(of: path)], mode: .treeClick)
        }
        return true
    }

    /// A letter typed at the tree goes to the row whose name starts with what
    /// has been typed (`ProjectTypeAhead`); a file it reaches is shown, as the
    /// arrows show one. Whitespace is left alone — Space folds a folder.
    private static func jump(
        _ character: Character, session: EditorSession, project: ProjectSession, rowHeight: Float
    ) -> Bool {
        guard !character.isWhitespace, !character.isNewline else { return false }
        guard let path = project.typeAhead.type(
            character, at: FrameScheduler.now(), from: project.selected, in: project.rows
        ) else { return true }
        if path == project.selected { return true }
        project.apply(.select(path), rowHeight: rowHeight)
        if project.rows.contains(where: { $0.node.path == path && !$0.node.isDirectory }) {
            session.open([project.tree.url(of: path)], mode: .treeClick)
        }
        return true
    }

    private func header(theme: Theme) -> some View {
        HStack(padding: 0, alignment: .center, spacing: 8) {
            // The workspace when one is open — it is what the user named this
            // window's contents — and the folder otherwise.
            Text(session.workspaceName ?? project.name, color: .primary,
                 font: session.fonts.tabSelected, lineLimit: 1)
                .agentId("project-name")
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 10))
    }

    private func row(
        _ row: ProjectRow, isSelected: Bool, isRenaming: Bool, font: UIFont?, rowH: Float, colors: GitMarkColors,
        theme: Theme
    ) -> AnyView {
        if isRenaming {
            return AnyView(renameField(row, font: font, rowH: rowH, theme: theme))
        }
        let mark = project.decorations.mark(for: row.node)
        let session = self.session
        let imageEditor = session.imageEditor
        let project = self.project
        return AnyView(Canvas(
            label: "project-row",
            width: .pct(100), height: .pt(rowH),
            onGesture: { gesture in
                guard gesture.phase == .began, gesture.button == PointerButton.left else { return }
                if row.node.isDirectory {
                    project.selected = row.node.path
                    project.toggle(row.node.path)
                } else {
                    session.openFromTree(row.node.path, clicks: gesture.clickCount)
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
            if !row.node.isDirectory {
                // In the column a folder's chevron takes, so a file's name lines
                // up with its sibling folders' names.
                FileIcons.draw(row.node.name, in: list, x: indent - 3, y: midY - 7, size: 14,
                               theme: theme, editor: imageEditor)
            }
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
        // The renderer's chip, the same shape as the selection fill. A
        // selected row states none: both go out in one draw list, so the
        // selection never shows with a hover wash over it.
        .hoverBackground(isSelected ? .clear : theme.hover)
        .hoverInset(horizontal: 6, vertical: 1)
        .cornerRadius(5)
        .hoverSnap()
        .cursor(.pointer))
    }

    /// The row while its name is edited (F2): the name in a field where the
    /// name was, the part before the extension selected. Enter renames,
    /// Escape leaves it, and a click elsewhere keeps a changed name.
    private func renameField(_ row: ProjectRow, font: UIFont?, rowH: Float, theme: Theme) -> some View {
        let session = self.session
        let project = self.project
        let stem = Rename.stemLength(of: row.node.name, isDirectory: row.node.isDirectory)
        // Where the name stands in a row (`indent + 14`), less the field's
        // own inset, so the text does not jump when the field appears.
        let lead = 12 + Float(row.depth) * 14 + 14 - 8
        return HStack(spacing: 0) {
            TextField(
                text: Binding(get: { project.renameText }, set: { project.renameText = $0 }),
                font: font, autoFocus: true, selectionOnFocus: .leading(stem),
                onCancel: { session.endRename(keeping: false) },
                onSubmit: { session.commitRename() }
            )
            .focused(Binding(get: { project.renaming == row.node.path }, set: { focused in
                if !focused, project.renaming == row.node.path { session.endRename(keeping: true) }
            }))
            .flexGrow(1)
            .agentId("project-rename")
        }
        .padding(EdgeInsets(top: 1, leading: lead, bottom: 1, trailing: 8))
        .frame(height: .pt(rowH))
    }
}

/// The branch, in a sidebar header. A click opens the branch picker.
/// Shown while detached too, as "detached" — that is when switching back to
/// a branch is most wanted.
struct BranchChip: View {
    let session: EditorSession
    let project: ProjectSession
    let appearance: EditorAppearance

    var body: some View {
        if project.isInRepository {
            let session = self.session
            Text(project.branch ?? "detached", color: appearance.languageText, font: session.fonts.status,
                 hoverFill: appearance.languageFill.opacity(0.7), cornerRadius: 10, lineLimit: 1,
                 onClick: { session.openBranchPicker() })
                .padding(EdgeInsets(top: 3, leading: 9, bottom: 3, trailing: 9))
                .background(appearance.languageFill)
                .cornerRadius(10)
                .flexShrink(1)
                .cursor(.pointer)
                .tooltip("Switch Branch or Worktree")
        }
    }
}
