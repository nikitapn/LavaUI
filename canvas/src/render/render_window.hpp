#pragma once

#include <algorithm>
#include <cstdint>
#include <functional>
#include <mutex>
#include <unordered_map>
#include <vector>

#include <vulkan/vulkan.h>

#include "vk_mem_alloc.h"

#include "render/blur_pass.hpp"
#include "render/draw_command.hpp"
#include "render/quad_renderer.hpp"
#include "util/types.hpp"

struct GLFWwindow;
class RenderDevice;

namespace canvas {
class DmabufImage;
}

/// One render target and everything sized to it.
///
/// Windowed, it owns a surface and a swapchain; offscreen, it owns a
/// host-visible staging buffer instead. Everything else is the same, because
/// **the swapchain is only a blit destination**: every frame is drawn into
/// this window's own MSAA attachment, resolved, and copied out — nothing is
/// ever rendered straight into a swapchain image. That indirection is what
/// keeps the render passes, and so every pipeline built against them,
/// independent of any surface. They live on `RenderDevice` and a second window
/// costs its attachments and its sync objects, not a second glyph atlas,
/// texture cache, or pipeline set.
///
/// Frame slots are per window: two windows presenting at once hold two
/// independent `currentFrame_` cursors over one queue, which is safe because
/// nothing in a frame reads another window's attachments. What is *not* per
/// window is the lifetime of the shared resources they both sample — a texture
/// or an atlas page is only dead once no window still has a frame that could
/// name it. See `RenderDevice::destroyImageDeferred`.
///
/// A window is driven by one worker at a time. Different windows are safe to
/// render concurrently: each owns its command pool and leases a device queue;
/// shared cache/lifetime operations are synchronized by RenderDevice.
class RenderWindow {
 public:
  /// CPU/GPU overlap: while the GPU draws slot N, the CPU builds slot N+1.
  static constexpr uint32_t kMaxFramesInFlight = 2;

  /// Presents into `window`'s surface. The GLFW window belongs to the caller
  /// and must outlive this object.
  ///
  /// `ownerId` is the `AppWindow::id` this belongs to, and exists only so the
  /// attachments show up in `RenderDevice::gpuLedger()` under the window that
  /// pays for them. It is a constructor argument rather than a setter because
  /// the attachments are allocated before the constructor returns.
  RenderWindow(RenderDevice &device, GLFWwindow *window, uint32_t ownerId = 0);

  /// Offscreen: no surface, no swapchain, no present. Each frame's resolve is
  /// copied into a staging buffer for `readPixels`.
  RenderWindow(RenderDevice &device, uint32_t width, uint32_t height,
               uint32_t ownerId = 0);

  ~RenderWindow();

  RenderWindow(const RenderWindow &)            = delete;
  RenderWindow &operator=(const RenderWindow &) = delete;

  /// One-time setup of the renderers this window owns. Separate from the
  /// constructor because it is the expensive half — pipelines, descriptor
  /// pools, the blur render pass — and because a caller may want the window
  /// (and so its surface and size) before paying for it.
  void initRenderers();

  // ─── Frame ───────────────────────────────────────────────────────────────

  /// Replays `list` into this window's batch stream and presents the result.
  ///
  /// Everything between here and the swapchain belongs to the window: the
  /// vertex arena for this frame slot, the blur scratch targets, the segment
  /// boundaries a backdrop blur splits the frame into. The caller supplies
  /// commands and nothing else, which is what makes a second window a second
  /// `render` call rather than a second renderer.
  ///
  /// `list` only has to stay alive for the duration of the call.
  void render(const canvas::DrawList &list);

