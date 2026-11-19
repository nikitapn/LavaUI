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

    /// The bundled `fonts` directory under `root`.
    public static var fontsDirectory: String {
        (root as NSString).appendingPathComponent("fonts")
    }
}

/// Faces LavaUI ships beside its defaults, by file name without `.ttf`.
///
/// Figtree (Regular, SemiBold, Bold) is the desktop's UI face and Caprasimo
/// its display face for headings; both are OFL, licences beside them. Here
/// rather than in each app so the panel and the editor load the same bytes —
/// fonts are content-addressed, so one file is one set of atlas glyphs for
/// every client that asks for it.
public enum BundledFont {
    /// Absolute path to `name.ttf` in `LavaResources.fontsDirectory`, or nil
    /// when the file is not there.
    public static func path(_ name: String) -> String? {
        let path = (LavaResources.fontsDirectory as NSString)
            .appendingPathComponent(name + ".ttf")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}
