import Foundation
import LavaPlayerCore
import LavaUI

/// The window: a title strip, the video, and the transport along the bottom.
struct PlayerView: View {
    @Bindable var session: PlayerSession
    private let keyTarget = NodeID.generate()

    var body: some View {
        FocusManager.setDefault(
            keyTarget,
            onKey: { [session] event in PlayerKeys.handle(event, session: session) },
            onChar: { _ in false }
        )

        // The same transport bar in one of two places. Windowed, it is a row
        // under the video, and the video is laid out around it. Fullscreen, it
        // floats over the video's bottom edge and takes no space — so showing
        // and hiding it never resizes the video, which would make mpv render
        // at a new size and the picture jump every time the pointer moved.
        return VStack(flexGrow: 1, spacing: 0) {
            if !session.fullscreen { TitleBar(session: session) }
            if let error = session.error { errorBar(error) }
            screen
                .overlay(alignment: .bottom, inset: TransportBar.floatingInset) {
                    if session.fullscreen && session.barsVisible {
                        // A point width, not a percentage: an overlay's plate
                        // sizes to its content, so there is no width above it
                        // for a percentage to be of.
                        TransportBar(session: session, floating: true)
                            .frame(width: .pt(max(0, min(
                                TransportBar.floatingMaxWidth,
                                session.screenWidth - TransportBar.floatingInset * 2
                            ))))
                            .onHover { session.noteBarHover($0) }
                    }
                }
            if !session.fullscreen { TransportBar(session: session, floating: false) }
        }
        .background(Palette.mat)
        .onDrop { urls in session.open(paths: urls.map(\.path)) }
    }

    // MARK: - The video

    private var screen: some View {
        Canvas(
            label: "video",
            flexGrow: 1,
            minHeight: 60,
            onGesture: { gesture in
                guard gesture.phase == .began, gesture.button == PointerButton.left else { return }
                FocusManager.clear()
                // An open menu takes the click that closes it, as menus do.
                // The overlay cannot do this itself here: it lets a click
                // outside reach a real target, and the video is one that
                // covers everything.
                if session.subtitleMenuOpen {
                    session.closeSubtitleMenu()
                    return
                }
                // A click pauses and a double-click goes fullscreen, the
                // convention every desktop player shares. The first click of
                // a double has already paused, so the second un-pauses it on
                // the way: the video keeps playing either way.
                if gesture.clickCount == 2 {
                    session.togglePause()
                    session.toggleFullscreen()
                } else {
                    session.togglePause()
                }
            },
            onWheel: { _, dy, _, _ in session.nudgeVolume(Double(dy) * 5) },
            onPointerMove: { _, _ in
                session.noteActivity()
                return nil
            },
            paint: paint
        )
        .flexGrow(1)
        // Stated even when it is the arrow: a view with a cursor is one the
        // renderer reports as hovered, and the hidden cursor is resolved from
        // that — over a view it never names, there is nothing to hide it on.
        .cursor(session.hidesCursor ? .hidden : .arrow)
        .agentId("video")
    }

    private func paint(_ list: DrawList, _ frame: CanvasFrame) {
        session.player.setSize(width: frame.w, height: frame.h)
        session.noteScreen(width: frame.w)
        session.updateBars()
        session.placeSubtitles(screenHeight: frame.h)
        list.rect(x: frame.x, y: frame.y, w: frame.w, h: frame.h, color: Palette.mat)

        guard session.hasMedia else {
            centred(list, frame, "Drop a video here, or press Ctrl+O", Theme.current.textDim)
            return
        }
        if let current = session.player.currentFrame(), session.hasVideo || !session.state.idle {
            // mpv renders at the box's size and letterboxes inside it, so this
            // is normally the whole box. Mid-resize the frame on hand was
            // drawn for the previous box; it is fitted rather than stretched,
            // and the next frame is the right size again.
            let (w, h) = current.size
            let scale = min(frame.w / max(w, 1), frame.h / max(h, 1))
            let dw = w * scale, dh = h * scale
            list.image(
                textureId: current.textureId,
                x: frame.x + (frame.w - dw) / 2, y: frame.y + (frame.h - dh) / 2,
                w: dw, h: dh
            )
            session.player.noteDrawn(current)
        }
        if !session.hasVideo, session.state.position != nil {
            // Audio: mpv draws black. Say what is playing rather than show a
            // window that looks broken.
            centred(list, frame, session.currentName, Theme.current.textSecondary)
        }
    }

    private func centred(_ list: DrawList, _ frame: CanvasFrame, _ text: String, _ color: Color) {
        guard let font = Environment.current.font ?? FontStore.default, !text.isEmpty
        else { return }
        let size = font.measure(text)
        list.text(
            text,
            // `DrawList.text` insets the pen by 4; see LavaView's `centred`.
            x: frame.x + (frame.w - size.width) / 2 - 4,
            y: frame.y + (frame.h - font.lineHeight) / 2,
            w: size.width + 8, h: font.lineHeight,
            color: color, font: font
        )
    }

    private func errorBar(_ message: String) -> some View {
        HStack(height: .pt(32), padding: 8, alignment: .center, spacing: 8) {
            Text(message, color: Theme.current.textPrimary, lineLimit: 1)
                .flexShrink(1)
                .agentId("error")
            Spacer()
            Text("Dismiss", color: .accent, onClick: { session.dismissError() })
                .padding(4)
                .cornerRadius(4)
                .cursor(.pointer)
        }
        .background(Theme.current.panel)
    }
}

enum Palette {
    /// The surround. Video is judged against it, and anything lighter than
    /// black makes the black bars of a letterbox look grey.
    static let mat = Color(r: 0, g: 0, b: 0)
}
