import Foundation

/// SwiftPM resource bundle for LavaUI defaults (fonts).
///
/// Engine SPIR-V is `CanvasResources` in the canvas package; app-owned images
/// belong on the executable's own `Bundle.module`.
public enum LavaResources {
    /// Directory containing `fonts/` (and anything else declared on the
    /// LavaUI target's `resources:`).
    public static var root: String {
        if let url = Bundle.module.resourceURL {
            return url.path
        }
        return FileManager.default.currentDirectoryPath
    }

    public static var fontsDirectory: String {
        (root as NSString).appendingPathComponent("fonts")
    }
}
