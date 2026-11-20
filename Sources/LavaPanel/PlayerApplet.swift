import Foundation
import LavaMpris
import LavaUI

/// What is playing, as a card: the cover, the title in the display face, a
/// seek bar with the time either side, the transport, and which player it is.
struct PlayerWindow: View {
    var mpris: MprisSession

    static let width: Float = 340
    static let padding: Float = 16
    static let art: Float = 76
    static var height: Float {
        padding * 2 + art + 16 + 16 + 6 + 15 + 6 + 52 + 12 + 1 + 12 + 20 + 2
    }

    var body: some View {
        let palette = PopupPalette.current
        let fonts = popupFonts!
        let mpris = mpris
        // The panel's clock ticks once a second; reading it here re-runs this
        // body on the tick, which is what moves the seek bar and the times.
        // MPRIS does not stream a position — it reports one, and a player
        // that is playing is expected to be extrapolated.
        _ = clock.time
        let length = max(0, Float(mpris.lengthUs) / 1_000_000)
        let position = min(length, PlaybackPosition.shared.seconds(mpris))
        let title = mpris.title.isEmpty ? mpris.stripTitle : mpris.title

        return PopupCard(padding: Self.padding) {
            HStack(padding: 0, alignment: .center, spacing: 14) {
                PlayerArt(mpris: mpris, size: Self.art, radius: 18, palette: palette)
                VStack(flexGrow: 1, padding: 0, alignment: .start, spacing: 2) {
                    Text(title, color: palette.bar.text, font: fonts.heading19, lineLimit: 1)
                    if !mpris.artist.isEmpty {
                        Text(mpris.artist, color: palette.bar.textSoft, font: fonts.body14,
                             lineLimit: 1)
                    }
                    if !mpris.album.isEmpty {
                        Text(mpris.album, color: palette.bar.textSoft, font: fonts.small13,
                             lineLimit: 1)
                    }
                }
                .clipped()
            }

            // ── Seek bar ─────────────────────────────────────────────────
            VStack(padding: 0, spacing: 6) {
                Slider(
                    value: Binding(
                        get: { position },
                        set: { seconds in
                            PlaybackPosition.shared.seek(mpris, to: seconds)
                        }),
                    in: 0...max(1, length),
                    style: PopupStyles.slider(palette, width: Self.width - Self.padding * 2 - 8),
                    isEnabled: mpris.canSeek && length > 0
                )
                .agentId("player.seek")
                HStack(padding: 0, alignment: .center) {
                    Text(Self.time(position), color: palette.bar.textSoft,
                         font: fonts.caption12Tabular)
                    Spacer()
                    Text("-" + Self.time(max(0, length - position)), color: palette.bar.textSoft,
                         font: fonts.caption12Tabular)
                }
            }
            .padding(EdgeInsets(top: 16, leading: 0, bottom: 6, trailing: 0))

            // ── Transport ────────────────────────────────────────────────
            HStack(padding: 0, alignment: .center, spacing: 14) {
                Spacer()
                transport(.previous, size: 40, enabled: mpris.canGoPrevious,
                          palette: palette, id: "player.prev") { mpris.previous() }
                transport(mpris.isPlaying ? .pause : .play, size: 52,
                          enabled: mpris.canPlay || mpris.canPause,
                          palette: palette, id: "player.playpause") { mpris.playPause() }
                transport(.next, size: 40, enabled: mpris.canGoNext,
                          palette: palette, id: "player.next") { mpris.next() }
                Spacer()
            }

            // ── Which player ─────────────────────────────────────────────
            VStack(padding: 0, spacing: 0) {
                CardDivider()
                HStack(padding: 0, alignment: .center, spacing: 8) {
                    IconDisc(icon: PanelIcons.appDisc, size: 20, glyph: 11,
                             fill: palette.sage200, color: palette.sage800, strokeWidth: 3)
                    Text(mpris.identity.isEmpty ? "Media" : mpris.identity,
                         color: palette.bar.textSoft, font: fonts.small13)
                    Spacer()
                    TagLabel(text: mpris.isPlaying ? "Playing" : "Paused",
                             tone: mpris.isPlaying ? .sage : .neutral)
                }
                .padding(EdgeInsets(top: 12, leading: 0, bottom: 0, trailing: 0))
            }
            .padding(EdgeInsets(top: 12, leading: 0, bottom: 0, trailing: 0))
        }
        .agentId("player.window")
    }

