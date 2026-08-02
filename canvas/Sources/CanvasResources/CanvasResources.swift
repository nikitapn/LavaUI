import Foundation

/// Paths into the SwiftPM resource bundle for the canvas engine (SPIR-V, etc.).
///
/// User-facing assets (fonts, app images) live on LavaUI / app targets — not here.
public enum CanvasResources {
    /// Directory that contains `shaders/*.bin`. Pass this to `Engine.openWindow`
    /// / `LavaApp.open` as the engine assets root.
    public static var engineRoot: String {
        if let env = ProcessInfo.processInfo.environment["CANVAS_ASSETS_ROOT"], !env.isEmpty {
            return env
        }
        guard let url = Bundle.module.resourceURL else {
            // Extremely defensive: should never happen when the target declares resources.
            return FileManager.default.currentDirectoryPath
        }
        return url.path
    }

    public static var shadersDirectory: String {
        (engineRoot as NSString).appendingPathComponent("shaders")
    }
}