  /// Sends this window's frames to a buffer another driver reads.
  ///
  /// A third destination alongside the swapchain and the staging buffer. Where
  /// the buffer can be rendered into (`DmabufImage::renderable`) it *is* the
  /// window's resolve attachment: the MSAA attachment resolves straight into
  /// it, this window allocates no single-sample image of its own, and the
  /// frame ends with a queue-ownership release instead of a full-screen blit.
  /// Where it cannot, the frame resolves into this window's own image and is
  /// blitted out, which is what every export used to do. Nothing about the
  /// render passes, the pipelines or the atlas changes either way.
  ///
  /// Offscreen windows only — a window that presents already has somewhere to
  /// put its frames. `target` must be at least this window's size and must
  /// outlive it; null goes back to the staging buffer. Larger is ordinary:
  /// exported buffers are allocated in steps so a resize can keep the one it
  /// has, and the frame is blitted into the target's top-left corner, which is
  /// the rectangle the consumer crops to. See `canvas::DmabufImage`.
  void setExportTarget(canvas::DmabufImage *target);

  /// The sync_file for the frame this window last exported, or -1 when there
  /// is none — either the device cannot make one or the frame was waited for
  /// instead. **The caller owns the fd** and must close it.
  ///
  /// Valid to ignore: an uncollected fence is closed when the next frame
  /// replaces it. What is not valid is to skip the wait *and* not collect,
  /// which is why `setExportFenceHonoured` and this are two halves of one
  /// promise.
  int takeFrameFence();

  /// Rebinds the glyph atlas this window's batches sample. The atlas belongs
  /// to the shared `TextRenderer`, so growing it invalidates the binding in
  /// *every* window and each has to be told.
  void setGlyphAtlas(VkImageView view, VkSampler sampler);

  /// Clears each frame to nothing instead of to opaque black.
  ///
  /// For a window whose pixels are composited by something else — a compositor
  /// surface — where "the parts nothing was drawn over" has to mean *nothing*
  /// rather than black. A rounded corner, a translucent panel and a shadow all
  /// depend on it, and against an opaque clear all three come out as black.
  ///
  /// What lands in the buffer is then premultiplied alpha, which is what
  /// Wayland expects, and it falls out of the blend state rather than needing
  /// one: colour blends `SRC_ALPHA`/`ONE_MINUS_SRC_ALPHA` and alpha blends
  /// `ONE`/`ONE_MINUS_SRC_ALPHA`, so the first quad drawn onto a transparent
  /// clear leaves `rgb = C·A, a = A` and every quad after it composes as
  /// premultiplied `over`.
  ///
  /// Off by default: a window that presents to a swapchain, or that is read
  /// back as a PNG, wants a background rather than a hole.
  void setTransparent(bool transparent) { transparent_ = transparent; }

  /// Whole-window camera applied at draw time (layout pixels → screen).
  /// Per window: two views of the same document can sit at different zooms.
  void setViewTransform(float zoom, float panX, float panY);

  /// Block until *this* slot is free (the GPU finished its last use). With 2
  /// frames in flight this does not wait on the other slot, so the CPU can
  /// prepare frame N+1 while the GPU still paints N.
  void waitForInFlightFrame();

  /// Block until every one of this window's frames is done. Callers replacing
  /// something *shared* want `RenderDevice::waitForAllFramesInFlight()`
  /// instead — this one says nothing about the other windows.
  void waitForAllFrames();

  /// Slot the next record/submit will use (0 or 1).
  uint32_t currentFrameSlot() const { return currentFrame_; }

  /// Frames presented by this window since it opened. Monotonic, unlike
  /// `currentFrameSlot()`.
  uint64_t frameCounter() const { return frameCounter_; }

  /// Lowest device submission index this window may still have running, or
  /// `UINT64_MAX` when everything it submitted has retired. This is what lets
  /// `RenderDevice::collectGarbage` free a shared texture only once *no*
  /// window can still name it.
  uint64_t oldestUnretiredSubmission() const;

  // ─── Targets ─────────────────────────────────────────────────────────────

  const VkExtent2D &getExtent() const { return extent_; }

  /// The single-sample image this window's frame ends up in.
  ///
  /// Usually this window's own resolve attachment, and for an exported window
  /// drawing a frame that goes straight into its buffer, the shared image
  /// itself — the frame resolves there and there is no local copy of it to
  /// read. Anything that wants the finished frame (the backdrop blur's
  /// capture, a readback) has to go through here rather than name
  /// `resolveImage_`, which in that case does not exist. Which of the two it
  /// is can change from frame to frame: see `directToExport`.
  VkImage       frameImage() const;
  VkImageView   frameImageView() const;
  VkFramebuffer mainFramebuffer() const { return framebuffer_; }