    private func transport(
        _ kind: TransportMark.Kind, size: Float, enabled: Bool, palette: PopupPalette,
        id: String, action: @escaping () -> Void
    ) -> some View {
        let primary = size > 44
        let ink: Color = primary ? palette.bar.onAccent
            : enabled ? palette.bar.text : palette.neutral400
        return HStack(width: .pt(size), height: .pt(size), padding: 0, alignment: .center, spacing: 0,
                      onClick: enabled ? action : nil) {
            Spacer()
            TransportMark(kind, size: primary ? 20 : 18, color: ink)
            Spacer()
        }
        .background(primary ? palette.bar.accent : .clear)
        .hoverBackground(!enabled ? .clear : primary ? palette.bar.accentHover : palette.rowHover)
        .cornerRadius(size / 2)
        .cursor(enabled ? .pointer : .arrow)
        .agentId(id)
    }

    /// "1:41".
    static func time(_ seconds: Float) -> String {
        let total = Int(seconds.rounded(.down))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

/// Where playback is now, from where the player last said it was.
///
/// A player reports its position when asked and on a seek, not as it plays,
/// so a bar that showed only the reported number would stand still. Each new
/// report — or a change between playing and paused — is taken as a fresh
/// anchor, and the time since it is added while playing.
final class PlaybackPosition: @unchecked Sendable {
    static let shared = PlaybackPosition()

    private var reported: Int64 = -1
    private var playing = false
    private var anchorSeconds: Float = 0
    private var anchorAt = Date()

    func seconds(_ mpris: MprisSession) -> Float {
        if mpris.positionUs != reported || mpris.isPlaying != playing {
            reported = mpris.positionUs
            playing = mpris.isPlaying
            anchorSeconds = Float(mpris.positionUs) / 1_000_000
            anchorAt = Date()
        }
        guard playing else { return anchorSeconds }
        return anchorSeconds + Float(Date().timeIntervalSince(anchorAt))
    }

    func seek(_ mpris: MprisSession, to seconds: Float) {
        mpris.setPosition(us: Int64(seconds * 1_000_000))
        // Shown at once rather than when the player gets round to saying so.
        anchorSeconds = seconds
        anchorAt = Date()
        ViewInvalidation.markNeedsBody()
    }
}

/// Album art, or — with none — a note on the accent's gradient.
private struct PlayerArt: View {
    var mpris: MprisSession
    var size: Float
    var radius: Float
    var palette: PopupPalette

    var body: some View {
        let url = mpris.artURL
        if let path = ArtCache.pathIfReady(for: url, onReady: {
            MainQueue.async { ViewInvalidation.markNeedsBody() }
        }) {
            Image(
                path: path,
                width: .pt(size),
                height: .pt(size),
                placeholder: palette.accent300,
                placeholderCornerRadius: radius,
                contentMode: .fill
            )
            .cornerRadius(radius)
            .frame(width: .pt(size), height: .pt(size))
        } else {
            HStack(width: .pt(size), height: .pt(size), padding: 0, alignment: .center, spacing: 0) {
                Spacer()
                Icon([.path(PanelIcons.music), .circle(cx: 6, cy: 18, r: 3),
                      .circle(cx: 18, cy: 16, r: 3)],
                     size: 30, color: Color(r: 1, g: 1, b: 1, a: 1), strokeWidth: 2)
                Spacer()
            }
            .background(Gradient(from: palette.accent300, to: palette.bar.accentInk,
                                 angle: .pi * 0.75))
            .cornerRadius(radius)
        }
    }
}
