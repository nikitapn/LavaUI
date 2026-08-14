import Foundation
import LavaHost
import LavaUI
import WeatherCore

/// LavaWeather — current conditions, the next day, and the week.
///
/// Data from Open-Meteo, which needs no API key: an app that refused to start
/// until you had registered for something would not be a weather app.
/// Sizes the window is opened and held at.
///
/// The minimum is not a guess: below roughly this width the week rows run out
/// of room for the summary and the range bar at once, and the hour strip stops
/// showing enough hours to be a strip. The active window host clamps
/// interactive resizes to it, so the broken shape is simply not reachable.
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

        // Client-framed under the compositor: the window already has a strip
        // with the place name on it, and a title bar above that would be a
        // second one saying less. `LAVA_FRAME=server` puts it back.
        let editorOrNil = LavaHost.open(
            title: "LavaWeather",
            width: Layout.initialWidth, height: Layout.initialHeight
        )
        guard let editor = editorOrNil else { exit(1) }

        // Not the whole screen. A forecast is a glance, and the content has a
        // natural size — a hero, a strip of hours, seven rows — that a
        // full-screen window would leave floating in the middle of nothing.
        LavaHost.setMinimumSize(
            editor: editor,
            width: Layout.minWidth, height: Layout.minHeight
        )

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

        LavaHost.run(editor: editor) { WeatherView(session: session) }
    }
}