  /// If the framebuffer size drifted (a WM resize, `setWindowFrame`), rebuild
  /// the swapchain and every sized attachment. True if a rebuild happened.
  bool resize();

  /// Resizes a window that has no surface of its own to measure.
  ///
  /// The offscreen and exported counterpart of `resize()`: a windowed one asks
  /// its swapchain how big it is, and one that is composited elsewhere has to
  /// be *told*. True if anything was rebuilt.
  ///
  /// An export target does not survive this — a window mid-resize must not
  /// draw into an image it no longer matches. The caller sets one again
  /// afterwards, which is usually the *same* image at a size the window now
  /// fills less of; see `Application::resizeExportedWindow`.
  bool resizeTo(uint32_t width, uint32_t height);

  // ─── Window ──────────────────────────────────────────────────────────────

  bool isWindowed() const { return windowed_; }

  /// Rebuilds the framebuffers against the current attachment views.
  ///
  /// Called by the device when the shared depth image is replaced — every
  /// window is then holding a framebuffer that names a destroyed view. Cheap
  /// (two `vkCreateFramebuffer` calls) and safe only between frames, which is
  /// where the growth that triggers it happens.
  void rebuildFramebuffer();

  /// Allocates the host-visible readback buffer if this window does not have one
  /// yet. Idempotent, and safe to call only between frames.
  ///
  /// Called by the paths that actually read pixels back rather than at window
  /// creation: it is a full frame of host-visible memory — 7.9 MiB at 1080p —
  /// and a window that is never captured never needs it. On a compositor that
  /// is every window, since an exported frame is blitted into its dma-buf and
  /// never passes through here.
  void ensureStagingBuffer();
  /// The `AppWindow::id` whose allocations are tagged with this window.
  uint32_t ownerId() const { return ownerId_; }
  GLFWwindow *window() const { return window_; }
  bool windowShouldClose() const;
  /// Ask the loop to exit (sets GLFW should-close).
  void requestClose();

  /// Move/resize in screen coordinates. A size change rebuilds the swapchain
  /// and offscreen targets on the next `resize()`. No-op when not windowed.
  void setWindowFrame(int x, int y, int width, int height);
  void setWindowVisible(bool visible);

  /// Rounds this window's corners: everything outside the rounded rectangle
  /// is cleared to transparent as the last step of every frame.
  ///
  /// `radius` 0 turns it off. `top`/`bottom` select which pair is rounded, so
  /// a title bar can round only the two corners it actually owns and leave the
  /// join with the content below it square. The client is never told — this
  /// is a property of the *window*, and a client that had to know its own
  /// corners were round would have to be told again every time a config
  /// changed.
  void setCornerRadius(float radius, bool top = true, bool bottom = true) {
    cornerRadius_ = radius < 0.f ? 0.f : radius;
    cornerTop_ = top;
    cornerBottom_ = bottom;
  }

#ifdef INCLUDE_IMGUI
  /// Call after installing app-level GLFW callbacks so ImGui can chain.
  void initImGuiGlfwBackend();
#endif

  // ─── Readback ────────────────────────────────────────────────────────────

  /// Copies the last-rendered frame (RGBA8) into `dst`, which must hold at
  /// least `extent.width * extent.height * 4` bytes. Prefer `captureFrame`
  /// when windowed — the present path does not fill staging every frame.
  void readPixels(uint8_t *dst, size_t dstSize);

  /// Wait for the GPU, copy resolve → staging, then `readPixels` into `dst`.
  /// Works windowed and offscreen. Also refreshes the capture cache.
  void captureFrame(uint8_t *dst, size_t dstSize);

  /// Drop the host capture cache (called after presenting a new frame).
  void invalidateCaptureCache() { captureCacheValid_ = false; }

