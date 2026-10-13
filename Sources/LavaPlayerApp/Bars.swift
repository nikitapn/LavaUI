import Foundation
import LavaPlayerCore
import LavaUI

/// The strip along the top: window buttons, what is playing, where it is in
/// the queue. A client-framed window has no other title bar.
struct TitleBar: View {
    @Bindable var session: PlayerSession

    static let height: Float = 36

    var body: some View {
        HStack(height: .pt(Self.height), padding: 8, alignment: .center, spacing: 8) {
            if WindowBridge.drawsOwnChrome {
                WindowControls().windowChrome()
            }
            Text(session.currentName, color: Theme.current.textPrimary, lineLimit: 1)
                .flexShrink(1)
                .agentId("title")
            Spacer()
                .frame(height: .pt(Self.height), minWidth: 48)
            if session.playlist.count > 1, session.playlist.position > 0 {
                Text(
                    "\(session.playlist.position) / \(session.playlist.count)",
                    color: Theme.current.textDim
                )
                .agentId("position")
            }
        }
        .background(Theme.current.panel)
        .windowDrag()
    }
}

/// Play, the seek bar, the clock and the volume.
///
/// Every control but the seek bar states its width, so the bar is the only
/// thing that gives as the window narrows — and the clock is wide enough for
/// `0:00:00 / 0:00:00`, so it does not shove the seek bar about as a file of
/// an hour or more ticks past each minute.
struct TransportBar: View {
    @Bindable var session: PlayerSession
    /// Over the video in fullscreen, rather than a row under it: translucent
    /// and rounded, so it reads as laid on the picture.
    var floating: Bool

    static let height: Float = 44
    /// How far the floating bar sits in from the screen's edges.
    static let floatingInset: Float = 16
    /// The floating bar's width on a screen wide enough for it, centred. Its
    /// own content is ~650 pt, so the rest — all of it the seek track, the
    /// only thing in the row that stretches — is what makes it worth floating.
    /// Edge to edge on a 2560-wide screen was a seek bar you had to travel to.
    static let floatingMaxWidth: Float = 1000

    var body: some View {
        HStack(height: .pt(Self.height), padding: 8, alignment: .center, spacing: 6) {
            iconButton("⏮", id: "previous", enabled: session.playlist.hasPrevious) {
                session.step(-1)
            }
            iconButton(playGlyph, id: "play", enabled: session.hasMedia) {
                session.togglePause()
            }
            iconButton("⏭", id: "next", enabled: session.playlist.hasNext) {
                session.step(1)
            }
            Text(
                Clock.pair(position: session.shownPosition, duration: session.state.duration),
                color: Theme.current.textSecondary,
                align: .center
            )
            .frame(width: .pt(140))
            .agentId("clock")
            Slider(
                value: Binding(
                    get: { session.progress },
                    set: { session.seek(fraction: $0) }
                ),
                in: 0...1,
                isEnabled: session.state.duration != nil,
                onEditingChanged: { session.seekBarEditing($0) }
            )
            .flexGrow(1)
            .agentId("seek")
            if !session.subtitleTracks.isEmpty {
                subtitlesButton
            }
            iconButton(session.state.muted ? "🔇" : "🔊", id: "mute", enabled: session.hasMedia) {
                session.toggleMute()
            }
            Slider(
                value: Binding(
                    get: { Float(session.state.muted ? 0 : session.state.volume) },
                    set: { session.setVolume($0) }
                ),
                in: 0...100,
                style: SliderStyle(trackWidth: 90)
            )
            .agentId("volume")
            iconButton(session.fullscreen ? "🗗" : "🗖", id: "fullscreen", enabled: true) {
                session.toggleFullscreen()
            }
        }
        .background(floating ? Theme.current.panel.opacity(0.85) : Theme.current.panel)
        .cornerRadius(floating ? 10 : 0)
    }

