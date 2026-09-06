import Foundation
import LavaHost
import LavaUI
import SpotifyCore

/// LavaSpotify — Spotify-shaped UI + local control of spotifyd.
///
/// Catalog: client credentials or seed/oembed.
/// Playback: MPRIS on the session bus (spotifyd / librespot). The Web API
/// Player endpoints are only the fallback when no spotifyd is present.
@main
struct SpotifyApp {
    static func main() {
        // Shared config root: ~/.config/LavaSpotify/settings.json (Linux).
        AppSettings.configure(appName: "LavaSpotify")
        SpotifyTheme.restore()
        Theme.current = SpotifyTheme.theme

        // Client-framed by default under the compositor: the window draws its
        // own controls and drag strip (same shape as LavaWeather).
        // `LAVA_FRAME=server` puts the compositor's title bar back.
        let editorOrNil = LavaHost.open(title: "LavaSpotify")
        guard let editor = editorOrNil else { exit(1) }

        if let b = ProcessInfo.processInfo.environment["LAVA_IMAGE_BUDGET_KB"],
           let kb = Int(b), kb > 0
        {
            ImageStore.budgetBytes = kb * 1024
            FileHandle.standardError.write(
                Data("LavaSpotify: ImageStore budget \(kb) KB\n".utf8)
            )
        }

        let session = SpotifySession(editor: editor)
        FrameTasks.after { session.start() }

        let menu = {
            MenuBar {
                Menu("LavaSpotify", id: "app") {
                    MenuItem("About LavaSpotify", id: "app.about") {
                        FileHandle.standardError.write(
                            Data(
                                "LavaSpotify · LavaUI + Spotify Connect (spotifyd)\n"
                                    .utf8
                            )
                        )
                    }
                    MenuSeparator()
                    MenuItem("Reload Catalog", id: "app.reload") {
                        session.start()
                    }
                    MenuSeparator()
                    MenuItem(
                        "Quit",
                        id: "app.quit",
                        shortcut: KeyShortcut(KeyCode.q, .primary)
                    ) {
                        editor.requestClose()
                    }
                }
                Menu("Account", id: "account") {
                    MenuItem("Log in to Spotify…", id: "account.login") {
                        session.login()
                    }
                    MenuItem("Log out", id: "account.logout") {
                        session.logout()
                    }
                    MenuSeparator()
                    MenuItem("Refresh devices", id: "account.devices") {
                        session.refreshDevices()
                    }
                }
                Menu("View", id: "view") {
                    MenuItem("Home", id: "view.home") { session.goHome() }
                    MenuItem("Search", id: "view.search") { session.goSearch() }
                    MenuItem("Library", id: "view.library") { session.goLibrary() }
                    MenuSeparator()
                    MenuItem(
                        "Choose Theme…",
                        id: "view.theme",
                        shortcut: KeyShortcut(KeyCode.t, .primary)
                    ) {
                        session.showThemePicker()
                    }
                    MenuSeparator()
                    MenuItem("Zoom In", id: "view.zoom-in") {
                        FontStore.zoomIn(into: editor)
                    }
                    MenuItem("Zoom Out", id: "view.zoom-out") {
                        FontStore.zoomOut(into: editor)
                    }
                    MenuItem("Actual Size", id: "view.zoom-reset") {
                        FontStore.resetScale(into: editor)
                    }
                }
                Menu("Help", id: "help") {
                    MenuItem("Setup", id: "help.setup") {
                        let msg = """
                            LavaSpotify + spotifyd
                            ─────────────────────
                            Playback talks to spotifyd over MPRIS (session bus),
                            not the Web API Player endpoints. Catalog still uses
                            the Web API (or the seed catalog).

                            A) spotifyd (the speaker)
                               1. use_mpris = true in spotifyd.conf
                               2. spotifyd authenticate
                               3. systemctl --user restart spotifyd
                               Play / pause / next / volume / click-a-track
                               then stay on D-Bus.

                            B) LavaSpotify catalog (optional for transport)
                               1. Dashboard: redirect http://127.0.0.1:17321/callback
                               2. export SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET
                               3. Account → Log in only if you want other
                                  Connect devices (phone, official client)

                            Optional: SPOTIFY_DEVICE_NAME=spotifyd
                            (substring match; default already “spotifyd”)
                            """
                        FileHandle.standardError.write(Data((msg + "\n").utf8))
                    }
                }
            }
        }
        let onRawKey = { (event: LavaUI.InputEvent) in
            session.handleThemeKey(event)
        }
        let root = { Spotify(session: session) }

        LavaHost.run(
            editor: editor, menu: menu, onRawKey: onRawKey, makeRoot: root
        )
    }
}
