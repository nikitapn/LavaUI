import Foundation

/// Which files LavaView will try to open.
///
/// The list is the intersection of what the engine can actually decode — stb
/// for raster, the SVG rasteriser for vector, the embedded preview for a
/// camera raw (`Engine::decodeImage`) — and what a person would call a
/// picture. It is deliberately not "everything stb
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
        // Canon raw. What is shown is the JPEG the camera embedded, not a
        // development of the sensor data — see `canvas/src/render/raw_preview.cpp`,
        // and add a format here only alongside `isRawPhoto`.
        "cr2",
    ]

    public static func isImage(path: String) -> Bool {
        isImage(extension: (path as NSString).pathExtension)
    }

    public static func isImage(extension ext: String) -> Bool {
        extensions.contains(ext.lowercased())
    }

    /// Longest edge a raster picture is decoded at for display: a ceiling,
    /// never reached by anything smaller. Not a quality decision — a device
    /// limit. `maxImageDimension2D` is 16384 on every desktop GPU and 4096 is
    /// all Vulkan guarantees; 8192 is comfortably inside every real limit and
    /// past any display.
    public static let rasterDecodeSide: UInt32 = 8192

    /// Longest edge a vector picture is drawn at for display.
    ///
    /// For an SVG the decoder's size is not a ceiling but the size it draws
    /// at — a vector has no pixels of its own to be capped. Handed the raster
    /// ceiling, every SVG became an 8192-pixel square: 256 MiB, 120–170 ms to
    /// draw and 165–300 ms to upload, for a file that might be an icon. This
    /// fills a 4K screen's height, which is the most a fitted picture is ever
    /// drawn at; zoom past that and it is scaled up like a photograph would be.
    public static let vectorDecodeSide: UInt32 = 2560

    public static func isVector(path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "svg"
    }

    /// The size to ask the decoder for when showing `path`.
    public static func displayDecodeSide(for path: String) -> UInt32 {
        isVector(path: path) ? vectorDecodeSide : rasterDecodeSide
    }

    /// Filters for `FileDialog.openFile`.
    public static var dialogExtensions: [String] {
        extensions.sorted()
    }
}
