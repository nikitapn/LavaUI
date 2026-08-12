import Foundation
import LavaUI
import WeatherCore
#if canImport(LavaClient)
import LavaClient
#endif

/// LavaWeather — current conditions, the next day, and the week.
///
/// Data from Open-Meteo, which needs no API key: an app that refused to start
/// until you had registered for something would not be a weather app.
/// Sizes the window is opened and held at.
///
/// The minimum is not a guess: below roughly this width the week rows run out
/// of room for the summary and the range bar at once, and the hour strip stops
/// showing enough hours to be a strip. The compositor clamps interactive
/// resizes to it, so the broken shape is simply not reachable.
enum Layout {
    static let initialWidth: Float = 580
    static let initialHeight: Float = 660
    static let minWidth: Float = 560
    static let minHeight: Float = 420
}

@main
struct WeatherApp {
    static func main() {
        AppSettings.configure(appName: "LavaWeather")

        let client = ProcessInfo.processInfo.environment["LAVA_CLIENT"] == "1"
        #if canImport(LavaClient)
        // Client-framed under the compositor: the window already has a strip
        // with the place name on it, and a title bar above that would be a
        // second one saying less.
        let serverFrame =
            ProcessInfo.processInfo.environment["LAVA_FRAME"] == "server"
        let editorOrNil = client
            ? LavaClient.open(
                title: "LavaWeather",
                width: Layout.initialWidth, height: Layout.initialHeight,
                frame: serverFrame ? .server : .client
              )
            : LavaApp.open(
                title: "LavaWeather",
                width: Layout.initialWidth, height: Layout.initialHeight
              )
        #else
        let editorOrNil = client
            ? LavaApp.openClient()
            : LavaApp.open(title: "LavaWeather")
        #endif
        guard let editor = editorOrNil else { exit(1) }

        // Not the whole screen. A forecast is a glance, and the content has a
        // natural size — a hero, a strip of hours, seven rows — that a
        // full-screen window would leave floating in the middle of nothing.
        #if canImport(LavaClient)
        if client {
            LavaClient.setMinimumSize(
                width: Layout.minWidth, height: Layout.minHeight
            )
        }
        #endif

        Theme.current = .nebula
        // A second, larger instance of the UI face for the headline. Loaded
        // through `UIFont.loadUI` rather than by scaling the default one:
        // `FontStore.default` is a *rasterised* face at one pixel size, and
        // drawing it larger would be an upscale of an atlas rather than type.
        if let big = UIFont.loadUI(assetsRoot: LavaResources.root, pixelSize: 64) {
            big.registerWithEngine(editor)
            Fonts.hero = big
        }

        let session = WeatherSession()
        // After the first frame, so the window is on screen while the network
        // is still thinking. A weather app that shows nothing until the
        // forecast arrives looks like one that failed to start.
        FrameTasks.after { session.reload() }

        #if canImport(LavaClient)
        if client {
            LavaClient.run(editor: editor) { WeatherView(session: session) }
            return
        }
        #endif
        LavaApp.run(editor: editor) { WeatherView(session: session) }
    }
}
