import LavaGitCore
import LavaUI

struct BlameCard: View {
    let card: BlameState.Card
    let state: BlameState
    let appearance: EditorAppearance
    let font: UIFont?

    var body: some View {
        let theme = appearance.documentTheme
        let relative = BlameDate.relative(card.commit.date, now: card.now)
        let exact = BlameDate.exact(card.commit.date)
        let message = "\(card.author), \(relative) (\(exact))\n\(card.commit.shortOID)\n\n\(card.commit.message)"
        return VStack(flexGrow: 1, padding: 8, spacing: 4) {
            EditorView(text: .constant(message), isReadOnly: true,
                       style: CodeStyle(text: theme.textPrimary, currentLine: .clear),
                       font: font, showLineNumbers: false, wraps: true,
                       visibleLines: 20, controller: state.cardEditor)
                .flexGrow(1)
                .agentId("blame-message")
            HStack(alignment: .center) {
                Spacer()
                Button("Copy Hash", font: font) { ClipboardBridge.write(card.commit.oid) }
                    .agentId("blame-copy")
            }
        }
        .theme(theme)
        .onHover { [state] inside in state.hoverCard(inside) }
        .agentId("inline-blame-card")
    }

    static func placement(_ anchor: EditorLineEndHintAnchor) -> OverlayPlacement {
        OverlayPlacement { context in
            guard let hint = anchor.frame else { return context.anchor }
            let gap: Float = 5
            let width = min(640, max(1, context.viewport.width - 2 * gap))
            let x = min(Float(hint.minX), context.viewport.width - width - gap)
            let above = max(0, Float(hint.minY) - 2 * gap)
            let below = max(0, context.viewport.height - Float(hint.maxY) - 2 * gap)
            let wanted = min(300, context.idealSize.height)
            let goAbove = above >= wanted || above >= below
            let height = max(1, min(wanted, goAbove ? above : below))
            let y = goAbove ? Float(hint.minY) - gap - height : Float(hint.maxY) + gap
            return OverlayFrame(x: x, y: y, width: width, height: height)
        }
    }
}
