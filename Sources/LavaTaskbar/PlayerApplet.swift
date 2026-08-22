import Foundation
import LavaUI

/// Panel media control: cover + title in the strip, popover with transport.
///
/// Talks to whatever is on MPRIS, preferring spotifyd. Hidden when nothing
/// is. `isOpen` is owned by the panel so the compositor input region covers
/// the dropdown — same contract as volume and the calendar.
struct PlayerApplet: View {
    var mpris: MprisSession
    var isOpen: Binding<Bool>

    var body: some View {
        let theme = Theme.current
        let open = isOpen
        let playing = mpris.isPlaying
        return HStack(
            height: .pt(36),
            padding: 0,
            alignment: .center,
            spacing: 6,
            onPointer: { _, button in
                if button == PointerButton.right {
                    mpris.playPause()
                } else if button == PointerButton.left {
                    open.wrappedValue.toggle()
                }
            },
            onWheel: { _, dy in mpris.skipByWheel(dy: dy) }
        ) {
            cover(size: 22, radius: 3)
            titleLabel(playing: playing, theme: theme)
        }
        .padding(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 6))
        .hoverBackground(TaskbarChrome.style.titleHover)
        .cornerRadius(6)
        .agentId("applet.player")
        .overlay(
            isPresented: isOpen,
            alignment: .below,
            style: {
                var s = TaskbarChrome.style.overlayStyle
                s.padding = 10
                s.minWidth = 240
                return s
            }()
        ) {
            popover
        }
    }

    @ViewBuilder
    private var popover: some View {
        let theme = Theme.current
        VStack(padding: 4, spacing: 10) {
            HStack(padding: 0, alignment: .center, spacing: 10) {
                cover(size: 72, radius: 6)
                VStack(padding: 0, alignment: .start, spacing: 4) {
                    Text(
                        mpris.title.isEmpty ? mpris.stripTitle : mpris.title,
                        color: theme.textPrimary,
                        lineLimit: 2
                    )
                    if !mpris.artistLine.isEmpty {
                        Text(mpris.artistLine, color: theme.textSecondary, lineLimit: 2)
                    }
                    Text(
                        mpris.isPlaying ? "Playing" : (mpris.status.isEmpty ? "" : mpris.status),
                        color: theme.textDim
                    )
                }
                .frame(width: .pt(160))
            }

            Divider()

            HStack(padding: 0, alignment: .center, spacing: 8) {
                Spacer()
                transport("‹‹", enabled: mpris.canGoPrevious, id: "player.prev") {
                    mpris.previous()
                }
                transport(
                    mpris.isPlaying ? "❚❚" : "▶",
                    enabled: mpris.canPlay || mpris.canPause,
                    id: "player.playpause"
                ) {
                    mpris.playPause()
                }
                transport("››", enabled: mpris.canGoNext, id: "player.next") {
                    mpris.next()
                }
                Spacer()
            }

            if !mpris.identity.isEmpty {
                Text(mpris.identity, color: theme.textDim)
            }
        }
    }

    @ViewBuilder
    private func cover(size: Float, radius: Float) -> some View {
        let theme = Theme.current
        let url = mpris.artURL
        if let path = ArtCache.pathIfReady(for: url, onReady: {
            MainQueue.async { ViewInvalidation.markNeedsBody() }
        }) {
            Image(
                path: path,
                width: .pt(size),
                height: .pt(size),
                placeholder: theme.inset,
                placeholderCornerRadius: radius,
                contentMode: .fill
            )
            .cornerRadius(radius)
            .frame(width: .pt(size), height: .pt(size))
        } else {
            Text("♫", color: theme.textDim)
                .frame(width: .pt(size), height: .pt(size))
                .background(theme.inset)
                .cornerRadius(radius)
        }
    }

    private func transport(
        _ label: String, enabled: Bool, id: String, action: @escaping () -> Void
    ) -> some View {
        let theme = Theme.current
        // Click lives on the padded stack, not the glyph. Text-with-onClick
        // only hits the letters, and these marks are two characters wide.
        return HStack(
            padding: 0,
            alignment: .center,
            onClick: enabled ? action : nil
        ) {
            Text(label, color: enabled ? theme.textPrimary : theme.textDim)
        }
        .padding(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
        .hoverBackground(enabled ? theme.hover : .clear)
        .cornerRadius(6)
        .agentId(id)
    }

    /// Natural title width, capped so a long name cannot shove the clock
    /// off the strip. Short titles shrink to themselves — the old 140pt
    /// box left a hole after "Ceremony" and cut "Give Life Back to Music".
    private static let maxTitleWidth: Float = 140

    @ViewBuilder
    private func titleLabel(playing: Bool, theme: Theme) -> some View {
        let title = mpris.stripTitle
        Text(
            title,
            color: playing ? theme.textPrimary : theme.textDim,
            lineLimit: 1
        )
        .frame(width: .pt(Self.maxTitleWidth))
        .clipped()
    }
}