  /// Encode a (sub)region of the current resolve as PNG bytes. `x,y,w,h` in
  /// framebuffer pixels; `w` or `h` <= 0 means full frame. If `maxSide` > 0
  /// and the longer side exceeds it, downsamples so
  /// max(outW, outH) <= maxSide (agent overview / token budget). Reuses the
  /// capture cache when still valid, so several crops share one readback.
  /// False on an empty/invalid region or an encode failure.
  bool capturePng(std::vector<uint8_t> &outPng, int x, int y, int w, int h,
                  int maxSide = 0, int *outW = nullptr, int *outH = nullptr);

  // ─── Scene nodes ─────────────────────────────────────────────────────────
  //
  // The retained half of the draw list. Commands are republished every frame
  // and own nothing; a *node* has an identity, and the state this window
  // keeps against that identity outlives any one frame. Scroll offset is the
  // first such state, and the reason the split is worth having: a wheel event
  // moves a subtree here, with no round trip to the process that drew it.

  /// Nodes as they were laid out in the last replay, in pre-order — so the
  /// innermost node containing a point is the *last* one that contains it.
  const std::vector<canvas::SceneNodeRect> &sceneNodes() const
  {
    return sceneNodes_;
  }

  /// Aims a scrollable node under the pointer at a new offset.
  ///
  /// Moves the node's *target*, not the node: the visible offset eases toward
  /// it in `advanceSceneAnimations`. A wheel notch is a discrete step, and
  /// applying it directly is what makes wheel scrolling feel like a stepper
  /// rather than like scrolling.
  ///
  /// Walks the chain under the pointer from the inside out, so a pane already
  /// at its end passes the notch to whatever encloses it instead of
  /// swallowing it. A node flagged `kSceneNodeWheel` ends the walk without
  /// consuming: the producer has its own use for the wheel there, and only
  /// the producer can say whether its widget will take this particular notch.
  ///
  /// `ignoreWheelClaims` is how the producer hands the event back after
  /// finding nothing that wanted it — the same walk, minus the deference that
  /// has now been answered. Passing it on the way *in* would scroll a
  /// container out from under a widget that was about to use the wheel.
  ///
  /// Returns true if a target changed, which is the caller's signal that the
  /// event has been consumed and this window needs a repaint.
  bool scrollSceneNode(float pointerX, float pointerY, float deltaX,
                       float deltaY, bool ignoreWheelClaims = false);

  /// Steps every in-flight node animation to `now` (seconds, monotonic).
  ///
  /// Returns true while anything is still moving — the caller's cue to keep
  /// the frame loop awake, since an animation is a repaint nobody requested
  /// and nothing else will ask for the next one.
  ///
  /// `outMoved` collects the nodes whose offset actually changed, so the
  /// window can tell the producer where they ended up.
  /// `outFinished` collects nodes whose declared animation arrived on this
  /// step, so the window can tell the producer. An edge, not a state: a node
  /// appears here once per transition.
  bool advanceSceneAnimations(double now,
                              std::vector<canvas::SceneNodeOffset> &outMoved,
                              std::vector<uint32_t> &outFinished);

  /// Consumes "a node parked at the edge of its drawn content can now move".
  ///
  /// A virtualizing producer draws a window of its content and says so; the
  /// scroll position is held inside that window, so a node with a target
  /// beyond it stops at the edge and reports *settled* rather than spinning
  /// for frames against a producer that may never draw the next row.
  ///
  /// That makes the next publish the only thing that can resume it, and this
  /// is how the publish gets noticed. Set during replay — where the rows
  /// actually arrive — and read after it, because the step that would use the
  /// new span runs before the replay that delivers it.
  bool takeSceneResume()
  {
    const bool was = sceneResume_;
    sceneResume_   = false;
    return was;
  }

