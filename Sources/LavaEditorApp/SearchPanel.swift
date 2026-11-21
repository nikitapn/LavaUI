import Foundation
import LavaProjectCore
import LavaUI

/// Project-wide search. Only visible rows become views, including the file
/// headings, so collapsing a file does not change the cost of painting a row.
struct SearchPanel: View {
    @Bindable var session: EditorSession
    let project: ProjectSession
    let appearance: EditorAppearance

    private var model: SearchPanelModel { session.projectSearch }
    private var root: URL { project.tree.root }
    private var theme: Theme { appearance.theme }

    var body: some View {
        let font = session.fonts.tab ?? FontStore.default
        let rowHeight = ((font?.lineHeight ?? 18) + 8).rounded()
        return VStack(flexGrow: 1, spacing: 0) {
            controls
            if model.root == root, let result = model.result {
                let rows = model.rows
                ScrollView(.vertical, position: model.scroll) {
                    LazyVStack(rows.indices, rowHeight: rowHeight) { index in
                        switch rows[index] {
                        case .file(let file):
                            fileRow(result.files[file], font: font, height: rowHeight)
                        case .line(let file, let line):
                            lineRow(result.files[file].lines[line], path: result.files[file].path,
                                    font: font, height: rowHeight)
                        }
                    }
                }
                .flexGrow(1)
                .agentId("search-results")
            } else {
                Spacer()
            }
        }
        .agentId("search-panel")
    }

