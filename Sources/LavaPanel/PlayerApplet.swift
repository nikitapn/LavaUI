import Foundation
import LavaMpris
import LavaUI

/// Transport for whatever is playing. Same glass as the other popups:
/// the panel is 32pt and this does not fit in it.
struct PlayerWindow: View {
    var mpris: MprisSession

    static let width: Float = 300
    static let height: Float = 210

    var body: some View {
        let theme = Theme.current
        VStack(padding: 4, spacing: 6) {
            HStack(padding: 0, alignment: .center, spacing: 10) {
                PlayerArt(mpris: mpris, size: 72, radius: 6)
                VStack(padding: 0, alignment: .start, spacing: 6) {
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
                transport(.previous, enabled: mpris.canGoPrevious, id: "player.prev") {
                    mpris.previous()
                }
                transport(
                    mpris.isPlaying ? .pause : .play,
                    enabled: mpris.canPlay || mpris.canPause,
                    id: "player.playpause"
                ) {
                    mpris.playPause()
                }
                transport(.next, enabled: mpris.canGoNext, id: "player.next") {
                    mpris.next()
                }
                Spacer()
            }

            if !mpris.identity.isEmpty {
                HStack() {
                    Spacer()
                    Text(mpris.identity, color: theme.textDim)
                }
            }
        }
        .padding(12)
        .frame(width: .pt(Self.width), height: .pt(Self.height))
        .background(PanelChrome.popupWash)
        .agentId("player.window")
    }

    private func transport(
        _ kind: TransportMark.Kind, enabled: Bool, id: String, action: @escaping () -> Void
    ) -> some View {
        let theme = Theme.current
        return HStack(
            padding: 0,
            alignment: .center,
            onClick: enabled ? action : nil
        ) {
            TransportMark(kind, size: 16, color: enabled ? theme.textPrimary : theme.textDim)
        }
        .padding(EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18))
        .hoverBackground(enabled ? theme.hover : .clear)
        .cornerRadius(6)
        .agentId(id)
    }
}

/// Album art, shared by the strip chip and the popup. A missing picture is
/// a note on the inset fill rather than an empty box.
private struct PlayerArt: View {
    var mpris: MprisSession
    var size: Float
    var radius: Float

    var body: some View {
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
            Text("♫", color: theme.textDim, align: .center)
                .frame(width: .pt(size), height: .pt(size))
                .background(theme.inset)
                .cornerRadius(radius)
        }
    }
}