  /// The part of the last frame that is genuinely opaque, or false if none is.
  ///
  /// The producer's claim (`DrawCommandKind::OpaqueBounds`) narrowed by this
  /// window's own rounding, because the corner mask runs *after* the client's
  /// content and clears pixels the client believed it had filled. Insetting
  /// here rather than in the caller keeps the two facts in the one place that
  /// knows both: a consumer would have to be told the radius to get it right,
  /// and would be wrong for a frame every time the radius changed.
  ///
  /// Only the rounded pair is inset, matching `setCornerRadius` — a bar that
  /// rounds its top two corners stays opaque all the way to its bottom edge.
  bool opaqueBounds(float &x, float &y, float &w, float &h) const
  {
    if (opaqueW_ <= 0.f || opaqueH_ <= 0.f) return false;
    const float r =
      (cornerTop_ || cornerBottom_) ? std::max(0.f, cornerRadius_) : 0.f;
    const float top    = cornerTop_ ? r : 0.f;
    const float bottom = cornerBottom_ ? r : 0.f;
    x = opaqueX_ + r;
    y = opaqueY_ + top;
    w = opaqueW_ - 2.f * r;
    h = opaqueH_ - top - bottom;
    return w > 0.f && h > 0.f;
  }

  /// Points the scene graph at a new pointer position.
  ///
  /// Returns true if the hovered node changed, which is the caller's cue that
  /// this window looks different now — the *only* cue, since a producer that
  /// is busy or stopped will not republish, and a hover that waits for the
  /// producer is the round trip this exists to avoid.
  ///
  /// Called on motion and also once per repaint, because content scrolling
  /// under a stationary pointer changes what is under it just as surely as
  /// moving the pointer does.
  bool updateSceneHover(float pointerX, float pointerY);

  /// Node currently under the pointer, or 0.
  uint32_t hoveredSceneNode() const { return hoveredNode_; }

  /// Records a press against whichever node is under the pointer.
  ///
  /// Unlike a scroll, the event is *not* consumed: a press means something to
  /// the producer, and only the producer knows what. The renderer draws the
  /// feedback and forwards the event — observing, not intercepting.
  bool updateScenePress(bool pressed);

  /// Forgets every node's retained state.
  ///
  /// Called when a window's producer changes: node ids are a producer's
  /// private numbering, so the offsets held against the old one's ids mean
  /// nothing to the new one and would apply themselves to whatever happens
  /// to reuse an id.
  void resetSceneState();

 private:
  /// Window rounding — see `setCornerRadius`. Applied in `replayDrawList`,
  /// after the client's own content, because it shapes the finished frame
  /// rather than anything in the draw list.
  float cornerRadius_ = 0.f;
  bool  cornerTop_    = true;
  bool  cornerBottom_ = true;

  /// What the last replayed frame declared fully opaque, in viewport pixels —
  /// see `DrawCommandKind::OpaqueBounds`. Zero width or height is "nothing
  /// claimed", which is where every frame starts.
  float opaqueX_ = 0.f;
  float opaqueY_ = 0.f;
  float opaqueW_ = 0.f;
  float opaqueH_ = 0.f;

  /// What this window remembers about a node between frames.
  struct SceneNodeState {
    /// Where the node is drawn.
    float scrollX = 0.f;
    float scrollY = 0.f;
    /// Where it is heading. Equal to the above when nothing is animating,
    /// which is also how "is this node animating" is answered — no separate
    /// flag to keep in step with the numbers it describes.
    float targetX = 0.f;
    float targetY = 0.f;
    /// Last producer scroll request applied. Repeated draw-list frames carry
    /// the same serial and must not override a later wheel gesture.
    uint32_t scrollRequestSerial = 0;
    /// Set when a replay moved this node outright rather than giving it
    /// somewhere to travel to — see `kSceneScrollImmediate`. The step reports
    /// the position once and clears it, because a snap leaves target and
    /// position already in agreement and so produces no movement for the step
    /// to notice and pass on. Without it the producer's own idea of the
    /// offset — what its hit testing and lazy mounting run in — would stay at
    /// wherever the node was before the drag.
    bool scrollReport = false;
    /// Last extent an `EndNode` actually reported.
    ///
    /// Retained rather than re-read per frame because the list comes from
    /// another process and may be truncated: a producer that runs out of
    /// arena mid-frame drops the commands that did not fit, and if the one
    /// it drops is this node's `EndNode`, a per-frame extent would collapse
    /// to the viewport and clamp the scroll back to the top. Remembering the
    /// last extent that was actually stated makes a short frame merely a
    /// short frame.
    float contentW = 0.f;
    float contentH = 0.f;
    /// Span the last `EndNode` said it had actually drawn.
    float emittedTop = 0.f;
    float emittedBottom = 0.f;
    /// Tints the last `EndNode` declared.
    uint32_t hoverTint = 0;
    uint32_t pressTint = 0;
    /// How far each tint has faded in, 0…1. Eased rather than switched,
    /// because a highlight that appears between two frames reads as a flicker
    /// at the speed a pointer actually crosses a list.
    float hoverAmount = 0.f;
    float pressAmount = 0.f;