    private var controls: some View {
        VStack(spacing: 7) {
            Text("Search", color: .primary, font: session.fonts.tabSelected)
            HStack(alignment: .center, spacing: 2) {
                field(\.query, placeholder: "Search", id: "search-query", autoFocus: true)
                    .focused(Binding(get: { model.queryFocused }, set: { model.queryFocused = $0 }))
                toggle("Aa", "Match Case", id: "search-case", option: \.caseSensitive)
                toggle("ab", "Match Whole Word", id: "search-word", option: \.wholeWord)
                toggle(".*", "Use Regular Expression", id: "search-regex", option: \.regularExpression)
            }
            field(\.include, placeholder: "Files to include", id: "search-include")
                .tooltip("Files to include, separated by commas")
            field(\.exclude, placeholder: "Files to exclude", id: "search-exclude")
                .tooltip("Files to exclude, separated by commas")
            Text(model.summary(for: root), color: .muted, font: session.fonts.status, lineLimit: 2)
                .agentId("search-summary")
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .flexShrink(0)
    }

    private func field(
        _ key: WritableKeyPath<ProjectSearchOptions, String>, placeholder: String,
        id: String, autoFocus: Bool = false
    ) -> some View {
        TextField(
            text: Binding(get: { model.options(for: root)[keyPath: key] }, set: { value in
                var options = model.options(for: root)
                guard options[keyPath: key] != value else { return }
                options[keyPath: key] = value
                model.search(root: root, options: options)
            }),
            placeholder: placeholder, font: session.fonts.tab, autoFocus: autoFocus,
            restingOutline: true,
            onSubmit: { model.search(root: root, options: model.options(for: root), immediate: true) }
        )
        .flexGrow(1)
        .flexShrink(1)
        .agentId(id)
    }

    private func toggle(
        _ label: String, _ hint: String, id: String,
        option: WritableKeyPath<ProjectSearchOptions, Bool>
    ) -> some View {
        let enabled = model.options(for: root)[keyPath: option]
        return Text(label, color: enabled ? .accent : .muted, font: session.fonts.tabSelected,
                    align: .center, onClick: {
                        var options = model.options(for: root)
                        options[keyPath: option].toggle()
                        model.search(root: root, options: options, immediate: true)
                    })
            .frame(width: .pt(25), height: .pt(26))
            .flexShrink(0)
            .background(enabled ? theme.selectionFill : .clear)
            .hoverBackground(theme.hover)
            .cornerRadius(4)
            .cursor(.pointer)
            .tooltip(hint)
            .agentId(id)
    }

    private func fileRow(_ file: ProjectSearchFile, font: UIFont?, height: Float) -> some View {
        let name = file.path.split(separator: "/").last.map(String.init) ?? file.path
        let folder = String(file.path.dropLast(name.count + 1))
        let closed = model.collapsed.contains(file.path)
        return Canvas(label: "search-file", width: .pct(100), height: .pt(height),
                      onTap: { model.toggle(file.path) }) { list, frame in
            guard let font else { return }
            let mid = frame.y + frame.h / 2
            let y = mid - font.lineHeight / 2
            let chevron: IconShape = closed ? .path("m9 18 6-6-6-6") : .path("m6 9 6 6 6-6")
            list.strokeIcon([chevron], x: frame.x + 8, y: mid - 7, size: 14, color: theme.textSecondary)

            let count = String(file.count)
            let textWidth = font.shapedRun(count).width
            let pillWidth = max(18, textWidth + 10)
            let pillX = frame.x + frame.w - pillWidth - 12
            list.roundedRect(x: pillX, y: mid - 8, w: pillWidth, h: 16,
                             color: theme.selectionFill, radius: 8)
            list.text(count, x: pillX + (pillWidth - textWidth) / 2 - 4, y: y,
                      w: textWidth, h: font.lineHeight, color: theme.textPrimary, font: font)

            let x = frame.x + 27
            let available = max(0, pillX - x - 6)
            list.pushClip(x: x, y: frame.y, w: available, h: frame.h)
            list.text(name, x: x - 4, y: y, w: available, h: font.lineHeight,
                      color: theme.textPrimary, font: font)
            let folderX = x + font.shapedRun(name).width + 7
            if !folder.isEmpty, folderX < pillX - 6 {
                list.text(folder, x: folderX - 4, y: y, w: pillX - folderX - 6, h: font.lineHeight,
                          color: theme.textDim, font: font)
            }
            list.popClip()
        }
        .hoverBackground(theme.hover)
        .cursor(.pointer)
        .agentId("search-file/\(file.path)")
    }

    private func lineRow(
        _ line: ProjectSearchLine, path: String, font: UIFont?, height: Float
    ) -> some View {
        let font = font ?? FontStore.default
        let number = String(line.number)
        let numberWidth = font?.shapedRun(number).width ?? 0
        let inset = max(44, numberWidth + 22)
        return Canvas(label: "search-match", width: .pct(100), height: .pt(height),
                      onGesture: { gesture in
            guard gesture.phase == .began, gesture.button == 0 else { return }
            let match: Int
            if let font, gesture.localX >= inset {
                let preview = MatchPreview(line, font: font, width: gesture.frame.w - inset - 10)
                match = preview.spans.firstIndex { $0.contains(gesture.localX - inset) } ?? 0
            } else {
                match = 0
            }
            session.openProjectMatch(project.tree.url(of: path), line: line, match: match)
        }) { list, frame in
            guard let font else { return }
            let x = frame.x + inset
            let y = frame.y + (frame.h - font.lineHeight) / 2
            list.text(number, x: x - numberWidth - 13, y: y, w: numberWidth, h: font.lineHeight,
                      color: theme.textDim, font: font)
            let width = max(0, frame.w - inset - 10)
            let preview = MatchPreview(line, font: font, width: width)
            list.pushClip(x: x, y: frame.y, w: width, h: frame.h)
            for span in preview.highlightRuns {
                list.roundedRect(x: x + span.lowerBound, y: y, w: span.upperBound - span.lowerBound,
                                 h: font.lineHeight, color: appearance.languageFill, radius: 3)
            }
            list.text(line.preview, x: x - preview.pan - 4, y: y, w: width, h: font.lineHeight,
                      color: theme.textPrimary, font: font)
            list.popClip()
        }
        .hoverBackground(theme.hover)
        .cursor(.pointer)
        .agentId("search-match/\(path):\(line.number)")
    }
}

/// The same glyph positions drive the highlight and the click target. Pan
/// long prefixes away on a narrow sidebar so the first match stays visible.
private struct MatchPreview {
    let pan: Float
    let spans: [Range<Float>]

    var highlightRuns: [Range<Float>] {
        // A regex such as "." can put a hit on every character. Paint one
        // plate across adjacent hits while keeping their click ranges distinct.
        var runs: [Range<Float>] = []
        for span in spans {
            if let previous = runs.last, span.lowerBound <= previous.upperBound {
                runs[runs.count - 1] = previous.lowerBound..<max(previous.upperBound, span.upperBound)
            } else {
                runs.append(span)
            }
        }
        return runs
    }

    init(_ line: ProjectSearchLine, font: UIFont, width: Float) {
        let run = font.shapedRun(line.preview)
        let positions = line.highlights.map { range in
            let start = run.text.index(run.text.startIndex, offsetBy: range.lowerBound)
            let end = run.text.index(start, offsetBy: range.count)
            return (run.caretX(for: start), run.caretX(for: end))
        }
        let pan = max(0, (positions.first?.0 ?? 0) - max(0, width) * 0.28)
        self.pan = pan
        spans = positions.map { start, end in
            (start - pan)..<(max(start + 2, end) - pan)
        }
    }
}
