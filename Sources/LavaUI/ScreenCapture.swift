import Foundation

/// A picture of the whole screen, for the one app that needs one.
///
/// Not the same question as `ScreenshotBridge`, which answers "what does *this
/// window* look like" and exists for the agent. This is the desktop: every
/// window on it, foreign and Lava alike, and the wallpaper behind them —
/// which only the compositor can see, and which a client can therefore only
/// ask for.
///
/// Nil in a windowed build. An app that cannot get one should say so rather
/// than show an empty editor: there is nothing it can do about it, and
/// pretending otherwise wastes the user's time finding that out.
public enum ScreenCapture {
    /// The path of a PNG the host wrote, or nil if it has no desktop to
    /// photograph.
    ///
    /// A path rather than bytes, and that is the interesting part. A picture
    /// does not fit in a shared-memory reply — half a megabyte is the cap, and
    /// a screenful of PNG is past it — so the two processes use the filesystem
    /// they already share. It also makes the ordinary case free: the path goes
    /// straight back to `registerImage`, and the pixels never cross at all.
    ///
    /// The file belongs to the caller from the moment it arrives. Nothing
    /// deletes it.
    public typealias Provider = @Sendable (
        _ includeSelf: Bool, _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32,
        _ maxSide: Int32
    ) -> String?

    nonisolated(unsafe) public static var provider: Provider?

    /// Whether the desktop can be captured here at all.
    public static var isAvailable: Bool { provider != nil }

    /// The screen the pointer is on, as a PNG file.
    ///
    /// `includeSelf` false leaves the calling window out — which is what a
    /// screenshot tool wants and cannot arrange for itself, since by the time
    /// it can ask, its own window is already up.
    ///
    /// The crop is in framebuffer pixels; an empty one means the whole screen.
    /// It happens on the far side because a client has no codec of its own: a
    /// region of a PNG is not something it can take for itself.
    ///
    /// Synchronous, and it costs an offscreen composite of the whole screen
    /// plus a PNG encode — once, when the user asks for a shot, never in a
    /// paint closure.
    public static func screen(
        includeSelf: Bool = false,
        x: Int32 = 0, y: Int32 = 0, w: Int32 = 0, h: Int32 = 0,
        maxSide: Int32 = 0
    ) -> String? {
        provider?(includeSelf, x, y, w, h, maxSide)
    }
}
