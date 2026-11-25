import Foundation
import LavaText
import LavaUI

/// The window: tabs, the editor, and the bars that come and go around it.
struct LavaEditorView: View {
    @Bindable var session: EditorSession
    let appearance: EditorAppearance
    /// Right-click menu on the status-bar path.
    @State private var pathMenuOpen = false

    var body: some View {
        VStack(flexGrow: 1, spacing: 0) {
            // With a project open the sidebar runs the full height of the
            // window and carries its buttons, and the tabs belong to the
            // document column beside it — as in VS Code. Tabs across the top
            // of both would put the tree under a strip of files it does not
            // own.
            if let project = session.project, session.showsSidebar {
                HSplitView(
                    fraction: $session.sidebarFraction,
                    minLeading: 160,
                    minTrailing: 360
                ) {
                    ProjectSidebar(session: session, project: project, appearance: appearance)
                        .agentId("project")
                } trailing: {
                    VStack(flexGrow: 1, spacing: 0) {
                        EditorTabs(session: session, appearance: appearance, showsWindowControls: false)
                        documentColumn
                    }
                }
            } else {
                EditorTabs(session: session, appearance: appearance)
                documentColumn
            }
            statusBar(appearance)
        }
        .background(appearance.theme.panel)
        .overlayLayer {
            Canvas(label: "session-checkpoint", width: .pct(100), height: .pct(100)) { _, _ in
                session.checkpointSession()
            }
        }
        // Dropping files on the window is how most people open the second one.
        .onDrop { urls in session.open(urls) }
    }

    // MARK: - The editor

    /// The document, and the terminal panel under it when that is open.
    ///
    /// The split is always there and collapses while the panel is closed:
    /// in an `if`, the editor would be a new view on every toggle and would
    /// draw a frame scrolled to the top before its place could be restored.
    private var documentColumn: some View {
        VSplitView(
            fraction: Binding(
                get: { session.terminal.editorFraction },
                set: { session.terminal.editorFraction = $0 }
            ),
            minTop: 120, minBottom: 80,
            collapsesBottom: !session.terminal.isOpen
        ) {
            documentStack
        } bottom: {
            TerminalPanelView(session: session, appearance: appearance)
                .agentId("terminal-panel")
        }
    }

    private var documentStack: some View {
        let showsFind = session.active.preview == nil && session.find.isOpen
        return VStack(flexGrow: 1, spacing: 0) {
            if let document = session.closingDocument { unsavedBar(document) }
            if session.active.preview == nil, session.gotoOpen { gotoBar }
            if let notice = session.notice { noticeBar(notice) }
            editor(appearance)
                .overlay(
                    alignment: .topTrailing, insets: EdgeInsets(top: 12, trailing: 32),
                    style: showsFind ? OverlayStyle(cornerRadius: 8, padding: 0) : nil
                ) {
                    if showsFind { findBar }
                }
        }
    }

