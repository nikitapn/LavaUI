import Foundation
import LavaUI
import SpotifyCore
#if canImport(LavaClient)
import LavaClient
#endif

/// LavaSpotify — Spotify-shaped UI + Connect control of spotifyd.
///
/// Catalog: client credentials or seed/oembed.
/// Playback: user OAuth → Player API → spotifyd (or any Connect device).
@main
struct SpotifyApp {
    static func main() {
        // Shared config root: ~/.config/LavaSpotify/settings.json (Linux).
        AppSettings.configure(appName: "LavaSpotify")
        SpotifyTheme.restore()
        Theme.current = SpotifyTheme.theme

        let client = ProcessInfo.processInfo.environment["LAVA_CLIENT"] == "1"
        #if canImport(LavaClient)
        // Client-framed by default under the compositor: the demo's toolbar is
        // already a 56pt row, and a title bar above it would be a second one
        // saying less. `LAVA_FRAME=server` puts the compositor's strip back,
        // which is the comparison worth being able to make in one keystroke.
        let serverFrame =
            ProcessInfo.processInfo.environment["LAVA_FRAME"] == "server"
        let editorOrNil = client
            ? LavaClient.open(
                title: "LavaSpotify",
                frame: serverFrame ? .server : .client
              )
            : LavaApp.open(title: "LavaSpotify")
        #else
        // Without the control plane there is nothing to be a client of. The
        // windowless engine still exists, so this stays useful for checking
        // that a tree lays out and emits with no GPU.
        let editorOrNil = client
            ? LavaApp.openClient()
            : LavaApp.open(title: "LavaSpotify")
        #endif
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
                            LavaSpotify login ≠ spotifyd login. Both are needed.

                            A) LavaSpotify (Web API control)
                               1. Dashboard: redirect http://127.0.0.1:17321/callback
                               2. export SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET
                               3. Account → Log in to Spotify

                            B) spotifyd (the actual speaker / Connect device)
                               Zeroconf alone (Spotifyd@host on LAN) does NOT
                               list the device on GET /me/player/devices until
                               spotifyd has credentials for your account:
                               1. spotifyd authenticate
                                  (browser OAuth; default port 8000)
                               2. systemctl --user restart spotifyd
                               3. Account → Refresh devices
                                  Expect a name containing “spotifyd”

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

        #if canImport(LavaClient)
        if client {
            // Never returns: the surface is created here, not by `open`, and
            // the process exits when the compositor takes it away.
            LavaClient.run(
                editor: editor, menu: menu, onRawKey: onRawKey, makeRoot: root
            )
        }
        #endif

        LavaApp.run(
            editor: editor, menu: menu, onRawKey: onRawKey, makeRoot: root
        )
    }
}
