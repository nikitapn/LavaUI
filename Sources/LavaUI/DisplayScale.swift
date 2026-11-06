/// The output scale a window is drawn at: framebuffer pixels per layout pixel.
///
/// A compositor drawing a window on a 1.5 screen renders it at 1.5 times its
/// layout size and says so with a `Scale` event (`InputEventKind.scale`).
/// Layout never changes — everything here stays in layout pixels — and most of
/// a frame needs nothing from the app: shapes are drawn at device resolution
/// by the renderer, and text is rasterised there from the same face at the
/// device size. What the renderer cannot do is ask for an image at a size it
/// was never decoded at, because the client picks the decode size. That is
/// what this is for.
///
/// Two readings, for two kinds of caller:
///
/// - `DrawList.displayScale` is per window, and is what the framework's own
///   `Image(path:width:height:)` uses at emit time — so a window on each of
///   two screens decodes for its own.
/// - `DisplayScale.main` is the app's first window, for an app that sizes its
///   own decodes in `body` (a dock's icons, a thumbnail cache). A change
///   invalidates `body`, so a view that reads it is rebuilt with the new
///   value. Apps with one window, which is nearly all of them, lose nothing.
///
/// Windowed apps have no source for it yet and stay at 1.
public enum DisplayScale {
    /// The main window's scale. 1 until a compositor says otherwise.
    nonisolated(unsafe) public private(set) static var main: Float = 1

    /// `points` layout pixels in device pixels at the main window's scale,
    /// rounded up — the decode cap for a box that size.
    public static func pixels(_ points: Float) -> UInt32 {
        pixels(points, scale: main)
    }

    static func pixels(_ points: Float, scale: Float) -> UInt32 {
        let device = points * scale
        guard device >= 1 else { return points > 0 ? 1 : 0 }
        return UInt32(device.rounded(.up))
    }

    /// The size in layout pixels of a screen running `width`×`height` device
    /// pixels at `scale`, turned by `transform` (`wl_output_transform`; odd
    /// values are a quarter turn, which swaps the axes).
    ///
    /// What a window that wants to fill a screen should ask for — not the mode,
    /// which is device pixels: a client that asked for 2560×1600 on a 1.5
    /// screen laid its first frame out half as large again as the screen, and
    /// the compositor held the window back until a frame at the real size
    /// came. Rounded up, the way the compositor sizes what fills an output, so
    /// the request lands on the size the window is actually given.
    public static func logicalSize(
        width: UInt32, height: UInt32, scale: Float, transform: UInt32
    ) -> (width: Float, height: Float) {
        let s = scale.isFinite && scale > 0 ? Double(scale) : 1
        let (w, h) = transform % 2 == 1 ? (height, width) : (width, height)
        // The epsilon keeps an exact division exact: 2560 / 1.25 is 2048.
        func logical(_ device: UInt32) -> Float {
            Float((Double(device) / s - 1e-4).rounded(.up))
        }
        return (logical(w), logical(h))
    }

    /// Takes a `Scale` event for `window`. Nonsense values are ignored rather
    /// than trusted: a scale is a ratio a compositor computed, and zero or a
    /// NaN would turn every decode cap into 0, which means *native*.
    static func note(_ scale: Float, window: WindowID) -> Float? {
        guard scale.isFinite, scale >= 0.25, scale <= 8 else { return nil }
        if window == .main, scale != main {
            main = scale
            ViewInvalidation.markNeedsBody()
        }
        return scale
    }
}
