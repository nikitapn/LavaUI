#pragma once

#include <cstdint>
#include <functional>
#include <vector>

#include <vulkan/vulkan.h>

#include "vk_mem_alloc.h"

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

  // ─── Frame ───────────────────────────────────────────────────────────────

  /// Records shadow + caller-owned main content, then presents (windowed) or
  /// copies out (offscreen).
  ///
  /// `mainCallback` owns begin/end of the main UI render pass(es) so it can
  /// interrupt for backdrop blur (end → capture/blur → begin LOAD → continue).
  void render(std::function<void(VkCommandBuffer)>      shadowCallback,
              std::function<void(VkCommandBuffer, u32)> mainCallback);

  void beginMainRenderPass(VkCommandBuffer commandBuffer, bool clear);
  void endMainRenderPass(VkCommandBuffer commandBuffer);

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

 private:
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