    private func editor(_ appearance: EditorAppearance) -> some View {
        let chat = session.inlineChat.flatMap { $0.documentID == session.active.id ? $0 : nil }
        return VStack(flexGrow: 1, spacing: 0) {
            if let preview = session.active.preview {
                switch preview.content {
                #if canImport(LavaEditorExtensionAPI)
                case .surface(let surface):
                    if let editor = session.imageEditor, let font = session.documentFont ?? FontStore.default {
                        EmbeddedPreviewCanvas(surface: surface, editor: editor, font: font,
                                              foreground: appearance.documentTheme.textPrimary)
                    }
                #endif
                case .terminal(let terminal):
                    AgentTerminalView(session: session, terminal: terminal, appearance: appearance)
                case .chat(let transcript):
                    SessionTranscriptView(session: session, transcript: transcript, appearance: appearance)
                case .markdown(let text):
                    ScrollView(.vertical) {
                        VStack(padding: 20, spacing: 0) { MarkdownView(text, font: session.documentFont) }
                    }
                    .theme(appearance.documentTheme)
                    .agentId("document-preview")
                case .message(let text):
                    Text(text, color: .muted).padding(20)
                }
            } else if let diff = session.visibleDiff {
                DiffPane(session: session, model: diff, appearance: appearance, style: documentStyle(appearance))
                    .flexGrow(1)
                    .theme(appearance.documentTheme)
            } else if let error = session.active.loadError {
                // The file could not be read. Saying so beats an empty buffer,
                // which looks exactly like an empty file — and would overwrite
                // the real one on the next Ctrl+S.
                VStack(flexGrow: 1, padding: 24, alignment: .center, spacing: 12) {
                    Text(session.active.name, color: .primary)
                    Text(error, color: .muted)
                }
            } else {
                let indentation = session.documentIndentation
                EditorView(
                    text: session.text,
                    isReadOnly: session.active.hasInvalidUTF8,
                    highlighter: session.active.language.highlighter,
                    indentation: session.active.indentation,
                    indentationFormat: indentation,
                    style: documentStyle(appearance),
                    font: session.documentFont(tabSize: indentation.tabSize),
                    showLineNumbers: session.showLineNumbers,
                    wraps: session.wraps,
                    visibleLines: 24,
                    search: session.find.isOpen ? session.find.search : TextSearch(),
                    decorations: session.languageDecorations(),
                    lineMarks: session.changeMarks(appearance),
                    lineActions: session.currentLineActions,
                    onDecorationTap: { session.notice = $0.message },
                    controller: session.controller,
                    onZoom: { session.zoom(by: $0) },
                    semanticHighlights: session.languageHighlights(),
                    hoverCard: session.hoverCard,
                    completion: session.completionList(),
                    onCompletionPick: { session.completionPicked($0) },
                    onPointerOffset: { session.pointerMoved(to: $0) },
                    onKey: { session.editorKey($0) },
                    onFollow: { session.follow(at: $0) },
                    lineGaps: chat.map { [EditorLineGap(line: session.chatAnchor.line, rows: $0.rows)] } ?? [],
                    stateStore: session.editorStates,
                    stateKey: session.active.id,
                    zone: session.chatAnchor
                )
                .flexGrow(1)
                .theme(appearance.documentTheme)
                .agentId("editor")
                .editorZone(session.chatAnchor, rows: chat?.rows ?? 0, isPresented: chat != nil) {
                    if let chat {
                        InlineChatView(session: session, chat: chat, appearance: appearance)
                    }
                }
            }
        }
        .padding(.top, 6)
        .background(appearance.theme.inset)
    }

    private func documentStyle(_ appearance: EditorAppearance) -> CodeStyle {
        let theme = appearance.theme
        var style = Language.codeStyle(theme: theme)
        style.gutterText = appearance.usesPaper ? theme.textDim : theme.textSecondary
        style.gutterBackground = theme.inset
        style.currentLine = appearance.currentLine
        style.activeGutterText = theme.accent
        style.activeGutterFont = session.documentBoldFont
        style.minimumGutterWidth = 68
        style.scrollbarColor = appearance.thumb
        style.scrollbarWidth = 7
        style.scrollbarSpansGutter = true
        if !session.active.hasInvalidUTF8 && session.active.isLoaded {
            style.placeholder = "Empty file. Start typing."
        }
        return style
    }

    // MARK: - Bars

    private var findBar: some View {
        let theme = appearance.theme
        let hasMatches = session.find.search.count > 0
        let noResults = session.find.search.isActive && !hasMatches
        return VStack(padding: 4, spacing: 4) {
            HStack(alignment: .center, spacing: 2) {
                TextField(
                    text: Binding(
                        get: { session.find.query },
                        set: { session.find.query = $0; session.runSearch() }
                    ),
                    placeholder: "Find in document",
                    font: session.fonts.tab,
                    autoFocus: true,
                    selectionOnFocus: .all,
                    onCancel: { session.closeFind() },
                    onSubmit: { session.findNext() }
                )
                .frame(width: .pt(200))
                .flexShrink(1)
                .focused($session.findQueryFocused)
                .agentId("find-query")
                Text(matchLabel, color: noResults ? appearance.modified : theme.textSecondary,
                     font: session.fonts.status, lineLimit: 1)
                    .padding(EdgeInsets(leading: 6))
                    .frame(width: .pt(90))
                    .agentId("find-status")
                Text("Aa", color: session.find.caseSensitive ? .accent : .secondary, font: session.fonts.status,
                     align: .center, onClick: {
                         session.find.caseSensitive.toggle()
                         session.runSearch()
                     })
                    .frame(width: .pt(26), height: .pt(26))
                    .hoverBackground(theme.hover)
                    .cornerRadius(4)
                    .cursor(.pointer)
                    .tooltip("Match Case")
                    .agentId("find-case")
                findIcon(.arrowUp, enabled: hasMatches, tip: "Previous Match", id: "find-prev") {
                    session.findPrevious()
                }
                findIcon(.arrowDown, enabled: hasMatches, tip: "Next Match", id: "find-next") {
                    session.findNext()
                }
                findIcon(.cross, enabled: true, tip: "Close", id: "find-close") {
                    session.closeFind()
                }
            }
            if session.find.showsReplace, !session.active.hasInvalidUTF8 {
                HStack(alignment: .center, spacing: 4) {
                    TextField(
                        text: Binding(get: { session.find.replacement }, set: { session.find.replacement = $0 }),
                        placeholder: "Replace with",
                        font: session.fonts.tab,
                        onCancel: { session.closeFind() },
                        onSubmit: { session.replaceCurrent() }
                    )
                    .flexGrow(1)
                    .agentId("replace-text")
                    Button("Replace", font: session.fonts.status, isEnabled: hasMatches) { session.replaceCurrent() }
                        .agentId("replace-one")
                    Button("Replace All", font: session.fonts.status, isEnabled: hasMatches) { session.replaceAll() }
                        .agentId("replace-all")
                }
            }
        }
        .agentId("find-bar")
    }

