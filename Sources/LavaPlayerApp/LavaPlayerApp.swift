import Foundation
import LavaHost
import LavaPlayerCore
import LavaUI

/// LavaPlayer — mpv, in a LavaUI window.
///
/// mpv decodes and renders; LavaUI draws everything around the picture. Under
/// the compositor the picture never touches the CPU: mpv renders into
/// dma-bufs on the compositor's own GPU and the compositor samples them (see
/// `Player` and `Sources/CLavaVideo`). Windowed, or wherever that path will
/// not come up, mpv renders in software and the frames are uploaded as
/// pixels — slower, and the same player.
///
/// `LavaPlayer file.mkv` plays it with its folder as Next/Previous.
/// `LavaPlayer a.mp4 b.mp4` plays those, one after another. No arguments
/// opens empty, ready for a drop.
enum Layout {
    static let initialWidth: Float = 1100
    static let initialHeight: Float = 680
    static let minWidth: Float = 560
    static let minHeight: Float = 240
}

@main
struct LavaPlayerApp {
    static func main() {
        AppSettings.configure(appName: "LavaPlayer")

        guard let editor = LavaHost.open(
            title: "LavaPlayer",
            width: Layout.initialWidth, height: Layout.initialHeight
        ) else { exit(1) }
        LavaHost.setMinimumSize(
            editor: editor, width: Layout.minWidth, height: Layout.minHeight
        )
        Theme.current = .nebula

        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let session = PlayerSession(
            host: editor.resources, playlist: Playlist.from(paths: Array(paths))
        )
        if let opened = session.playlist.current, !paths.isEmpty {
            LavaHost.noteOpened(opened, appId: "LavaPlayer")
        }

        // Started from the first frame rather than here: in client mode the
        // compositor connection — and with it the video target — is only
        // there once `run` has created the surface.
        nonisolated(unsafe) var started = false
        FrameTasks.after {
            started = session.start()
            if !started { exit(1) }
        }

        LavaHost.run(
            editor: editor,
            menu: {
                MenuBar {
                    Menu("Player", id: "app") {
                        MenuItem(
                            "Quit", id: "app.quit",
                            shortcut: KeyShortcut(KeyCode.q, .primary)
                        ) { editor.requestClose() }
                    }
                    Menu("File", id: "file") {
                        MenuItem(
                            "Open…", id: "file.open",
                            shortcut: KeyShortcut(KeyCode.o, .primary)
                        ) { session.openDialog() }
                    }
                    Menu("Playback", id: "playback") {
                        MenuItem("Play / Pause", id: "playback.pause") { session.togglePause() }
                        MenuItem("Forward 5 s", id: "playback.forward") { session.seek(by: 5) }
                        MenuItem("Back 5 s", id: "playback.back") { session.seek(by: -5) }
                        MenuSeparator()
                        MenuItem("Next", id: "playback.next") { session.step(1) }
                        MenuItem("Previous", id: "playback.previous") { session.step(-1) }
                        MenuSeparator()
                        MenuItem("Mute", id: "playback.mute") { session.toggleMute() }
                    }
                    Menu("Subtitles", id: "subtitles") {
                        MenuItem(
                            "Off", id: "subtitles.off",
                            isEnabled: !session.subtitleTracks.isEmpty,
                            isChecked: session.selectedSubtitle == nil
                        ) { session.selectSubtitles(nil) }
                        for track in session.subtitleTracks {
                            MenuItem(
                                track.label, id: "subtitles.track.\(track.id)",
                                isChecked: track.isSelected
                            ) { session.selectSubtitles(track.id) }
                        }
                        MenuSeparator()
                        MenuItem(
                            "Show Subtitles", id: "subtitles.visible",
                            isEnabled: session.selectedSubtitle != nil,
                            isChecked: session.state.subtitlesVisible
                        ) { session.toggleSubtitlesVisible() }
                        MenuItem("Earlier by 0.1 s", id: "subtitles.earlier") {
                            session.nudgeSubtitleDelay(-0.1)
                        }
                        MenuItem("Later by 0.1 s", id: "subtitles.later") {
                            session.nudgeSubtitleDelay(0.1)
                        }
                        MenuSeparator()
                        MenuItem(
                            "Load Subtitle File…", id: "subtitles.load",
                            isEnabled: session.hasMedia
                        ) { session.openSubtitlesDialog() }
                    }
                    Menu("Audio", id: "audio") {
                        for track in session.audioTracks {
                            MenuItem(
                                track.label, id: "audio.track.\(track.id)",
                                isChecked: track.isSelected
                            ) { session.selectAudio(track.id) }
                        }
                    }
                    Menu("View", id: "view") {
                        MenuItem("Fullscreen", id: "view.fullscreen") {
                            session.toggleFullscreen()
                        }
                    }
                }
            },
            makeRoot: { PlayerView(session: session) }
        )
        session.shutdown()
    }
}