    // ─── Producer-declared animation ────────────────────────────────────
    //
    // Where the producer said this node should end up, and where it has
    // actually got to. Targets are retained: a frame that never reached the
    // `NodeAnimate` command leaves them alone.
    float opacity = 1.f;
    float targetOpacity = 1.f;
    float translateX = 0.f;
    float translateY = 0.f;
    float targetTranslateX = 0.f;
    float targetTranslateY = 0.f;
    /// Time constant, seconds. Zero means the renderer's default.
    float animationTau = 0.f;
    /// Set when `animationTau` is a duration rather than a decay constant.
    bool  animationTimed = false;
    /// Where the current timed transition started, and when. Meaningless in
    /// decay mode, which needs no memory of where it set out from.
    float startOpacity = 1.f;
    float startTranslateX = 0.f;
    float startTranslateY = 0.f;
    double animationStart = -1.0;
    /// True between a retarget and the arrival it produces. What turns the
    /// arrival into an edge worth reporting rather than a state that is
    /// true on every frame afterwards.
    bool  animationRunning = false;
    /// Replay index this node was last drawn in, for reclaiming the state of
    /// nodes that are gone. See `sweepSceneState`.
    uint64_t lastSeen = 0;
    /// False until the node has declared an animation once. The first
    /// declaration snaps rather than eases — see `NodeAnimate`.
    bool  animationSeen = false;
    bool  extentKnown = false;
  };

  /// Where a scrolled node has been dragged to. Keyed by producer-assigned
  /// node id, and deliberately *not* cleared when the producer republishes:
  /// surviving the republish is the whole point.
  std::unordered_map<uint32_t, SceneNodeState> sceneState_;
  std::vector<canvas::SceneNodeRect>           sceneNodes_;
  /// Node under the pointer, and the one a press started in. Zero is "none",
  /// which is why a producer should number its nodes from one.
  uint32_t hoveredNode_ = 0;
  uint32_t pressedNode_ = 0;
  /// Timestamp of the last animation step, so a step covers real elapsed
  /// time rather than assuming a frame rate. Negative until the first step.
  double sceneAnimationTime_ = -1.0;
  /// Counts replays, so node state can be aged out by how long a node has
  /// been absent rather than by wall-clock time — a window nobody is drawing
  /// should not forget anything.
  uint64_t sceneReplayIndex_ = 0;
  /// See `takeSceneResume`.
  bool     sceneResume_      = false;

  /// Drops the retained state of nodes that have not been drawn for a while.
  ///
  /// Without this the map is append-only for the life of the window: node ids
  /// come from the producer, and one that mints an id per list row leaves an
  /// entry behind for every row ever scrolled past. Nothing here is large,
  /// but nothing here is ever freed either, and a compositor is a process
  /// that runs for weeks.
  ///
  /// Generous rather than prompt, because forgetting is visible: a node that
  /// comes back inside the window keeps where it was scrolled to, and one
  /// that comes back after it starts again from the top.
  void sweepSceneState();
  /// A point where the frame's recording has to be interrupted.
  ///
  /// `boundaries[i]` sits between segment i and segment i+1. Only the radius
  /// travels with it — the rect is already baked into the composite quad that
  /// opens the following segment.
  struct Boundary {
    enum class Kind { Backdrop, ContentBegin, ContentEnd };
    Kind  kind   = Kind::Backdrop;
    float radius = 8.f;
  };

