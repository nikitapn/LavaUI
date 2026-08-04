#pragma once

#include <cstdint>
#include <functional>
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
/// Not thread-safe, and deliberately so. Command pool, queue submission and
/// present all require external synchronization, and every window is driven
/// from the one thread that owns the event loop.
class RenderWindow {
 public:
  /// CPU/GPU overlap: while the GPU draws slot N, the CPU builds slot N+1.
  static constexpr uint32_t kMaxFramesInFlight = 2;

  /// Presents into `window`'s surface. The GLFW window belongs to the caller
  /// and must outlive this object.
  RenderWindow(RenderDevice &device, GLFWwindow *window);

  /// Offscreen: no surface, no swapchain, no present. Each frame's resolve is
  /// copied into a staging buffer for `readPixels`.
  RenderWindow(RenderDevice &device, uint32_t width, uint32_t height);

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

  /// Rebinds the glyph atlas this window's batches sample. The atlas belongs
  /// to the shared `TextRenderer`, so growing it invalidates the binding in
  /// *every* window and each has to be told.
  void setGlyphAtlas(VkImageView view, VkSampler sampler);

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
  VkImage     resolveImage() const { return resolveImage_; }
  VkImageView resolveImageView() const { return resolveImageView_; }
  VkFramebuffer mainFramebuffer() const { return framebuffer_; }

  /// If the framebuffer size drifted (a WM resize, `setWindowFrame`), rebuild
  /// the swapchain and every sized attachment. True if a rebuild happened.
  bool resize();

  // ─── Window ──────────────────────────────────────────────────────────────

  bool isWindowed() const { return windowed_; }
  GLFWwindow *window() const { return window_; }
  bool windowShouldClose() const;
  /// Ask the loop to exit (sets GLFW should-close).
  void requestClose();

  /// Move/resize in screen coordinates. A size change rebuilds the swapchain
  /// and offscreen targets on the next `resize()`. No-op when not windowed.
  void setWindowFrame(int x, int y, int width, int height);
  void setWindowVisible(bool visible);

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
  /// and the longer side exceeds it, box-downsamples so
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

  /// Aims the innermost scrollable node under the pointer at a new offset.
  ///
  /// Moves the node's *target*, not the node: the visible offset eases toward
  /// it in `advanceSceneAnimations`. A wheel notch is a discrete step, and
  /// applying it directly is what makes wheel scrolling feel like a stepper
  /// rather than like scrolling.
  ///
  /// Returns true if the target changed, which is the caller's signal that
  /// the event has been consumed and this window needs a repaint.
  bool scrollSceneNode(float pointerX, float pointerY, float deltaX,
                       float deltaY);

  /// Steps every in-flight node animation to `now` (seconds, monotonic).
  ///
  /// Returns true while anything is still moving — the caller's cue to keep
  /// the frame loop awake, since an animation is a repaint nobody requested
  /// and nothing else will ask for the next one.
  ///
  /// `outMoved` collects the nodes whose offset actually changed, so the
  /// window can tell the producer where they ended up.
  bool advanceSceneAnimations(double now,
                              std::vector<canvas::SceneNodeOffset> &outMoved);

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

  /// Records shadow + caller-owned main content, then presents (windowed) or
  /// copies out (offscreen).
  ///
  /// `mainCallback` owns begin/end of the main UI render pass(es) so it can
  /// interrupt for backdrop blur (end → capture/blur → begin LOAD → continue).
  void submitFrame(std::function<void(VkCommandBuffer)>      shadowCallback,
                   std::function<void(VkCommandBuffer, u32)> mainCallback);

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
  void pushBlurComposite(float x, float y, float w, float h, float viewW,
                         float viewH, float radius);

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

  VkSurfaceKHR             surface_   = VK_NULL_HANDLE;
  VkSwapchainKHR           swapchain_ = VK_NULL_HANDLE;
  std::vector<VkImage>     swapchainImages_;
  std::vector<VkImageView> swapchainImageViews_;
  VkFormat   swapchainImageFormat_ = VK_FORMAT_B8G8R8A8_SRGB;
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
