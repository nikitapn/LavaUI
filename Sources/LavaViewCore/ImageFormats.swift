import Foundation

/// Which files LavaView will try to open.
///
/// The list is the intersection of what the engine can actually decode — stb
/// for raster, the SVG rasteriser for vector (`Engine::decodeImage`) — and what
/// a person would call a picture. It is deliberately not "everything stb
/// compiles in": PSD and PIC are decoded by the same call, but a directory of
/// layered Photoshop files is not a slideshow, and putting them in the cycle
/// would mean a Next that lands on something the viewer renders wrongly.
///
/// Matched on the extension rather than by sniffing the bytes. Sniffing is
/// better for *one* file the user pointed at, and much worse for the directory
/// walk around it — it would open and read every file in the folder to decide
/// what is next.
public enum ImageFormats {
    /// Lowercase, without the dot.
    public static let extensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "jfif",
        "gif", "bmp", "tga", "hdr", "pnm", "ppm", "pgm", "pbm",
        "svg",
    ]

    public static func isImage(path: String) -> Bool {
        isImage(extension: (path as NSString).pathExtension)
    }

    public static func isImage(extension ext: String) -> Bool {
        extensions.contains(ext.lowercased())
    }

    /// Filters for `FileDialog.openFile`.
    public static var dialogExtensions: [String] {
        extensions.sorted()
    }
}
