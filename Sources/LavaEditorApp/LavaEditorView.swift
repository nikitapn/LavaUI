import Foundation
import LavaText
import LavaUI

/// The window: tabs, the editor, and the bars that come and go around it.
struct LavaEditorView: View {
    @Bindable var session: EditorSession

    /// Height of the tab strip, which is also the title bar.
    private static let barHeight: Float = 38

    var body: some View {
        VStack(flexGrow: 1, spacing: 0) {
            tabStrip
            Divider()
            if session.pendingClose != nil { unsavedBar }
            if session.gotoOpen { gotoBar }
            if session.find.isOpen { findBar }
            if let notice = session.notice { noticeBar(notice) }
            editor
            Divider()
            statusBar
        }
        .background(Environment.current.theme.background)
        // Dropping files on the window is how most people open the second one.
        .onDrop { urls in session.open(urls) }
    }

    // MARK: - Tabs

    /// A row of real tabs rather than a combo box: an editor's documents are
    /// switched between constantly, and one click beats two. It scrolls
    /// horizontally, because the answer to "twenty files" is a scrollbar and
    /// not a menu.
    ///
    /// It is also the title bar. There is no separate strip above it: a
    /// window whose whole job is the text should not spend two rows of it
    /// saying so, and every browser reached the same conclusion about tabs.
    private var tabStrip: some View {
        HStack(height: .pt(Self.barHeight), alignment: .center, spacing: 0) {
            if WindowBridge.drawsOwnChrome {
                WindowControls()
                    .padding(.horizontal, 8)
            }
            ScrollView(.horizontal) {
                HStack(padding: 4, alignment: .center, spacing: 2) {
                    ForEach(Array(session.documents.enumerated()), id: \.offset) { entry in
                        tab(index: entry.offset, document: entry.element)
                    }
                }
            }
            Text("+", color: .muted, onClick: { session.newDocument() })
                .padding(8)
                .hoverBackground(Environment.current.theme.hover)
                .cornerRadius(4)
                .cursor(.pointer)
                .agentId("new-document")
        }
        .background(Environment.current.theme.panel)
        .windowDrag()
    }

    private func tab(index: Int, document: EditorDocument) -> some View {
        let theme = Environment.current.theme
        let isActive = index == session.activeIndex
        return HStack(
            padding: 6, alignment: .center, spacing: 6,
            onClick: { session.activate(index) }
        ) {
            // A dot, not an asterisk in the name: the name is what the user
            // scans for, and prefixing it moves every tab's first letter.
            Text(
                document.isModified ? "•" : " ",
                color: document.isModified ? .accent : .dim
            )
            Text(document.name, color: isActive ? .primary : .muted, lineLimit: 1)
                .frame(width: .pt(150))
                .clipped()
            Text("×", color: .dim, onClick: { session.requestClose(index) })
                .padding(2)
                .hoverBackground(theme.hover)
                .cornerRadius(3)
                .cursor(.pointer)
        }
        .background(isActive ? theme.background : theme.panel)
        .cornerRadius(4)
        .cursor(.pointer)
        .agentId("tab-\(index)")
    }

    // MARK: - The editor

    private var editor: some View {
        VStack(flexGrow: 1, spacing: 0) {
            if let error = session.active.loadError {
                // The file could not be read. Saying so beats an empty buffer,
                // which looks exactly like an empty file — and would overwrite
                // the real one on the next Ctrl+S.
                VStack(flexGrow: 1, padding: 24, alignment: .center, spacing: 8) {
                    Text(session.active.name, color: .primary)
                    Text(error, color: .muted)
                }
            } else {
                EditorView(
                    text: session.text,
                    rules: session.active.language.rules,
                    style: Language.codeStyle(),
                    showLineNumbers: session.showLineNumbers,
                    wraps: session.wraps,
                    visibleLines: 24,
                    search: session.find.isOpen ? session.find.search : TextSearch(),
                    controller: session.controller
                )
                .flexGrow(1)
                .agentId("editor")
            }
        }
    }

    // MARK: - Bars

