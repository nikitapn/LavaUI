import LavaUI

/// The palette as a minibuffer: a prompt line along the bottom of the
/// window with the matching commands under it, the way Emacs's M-x looks
/// with a vertical completion list. Up/Down or Ctrl+P/N choose, Tab puts the
/// chosen command's name in the field, Enter runs it, and Escape, Ctrl+G or
/// Alt+X again closes it.
struct CommandPaletteView: View {
    let session: EditorSession
    let palette: CommandPalette
    let appearance: EditorAppearance

    /// As tall as it has been since it opened — the whole list then, up to
    /// 45% of the window — and no shorter as the matches narrow. A
    /// minibuffer keeps its size while it is typed into, which is what keeps
    /// the prompt from jumping on every key; no hits is an empty list, not a
    /// smaller box.
    static func placement(for palette: CommandPalette) -> OverlayPlacement {
        let tallest = palette.height
        return OverlayPlacement { context in
            let cap = max(80, context.viewport.height * 0.45)
            let height = min(cap, max(tallest.value, context.idealSize.height))
            tallest.value = height
            return OverlayFrame(x: 0, y: context.viewport.height - height,
                                width: context.viewport.width, height: height)
        }
    }

    static func style(session: EditorSession, palette: CommandPalette, theme: Theme) -> OverlayStyle {
        var style = OverlayStyle(background: theme.panel, border: theme.border, cornerRadius: 0,
                                 padding: 0, modal: true)
        style.onKey = { event in
            let matches = palette.matches
            switch event.key {
            case KeyCode.escape:
                session.closeCommandPalette()
            case KeyCode.g where event.control, KeyCode.x where event.alt:
                session.closeCommandPalette()
            case KeyCode.enter:
                guard palette.selection < matches.count else { return true }
                session.runCommand(matches[palette.selection])
            case KeyCode.up, KeyCode.p where event.control:
                palette.move(by: -1, in: matches.count)
            case KeyCode.down, KeyCode.n where event.control:
                palette.move(by: 1, in: matches.count)
            case KeyCode.pageUp:
                palette.move(by: -10, in: matches.count)
            case KeyCode.pageDown:
                palette.move(by: 10, in: matches.count)
            case KeyCode.tab:
                guard palette.selection < matches.count else { return true }
                palette.query = matches[palette.selection].title
            default:
                return false
            }
            return true
        }
        style.onUnfocusedText = { character in
            guard !character.isNewline else { return }
            palette.query += String(character)
            palette.fieldFocused = true
        }
        return style
    }

    var body: some View {
        let theme = appearance.theme
        let matches = palette.matches
        let selection = min(palette.selection, max(0, matches.count - 1))
        let session = self.session
        let palette = self.palette
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text("M-x", color: theme.accent, font: session.fonts.tab, lineLimit: 1)
                TextField(
                    text: Binding(get: { palette.query }, set: { palette.query = $0 }),
                    placeholder: "Run a command",
                    font: session.fonts.tab,
                    focusRing: FocusRingStyle.none, restingOutline: false
                )
                .focused(Binding(get: { palette.fieldFocused }, set: { palette.fieldFocused = $0 }))
                .flexGrow(1)
                .agentId("command-field")
                // At the end, where its width changing as the count does
                // moves nothing: before the prompt, it shifted the prompt and
                // the text being typed on every keystroke.
                Text("\(matches.isEmpty ? 0 : selection + 1)/\(matches.count)",
                     color: .muted, font: session.fonts.status, lineLimit: 1)
            }
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))

            if matches.isEmpty {
                Text("No command matches “\(palette.query)”.", color: .muted, font: session.fonts.status)
                    .padding(EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12))
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.offset) { index, command in
                            self.row(command, isSelected: index == selection, theme: theme)
                        }
                    }
                    .padding(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
                }
                .flexGrow(0)
                .flexShrink(1)
                .agentId("command-rows")
            }
        }
        .frame(width: .pct(100))
        // Pass the overlay's height constraint down to the scroll viewport.
        .flexShrink(1)
        .agentId("command-palette")
    }

    private func row(_ command: MenuCommand, isSelected: Bool, theme: Theme) -> some View {
        let session = self.session
        return HStack(alignment: .center, spacing: 10, onClick: { session.runCommand(command) }) {
            Text(command.title, color: .primary, font: session.fonts.tab, lineLimit: 1)
                .flexShrink(1)
            Text(command.path.joined(separator: " › "), color: .muted, font: session.fonts.status, lineLimit: 1)
                .flexShrink(1)
            Spacer()
            if let checked = command.isChecked {
                Text(checked ? "on" : "off", color: checked ? appearance.languageText : .muted,
                     font: session.fonts.status, lineLimit: 1)
                    .padding(EdgeInsets(top: 1, leading: 7, bottom: 1, trailing: 7))
                    .background(checked ? appearance.languageFill : .clear)
                    .cornerRadius(8)
            }
            if let shortcut = command.shortcut {
                Text(shortcut.label, color: .muted, font: session.fonts.status, lineLimit: 1)
            }
        }
        .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        .background(isSelected ? theme.selectionFill : .clear)
        .hoverBackground(isSelected ? theme.selectionFill : theme.hover)
        .hoverSnap()
        .cornerRadius(6)
        .cursor(.pointer)
        .scrollIntoView(when: isSelected)
        .agentId("command-\(command.id.raw)")
    }
}