  /// Records caller-owned main content, then presents (windowed) or copies
  /// out (offscreen).
  ///
  /// `mainCallback` owns begin/end of the main UI render pass(es) so it can
  /// interrupt for backdrop blur (end → capture/blur → begin LOAD → continue).
  void submitFrame(std::function<void(VkCommandBuffer, u32)> mainCallback);

  void beginMainRenderPass(VkCommandBuffer commandBuffer, bool clear);
  void endMainRenderPass(VkCommandBuffer commandBuffer);

  /// Replays the draw list into one ordered batch stream in *index order*,
  /// switching specialized pipelines without changing paint order.
  ///
  /// Blur commands close the current segment and record a boundary; the GPU
  /// work between segments happens in `render`'s main callback.
  void replayDrawList(const canvas::DrawList &list, float viewW, float viewH,
                      std::vector<Boundary> &outBoundaries);

  /// Quad that samples the blur result over `x,y,w,h`.
  ///
  /// UVs are the rect's own window position over the viewport, which makes the
  /// interpolated coordinate at any pixel equal that pixel's position — so the
  /// blur image lines up one-to-one with the frame whatever the rect is.
  /// Scaled by the fraction of the image this radius occupies, since each blur
  /// gets its own resolution out of one allocation.
  /// `cornerRadius` cuts the composite to the outline it sits under;
  /// 0 leaves it square.
  void pushBlurComposite(float x, float y, float w, float h, float viewW,
                         float viewH, float radius, float cornerRadius = 0.f);

  void createWindowSurface();
  void createSwapchain();
  void cleanupSwapchain();
  void createPresentSyncObjects();
  void createSyncObjects();
  void createCommandBuffer();
  void createColorResources();
  void createResolveResources();
  void createDepthResources();
  void createStagingBuffer();
  void createFramebuffer();

  /// Whether the exported buffer *could* be the resolve attachment: it exists
  /// and its format and modifier allow it. See `setExportTarget`.
  bool exportIsRenderable() const;

  /// Whether this frame is actually resolved straight into it.
  ///
  /// A frame that blurs is not, and that is not an optimisation — it is the
  /// difference between a consumer seeing whole frames and seeing half of one.
  /// Every blur interrupts the main pass, and ending a pass resolves it, so a
  /// blurred frame would land in the shared buffer several times: once with
  /// everything drawn so far and nothing after it, and again at the end. The
  /// consumer is only told to wait for the *submit*, so nothing stops it
  /// sampling between those two writes — and what it draws then is the window
  /// with everything below the blur missing. See `frameBlurs_`.
  bool directToExport() const { return exportIsRenderable() && !frameBlurs_; }

  /// Brings the local resolve attachment into line with where this window's
  /// frames now land — allocated when the frame needs somewhere of its own,
  /// released when the shared image is that place — and rebuilds the
  /// framebuffers around whichever it is. Callers must have waited for this
  /// window's frames first.
  void syncResolveTarget();

  /// Whether the frame being recorded interrupts its main pass to blur.
  ///
  /// Set from the draw list before anything is recorded, because it decides
  /// which image the framebuffers name. It changes only when a window starts
  /// or stops blurring — a launcher overlay opening, a panel losing its
  /// frost — and each change costs the stall and the two framebuffers that
  /// `syncResolveTarget` rebuilds.
  bool frameBlurs_ = false;

  /// Everything `resize()` rebuilds, and everything the destructor frees.
  void createSizedResources();
  void destroySizedResources();

  RenderDevice &dev_;

  /// The two renderers that write into this window's attachments.
  ///
  /// Per window rather than shared, because each holds a frame's worth of
  /// state that is only meaningful against one target: `QuadRenderer` a
  /// host-visible vertex arena per frame slot and the batch list built from
  /// this window's draw list, `BlurPass` scratch images sized to this
  /// window's extent. Their *pipelines* are window-independent — they compile
  /// against the device's render passes — and could be hoisted to the device
  /// later if a compositor with many surfaces makes the duplication matter.
  QuadRenderer quads_;
  BlurPass     blur_;
  bool         renderersReady_ = false;

  /// Reused across Mesh/Polyline commands so replaying a frame full of charts
  /// does not allocate per command.
  std::vector<vec2> meshPointScratch_;

