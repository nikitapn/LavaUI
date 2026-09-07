import Foundation

/// How a turned picture gets written back.
///
/// The interesting decision is not "where" but "in what", and it is decided
/// before anything is written so the confirmation can say it out loud. Two
/// facts drive it: the engine can encode PNG and baseline JPEG and nothing
/// else, and JPEG has no alpha channel.
public struct SaveTarget: Equatable, Sendable {
    public enum Encoding: Equatable, Sendable {
        /// Lossless. Every pixel survives the round trip.
        case png
        /// Lossy, at `quality`. Re-encoding a JPEG always costs something,
        /// even when the only change is which way is up.
        case jpeg(quality: UInt32)
    }

    /// Where the bytes go.
    public var path: String
    public var encoding: Encoding
    /// True when `path` is not the file that was opened, because its format
    /// cannot be written. The UI has to say so — a Save that silently landed
    /// somewhere else would be the worst kind of surprise.
    public var isFormatChange: Bool

    public var isLossy: Bool {
        if case .jpeg = encoding { return true }
        return false
    }

    /// Quality used for JPEG. High enough that a single turn-and-save is not
    /// visible at 100%, low enough that the file does not grow.
    public static let jpegQuality: UInt32 = 92

    /// Extensions the JPEG encoder is the right answer for.
    static let jpegExtensions: Set<String> = ["jpg", "jpeg", "jpe", "jfif"]
    /// Extensions that should stay exactly what they are, losslessly.
    static let pngExtensions: Set<String> = ["png"]

    /// Decides the destination for overwriting `path` in place.
    ///
    /// - `hasAlpha` comes from the decoded pixels, not from the extension: a
    ///   PNG with no transparent pixel is still a PNG, and a file named `.jpg`
    ///   that decoded with alpha (it happens — renamed files) must not lose it.
    public static func inPlace(path: String, hasAlpha: Bool) -> SaveTarget {
        let ns = path as NSString
        let ext = ns.pathExtension.lowercased()

        if jpegExtensions.contains(ext), !hasAlpha {
            return SaveTarget(
                path: path, encoding: .jpeg(quality: jpegQuality),
                isFormatChange: false
            )
        }
        if pngExtensions.contains(ext) {
            return SaveTarget(path: path, encoding: .png, isFormatChange: false)
        }

        // Everything else — GIF, BMP, TGA, PNM, SVG, or a JPEG that turned out
        // to carry alpha — becomes a PNG next to the original. Writing a
        // rasterised PNG over someone's `.svg` would destroy the only copy of
        // a thing that was never pixels; changing the name is the honest move.
        let renamed = ns.deletingPathExtension + ".png"
        return SaveTarget(
            path: renamed, encoding: .png,
            isFormatChange: renamed != path
        )
    }

    /// The destination for an explicit Save As, where the user named the file
    /// and the extension they typed is the instruction.
    public static func explicit(path: String, hasAlpha: Bool) -> SaveTarget {
        var target = inPlace(path: path, hasAlpha: hasAlpha)
        // "Save As" already told the user where it is going, and the picker
        // is what named it — so nothing here is a surprise to report.
        target.isFormatChange = false
        return target
    }

    /// One line for the confirmation bar. Says the two things a person needs
    /// before overwriting a photograph: what it will be called, and whether
    /// the pixels survive.
    public func confirmation(originalPath: String) -> String {
        let name = (path as NSString).lastPathComponent
        if isFormatChange {
            let was = (originalPath as NSString).lastPathComponent
            return "\(was) cannot be written back — save as \(name)?"
        }
        if isLossy {
            return "Overwrite \(name)? JPEG is re-encoded, so this loses a little quality."
        }
        return "Overwrite \(name)?"
    }
}