    /// Find, and replace when it was asked for. One bar rather than two
    /// dialogs: replace is find with an extra field, and a modal that covers
    /// the text you are searching is the oldest complaint about find dialogs.
    private var findBar: some View {
        VStack(padding: 6, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                Text("Find", color: .muted).frame(width: .pt(56))
                TextField(
                    text: Binding(
                        get: { session.find.query },
                        set: { session.find.query = $0; session.runSearch() }
                    ),
                    placeholder: "search…",
                    autoFocus: true,
                    onSubmit: { session.findNext() }
                )
                .flexGrow(1)
                .agentId("find-query")
                Text(matchLabel, color: .dim).frame(width: .pt(90))
                Text("Aa", color: session.find.caseSensitive ? .accent : .dim, onClick: {
                    session.find.caseSensitive.toggle()
                    session.runSearch()
                })
                .padding(4)
                .hoverBackground(Environment.current.theme.hover)
                .cornerRadius(4)
                .cursor(.pointer)
                .agentId("find-case")
                Button("‹") { session.findPrevious() }.agentId("find-prev")
                Button("›") { session.findNext() }.agentId("find-next")
                Button("Done") { session.closeFind() }.agentId("find-close")
            }
            if session.find.showsReplace {
                HStack(alignment: .center, spacing: 6) {
                    Text("Replace", color: .muted).frame(width: .pt(56))
                    TextField(
                        text: Binding(get: { session.find.replacement }, set: { session.find.replacement = $0 }),
                        placeholder: "replacement…",
                        onSubmit: { session.replaceCurrent() }
                    )
                    .flexGrow(1)
                    .agentId("replace-text")
                    Button("Replace") { session.replaceCurrent() }.agentId("replace-one")
                    Button("Replace All") { session.replaceAll() }.agentId("replace-all")
                }
            }
        }
        .background(Environment.current.theme.panel)
    }

    private var matchLabel: String {
        let search = session.find.search
        guard search.isActive else { return "" }
        guard search.count > 0 else { return "no matches" }
        let current = search.currentIndex.map { $0 + 1 } ?? 0
        return "\(current) of \(search.count)"
    }

    private var gotoBar: some View {
        HStack(padding: 6, alignment: .center, spacing: 6) {
            Text("Go to line", color: .muted)
            TextField(
                text: Binding(get: { session.gotoLine }, set: { session.gotoLine = $0 }),
                placeholder: "line number",
                autoFocus: true,
                onSubmit: { session.performGoto() }
            )
            .frame(width: .pt(120))
            .agentId("goto-line")
            Button("Go") { session.performGoto() }.agentId("goto-go")
            Button("Cancel") { session.gotoOpen = false }.agentId("goto-cancel")
        }
        .background(Environment.current.theme.panel)
    }

    /// The unsaved-changes question, in the window rather than in a dialog.
    /// A zenity modal would work, but this keeps the file it is asking about
    /// visible behind it — which is the information the answer depends on.
    private var unsavedBar: some View {
        HStack(padding: 8, alignment: .center, spacing: 8) {
            Text("\(session.active.name) has unsaved changes.", color: .primary)
            Spacer()
            Button("Save and Close") { session.resolvePendingClose(save: true) }
                .agentId("unsaved-save")
            Button("Discard") { session.resolvePendingClose(save: false) }
                .agentId("unsaved-discard")
            Button("Cancel") { session.pendingClose = nil }.agentId("unsaved-cancel")
        }
        .background(Environment.current.theme.selectionFill)
    }

    private func noticeBar(_ notice: String) -> some View {
        HStack(padding: 6, alignment: .center, spacing: 8) {
            Text(notice, color: .muted).flexGrow(1).agentId("notice")
            Text("×", color: .dim, onClick: { session.notice = nil })
                .padding(4)
                .cursor(.pointer)
        }
        .background(Environment.current.theme.panel)
    }

    private var statusBar: some View {
        HStack(height: .pt(26), padding: 6, alignment: .center, spacing: 12) {
            Text(session.active.url?.path ?? "unsaved", color: .dim, lineLimit: 1)
                .flexGrow(1)
                .clipped()
                .agentId("status-path")
            if session.active.isModified {
                Text("modified", color: .accent).agentId("status-modified")
            }
            Text("\(lineCount) lines", color: .dim).agentId("status-lines")
            Text(session.active.language.title, color: .dim, onClick: { })
                .agentId("status-language")
            Text(session.wraps ? "wrap" : "no wrap", color: .dim, onClick: {
                session.wraps.toggle()
            })
            .cursor(.pointer)
            .agentId("status-wrap")
        }
        .background(Environment.current.theme.panel)
    }

    /// Counted off the UTF-8 bytes rather than by splitting the buffer:
    /// `split` on a 10 MB file allocates a substring per line, on every frame
    /// the status bar draws.
    private var lineCount: Int {
        let text = session.active.text
        if text.isEmpty { return 1 }
        return text.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
    }
}