    private func findIcon(
        _ mark: Mark.Kind, enabled: Bool, tip: String, id: String, action: @escaping () -> Void
    ) -> some View {
        let theme = appearance.theme
        return HStack(width: .pt(26), height: .pt(26), alignment: .center, spacing: 0,
                      onClick: enabled ? action : nil) {
            Spacer()
            Mark(mark, size: mark == .cross ? 10 : 12, color: enabled ? theme.textSecondary : theme.textDim)
            Spacer()
        }
        .hoverBackground(enabled ? theme.hover : .clear)
        .cornerRadius(4)
        .cursor(enabled ? .pointer : .arrow)
        .tooltip(tip)
        .agentId(id)
    }

    private var matchLabel: String {
        let search = session.find.search
        guard search.isActive else { return "" }
        guard let current = search.currentIndex else { return "No results" }
        return "\(current + 1) of \(search.count)"
    }

    private var gotoBar: some View {
        HStack(padding: 6, alignment: .center, spacing: 6) {
            Text("Go to line", color: .muted)
            TextField(
                text: Binding(get: { session.gotoLine }, set: { session.gotoLine = $0 }),
                placeholder: "line number",
                font: session.fonts.tab,
                autoFocus: true,
                onSubmit: { session.performGoto() }
            )
            .frame(width: .pt(120))
            .focused($session.gotoFocused)
            .agentId("goto-line")
            Button("Go") { session.performGoto() }.agentId("goto-go")
            Button("Cancel") { session.closeGoto() }.agentId("goto-cancel")
        }
        .background(Environment.current.theme.panel)
    }

    /// The unsaved-changes question, in the window rather than in a dialog.
    /// A modal in another window would work, but this keeps the file it is asking about
    /// visible behind it — which is the information the answer depends on.
    private func unsavedBar(_ document: EditorDocument) -> some View {
        HStack(padding: 8, alignment: .center, spacing: 8) {
            Text("\(document.name) has unsaved changes.", color: .primary)
            Spacer()
            Button("Save and Close") { session.resolvePendingClose(save: true) }
                .agentId("unsaved-save")
            Button("Discard") { session.resolvePendingClose(save: false) }
                .agentId("unsaved-discard")
            Button("Cancel") { session.cancelPendingClose() }.agentId("unsaved-cancel")
        }
        .background(Environment.current.theme.selectionFill)
    }

    private func noticeBar(_ notice: String) -> some View {
        HStack(padding: 6, alignment: .center, spacing: 8) {
            Text(notice, color: .muted).flexGrow(1).agentId("notice")
            HStack(padding: 4, alignment: .center, onClick: { session.notice = nil }) {
                Mark(.cross, size: 8, color: .dim)
            }
                .hoverBackground(Environment.current.theme.hover)
                .cornerRadius(4)
                .cursor(.pointer)
        }
        .background(Environment.current.theme.panel)
    }

