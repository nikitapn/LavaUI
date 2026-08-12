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
                title: "LavaWeather", frame: serverFrame ? .server : .client
              )
            : LavaApp.open(title: "LavaWeather")
        #else
        let editorOrNil = client
            ? LavaApp.openClient()
            : LavaApp.open(title: "LavaWeather")
        #endif
        guard let editor = editorOrNil else { exit(1) }

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