  bool        windowed_ = false;
  GLFWwindow *window_   = nullptr;
  /// See the constructor: whose VRAM this is, for the ledger's benefit.
  uint32_t    ownerId_  = 0;
  /// See `setTransparent`.
  bool        transparent_ = false;

  /// Where frames go when this window is neither presenting nor being read
  /// back on the CPU. Borrowed; see `setExportTarget`.
  canvas::DmabufImage *exportTarget_ = nullptr;
  /// sync_file for the last exported frame, or -1. Owned here until a consumer
  /// takes it — see `takeFrameFence`.
  int frameFence_ = -1;

  VkSurfaceKHR             surface_   = VK_NULL_HANDLE;
  VkSwapchainKHR           swapchain_ = VK_NULL_HANDLE;
  std::vector<VkImage>     swapchainImages_;
  std::vector<VkImageView> swapchainImageViews_;
  VkFormat   swapchainImageFormat_ = VK_FORMAT_B8G8R8A8_UNORM;
  VkExtent2D swapchainExtent_{};

  /// Per in-flight frame: signals that the acquired image is ready to use.
  VkSemaphore imageAvailableSemaphores_[kMaxFramesInFlight]{};
  /// Per *swapchain image* (not frame slot): submit → present wait. Reusing a
  /// frame-slot semaphore is illegal until that image is re-acquired; see
  /// https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html
  std::vector<VkSemaphore> renderFinishedSemaphores_;
  VkCommandBuffer commandBuffers_[kMaxFramesInFlight]{};
  VkFence         inFlightFences_[kMaxFramesInFlight]{};
  /// Device submission index of the work in each slot; 0 if never submitted.
  uint64_t slotSubmission_[kMaxFramesInFlight]{};
  uint32_t currentFrame_ = 0;
  uint64_t frameCounter_ = 0;

  /// Submission resources belong to this window, hence to its render worker.
  /// Command pools are externally synchronized Vulkan objects and cannot be
  /// shared by concurrently recording windows.
  VkQueue       queue_ = VK_NULL_HANDLE;
  std::mutex   *queueMutex_ = nullptr;
  VkCommandPool commandPool_ = VK_NULL_HANDLE;

  /// Scene render target. Sized to the window, format fixed by the device.
  VkExtent2D extent_{};

  // MSAA color attachment.
  VkImage       colorImage_      = VK_NULL_HANDLE;
  VmaAllocation colorImageAlloc_ = VK_NULL_HANDLE;
  VkImageView   colorImageView_  = VK_NULL_HANDLE;

  // Single-sample resolve target: what the MSAA attachment resolves into, and
  // what gets blitted to the swapchain or copied out. Not the same image as
  // colorImage_.
  VkImage       resolveImage_      = VK_NULL_HANDLE;
  VmaAllocation resolveImageAlloc_ = VK_NULL_HANDLE;
  VkImageView   resolveImageView_  = VK_NULL_HANDLE;

  VkImage       depthImage_      = VK_NULL_HANDLE;
  VmaAllocation depthImageAlloc_ = VK_NULL_HANDLE;
  VkImageView   depthImageView_  = VK_NULL_HANDLE;

  /// Same attachments, two render passes: clear (first UI segment) and
  /// continue (LOAD, after a backdrop blur).
  VkFramebuffer framebuffer_         = VK_NULL_HANDLE;
  VkFramebuffer framebufferContinue_ = VK_NULL_HANDLE;

  // Host-visible buffer the resolve is copied into for CPU readback.
  VkBuffer      stagingBuffer_       = VK_NULL_HANDLE;
  VmaAllocation stagingBufferAlloc_  = VK_NULL_HANDLE;
  void         *stagingBufferMapped_ = nullptr;
  VkDeviceSize  stagingBufferSize_   = 0;

  /// Host RGBA of the last `captureFrame` — lets several region PNGs share one
  /// GPU readback within the same settled frame.
  std::vector<uint8_t> captureCache_;
  uint32_t             captureCacheW_ = 0;
  uint32_t             captureCacheH_ = 0;
  bool                 captureCacheValid_ = false;
};
