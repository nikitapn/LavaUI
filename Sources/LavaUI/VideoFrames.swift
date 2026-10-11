// Frames a client renders on the GPU and the renderer samples without a copy
// through the CPU — a video player's, today.
//
// A separate protocol from `GPUResourceHost` because only one of the two hosts
// can do it: the compositor imports a dma-buf the client allocated on its
// device, while the built-in renderer *is* the client's device and has no use
// for a second process's buffer. An app asks `editor.resources as?
// VideoFrameHost` and falls back to `uploadPixels` when the answer is no.

/// Where a client must allocate its buffers: the renderer's GPU, and the
/// layouts of `DRM_FORMAT_ABGR8888` it can import.
public struct VideoTarget: Sendable, Equatable {
    /// `/dev/dri/renderD*`. A buffer from another GPU is not importable at
    /// all, which on a laptop with two is the usual way to get this wrong.
    public var renderNode: String
    public var modifiers: [UInt64]

    public init(renderNode: String, modifiers: [UInt64]) {
        self.renderNode = renderNode
        self.modifiers = modifiers
    }
}

/// One single-plane dma-buf, as its allocator describes it.
public struct VideoBufferLayout: Sendable, Equatable {
    public var width: UInt32
    public var height: UInt32
    /// A DRM FourCC: `ABGR8888` or `XBGR8888`, which is RGBA in memory.
    public var fourcc: UInt32
    public var modifier: UInt64
    public var offset: UInt32
    public var stride: UInt32

    public init(
        width: UInt32, height: UInt32, fourcc: UInt32, modifier: UInt64,
        offset: UInt32, stride: UInt32
    ) {
        self.width = width
        self.height = height
        self.fourcc = fourcc
        self.modifier = modifier
        self.offset = offset
        self.stride = stride
    }
}

/// A frame the renderer has: the texture to draw, and its size.
public struct VideoFrame: Sendable, Equatable {
    public var textureId: UInt32
    public var width: UInt32
    public var height: UInt32

    public init(textureId: UInt32, width: UInt32, height: UInt32) {
        self.textureId = textureId
        self.width = width
        self.height = height
    }
}

/// A host that can sample a client's dma-bufs. See the top of this file.
///
/// All of it blocks, and all of it may be called from any thread — a player
/// calls `show` from the thread it renders on, so a frame never waits for the
/// UI loop to come round.
public protocol VideoFrameHost: AnyObject, Sendable {
    /// Nil when the host has no video path at all: a compositor too old for
    /// the call, a connection that cannot carry a descriptor, or a renderer
    /// with no render node to name.
    func videoTarget() -> VideoTarget?

    /// Hands the buffer to the renderer. `fd` is borrowed — the host sends a
    /// duplicate — so the caller still closes its own. Nil if refused.
    func attachVideoBuffer(fd: Int32, layout: VideoBufferLayout) -> UInt32?

    /// "This buffer holds a finished frame." The caller has already waited for
    /// its own rendering to complete. When this returns the renderer has
    /// copied it, and the buffer may be rendered into again.
    ///
    /// Draw the id this returns, every time: it is usually the same for the
    /// same buffer, and not always.
    func showVideoBuffer(_ handle: UInt32) -> VideoFrame?

    func detachVideoBuffer(_ handle: UInt32)
}