    private func statusBar(_ appearance: EditorAppearance) -> some View {
        let theme = appearance.theme
        return HStack(height: .pt(46), padding: 0, alignment: .center, spacing: 6) {
            if let preview = session.active.preview {
                Text(preview.tabTitle, color: theme.textSecondary, font: session.fonts.status)
                Spacer()
            } else {
                pathLabel(theme: theme)
                if session.active.hasInvalidUTF8, session.active.isLoaded {
                    Text("Read-only · invalid UTF-8", color: theme.accent,
                         font: session.fonts.status, lineLimit: 1)
                        .flexShrink(1)
                        .agentId("status-invalid-utf8")
                }
                lineStatus(theme: theme)
                    .padding(.horizontal, 6)
                    .agentId("status-lines")
                Text(session.active.language.title, color: appearance.languageText, font: session.fonts.status)
                    .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                    .background(appearance.languageFill)
                    .cornerRadius(12)
                    .agentId("status-language")
                wrapButton(appearance)
            }
        }
        .padding(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 14))
        .background(theme.panel)
    }

    private func lineStatus(theme: Theme) -> some View {
        let count = session.activeLineCount
        let formattedCount = count.formatted()
        let font = session.fonts.status ?? FontStore.default
        let widestDigit = (0...9).map(String.init).max {
            (font?.shapedRun($0).width ?? 0) < (font?.shapedRun($1).width ?? 0)
        } ?? "0"
        let lineSample = formattedCount.map { $0.isNumber ? widestDigit : String($0) }.joined()
        let width = font?.shapedRun("Ln \(lineSample) · \(formattedCount) lines").width ?? 126
        // Caret moves already redraw the editor. Read its line at paint time so
        // cursor navigation can update this label without rebuilding the window.
        return Canvas(label: "Line status", width: .pt(width + 4),
                      height: .pt(font?.lineHeight ?? 16)) { list, frame in
            guard let font else { return }
            let line = min(count, session.controller.caretLine() ?? 1)
            let label = "Ln \(line.formatted()) · \(formattedCount) lines"
            let labelWidth = font.shapedRun(label).width
            list.text(label, x: frame.x + frame.w - labelWidth - 4, y: frame.y,
                      w: frame.w, h: frame.h, color: theme.textSecondary, font: font)
        }
    }

    private func wrapButton(_ appearance: EditorAppearance) -> some View {
        let theme = appearance.theme
        let color = session.wraps ? appearance.languageText : theme.textSecondary
        return HStack(padding: 0, alignment: .center, spacing: 6, onClick: {
            session.wraps.toggle()
        }) {
            Mark(.textWrap, size: 13, color: color, lineWidth: 1.55)
            Text(session.wraps ? "Wrap" : "No wrap", color: color,
                 font: session.fonts.statusEmphasis)
        }
        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        .background(session.wraps ? appearance.languageFill : .clear)
        .hoverBackground(theme.hover)
        .cornerRadius(15)
        .border(theme.border)
        .cursor(.pointer)
        .agentId("status-wrap")
    }

    /// The path owns the right-click menu and keeps the filename emphasized.
    private func pathLabel(theme: Theme) -> some View {
        let url = session.active.url
        return HStack(
            flexGrow: 1,
            padding: 3,
            alignment: .center,
            spacing: 6,
            onPointer: { _, button in
                guard button == PointerButton.right else { return }
                pathMenuOpen = true
            }
        ) {
            Mark(.document, size: 14, color: theme.textSecondary, lineWidth: 1.55)
                .flexShrink(0)
            HStack(padding: 0, alignment: .center, spacing: 0) {
                if let url {
                    let directory = url.deletingLastPathComponent().path
                    Text(directory == "/" ? directory : directory + "/",
                         color: theme.textSecondary, font: session.fonts.status, lineLimit: 1)
                        .flexShrink(2)
                }
                Text(url?.lastPathComponent ?? "Unsaved",
                     color: theme.textPrimary, font: session.fonts.statusEmphasis, lineLimit: 1)
                    .flexShrink(1)
            }
            .flexShrink(1)
        }
        .flexShrink(1)
        .clipped()
        .hoverBackground(theme.hover)
        .cornerRadius(6)
        .cursor(.pointer)
        .agentId("status-path")
        .overlay(
            isPresented: $pathMenuOpen,
            alignment: .above,
            style: {
                var style = MenuBarStyle.standard(theme: theme).overlayStyle
                style.minWidth = 200
                return style
            }()
        ) {
            pathMenu(hasPath: url != nil, theme: theme)
        }
    }

    private func pathMenu(hasPath: Bool, theme: Theme) -> some View {
        MenuDropdownPanel(
            entries: [
                .item(MenuItemModel(
                    id: MenuID("path.reveal"),
                    title: "Open File Location",
                    isEnabled: hasPath
                )),
                .item(MenuItemModel(
                    id: MenuID("path.copy"),
                    title: "Copy File Path",
                    isEnabled: hasPath
                )),
            ],
            onActivate: { id in
                switch id.raw {
                case "path.reveal": session.revealActiveInFileManager()
                case "path.copy": session.copyActivePath()
                default: break
                }
                pathMenuOpen = false
            },
            style: .standard(theme: theme)
        )
    }
}