    /// CC: a left click cycles, the way `j` does — through off — and a right
    /// click lists every track. A stack's `onPointer` rather than a `Text`'s
    /// `onClick`, which answers every button the same: a right click would
    /// cycle *and* open the list. Lit while a track is showing.
    private var subtitlesButton: some View {
        HStack(
            padding: 6, alignment: .center,
            onPointer: { _, button in
                if button == PointerButton.left {
                    session.cycleSubtitles()
                } else if button == PointerButton.right {
                    session.toggleSubtitleMenu()
                }
            }
        ) {
            Text(
                "CC",
                color: session.selectedSubtitle != nil ? .accent : Theme.current.textSecondary,
                align: .center
            )
            .flexGrow(1)
        }
        .frame(width: .pt(34))
        .hoverBackground(Theme.current.hover)
        .cornerRadius(4)
        .cursor(.pointer)
        .agentId("subtitles")
        .overlay(
            isPresented: Binding(
                get: { session.subtitleMenuOpen },
                set: { if !$0 { session.closeSubtitleMenu() } }
            ),
            placement: OverlayPlacement { context in
                // Above the button, its right edge on the button's:
                // the bar is at the bottom of whatever it is in.
                let (w, h) = context.idealSize
                let anchor = context.anchor
                let x = min(
                    max(0, anchor.x + anchor.width - w),
                    max(0, context.viewport.width - w)
                )
                let y = max(0, anchor.y - h - 4)
                return OverlayFrame(x: x, y: y, width: w, height: h)
            },
            style: {
                var style = MenuBarStyle.standard(theme: Theme.current).overlayStyle
                style.minWidth = 200
                return style
            }()
        ) {
            if session.subtitleMenuOpen { SubtitleMenu(session: session) }
        }
    }

    private var playGlyph: String {
        session.state.paused || session.state.eofReached || !session.hasMedia ? "▶" : "⏸"
    }

    private func iconButton(
        _ glyph: String, id: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Text(
            glyph,
            color: enabled ? Theme.current.textSecondary : Theme.current.textDim,
            // `Text(align:)`, not `.frame(alignment:)`, so the click target is
            // the whole button — see AGENTS.md's layout traps.
            align: .center,
            onClick: enabled ? action : nil
        )
        .padding(6)
        .frame(width: .pt(34))
        .hoverBackground(enabled ? Theme.current.hover : Theme.current.panel)
        .cornerRadius(4)
        .cursor(enabled ? .pointer : .arrow)
        .agentId(id)
    }
}

/// The CC button's right-click menu: every subtitle track, off, and a file.
/// The same choices as the menubar's Subtitles menu, from one place.
private struct SubtitleMenu: View {
    @Bindable var session: PlayerSession

    var body: some View {
        MenuDropdownPanel(
            entries: entries,
            onActivate: { id in
                session.closeSubtitleMenu()
                switch id.raw {
                case "cc.off": session.selectSubtitles(nil)
                case "cc.load": session.openSubtitlesDialog()
                case let raw where raw.hasPrefix("cc.track."):
                    if let track = Int(raw.dropFirst("cc.track.".count)) {
                        session.selectSubtitles(track)
                    }
                default: break
                }
            },
            style: .standard(theme: Theme.current)
        )
        .agentId("subtitle-menu")
    }

    private var entries: [MenuEntry] {
        var items: [MenuEntry] = [
            .item(MenuItemModel(
                id: MenuID("cc.off"), title: "Off",
                isChecked: session.selectedSubtitle == nil
            )),
        ]
        for track in session.subtitleTracks {
            items.append(.item(MenuItemModel(
                id: MenuID("cc.track.\(track.id)"), title: track.label,
                isChecked: track.isSelected
            )))
        }
        items.append(.separator)
        items.append(.item(MenuItemModel(
            id: MenuID("cc.load"), title: "Load Subtitle File\u{2026}"
        )))
        return items
    }
}
