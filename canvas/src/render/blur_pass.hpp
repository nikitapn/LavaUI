#pragma once

// Dual Kawase blur behind both blur kinds.
//
// Downsample through a halving pyramid, then upsample the same path back. The
// two call sites still differ only in the source:
//   BeginBackdropBlur — RenderWindow::frameImage(), the frame so far.
//   BeginContentBlur  — sceneImage(), a subtree against transparent black.
//
// **Nothing here is window-sized.** The pyramid starts at half the window in
// each axis, which is where the memory went: the first level and the capture
// target were a full frame each, and they are the two largest things a blurred
// surface owns. Halving both costs a quarter of the pixels and is what every
// other compositor does, for the same reason it is safe — the result is
// upsampled by a linear sampler onto a picture that is *already* blurred, so
// the resolution it was blurred at is not something the eye has anything to
// compare against.
//
// The result still *spans* the whole window, so the composite UVs stay 1:1 and
// the reach of one Kawase iteration doubles in window pixels — see
// `iterationsFor`, whose ladder starts an octave higher because of it.

#include <array>
#include <cstdint>
#include <vulkan/vulkan.h>
#include "vk_mem_alloc.h"

#include "util/types.hpp"

class RenderDevice;
class RenderWindow;

class BlurPass {
 public:
  explicit BlurPass(RenderDevice &device) : device_{device} {}

  void setOwner(RenderWindow *owner) { owner_ = owner; }
  ~BlurPass() { cleanUp(); }

  /// The window whose VRAM this scratch belongs to, for `GpuLedger`. Defined
  /// out of line because `RenderWindow` is only forward-declared here.
  uint32_t ownerWindowId() const;

  BlurPass(const BlurPass &) = delete;
  BlurPass &operator=(const BlurPass &) = delete;

  void init();
  void cleanUp();

  /// Allocate the pyramid for this window. `finestRadius` picks how many
  /// levels to keep live; call outside command recording.
  void ensureSize(uint32_t width, uint32_t height, float finestRadius);

  /// Capture of `src` (TRANSFER_SRC, `srcW`×`srcH`) → Dual Kawase.
  /// Leaves the result SHADER_READ_ONLY.
  ///
  /// The source extent is passed rather than assumed because the two callers
  /// disagree about it: a backdrop is captured from a window-sized frame, and
  /// a content blur from `sceneImage()`, which is already at capture scale.
  /// The capture is a filtered blit, so the downsample to the pyramid's first
  /// level costs nothing extra — it is the same blit that was already there.
  void captureAndBlur(VkCommandBuffer cmd, VkImage src, VkImageLayout srcLayout,
                      uint32_t srcW, uint32_t srcH, float radius);

  void beginSceneCapture(VkCommandBuffer cmd);
  void endSceneCapture(VkCommandBuffer cmd);

  VkImage      sceneImage() const { return sceneImage_; }
  /// Size of the pyramid's first level and of the scene capture target — the
  /// window scaled by `kCaptureShift`. What a caller drawing into
  /// `sceneImage()` has to scale its viewport and scissors by.
  uint32_t     captureWidth() const { return captureWidth_; }
  uint32_t     captureHeight() const { return captureHeight_; }
  /// Capture size over window size, for a caller that has to scale geometry
  /// rather than an extent.
  static float captureScale() { return 1.f / float(1u << captureShift()); }
  VkRenderPass sceneRenderPass() const { return sceneRenderPass_; }
  bool         sceneReady() const { return sceneFb_ != VK_NULL_HANDLE; }

  VkImageView resultView() const { return levels_[0].view; }
  VkSampler sampler() const { return sampler_; }

  /// Always 1×1: the upsample lands back at window size.
  vec2 uvScaleFor(float radius) const;

  bool ready() const {
    return pipeline_ != VK_NULL_HANDLE && levels_[0].image != VK_NULL_HANDLE;
  }

  static constexpr float kMaxRadius = 64.f;
  static constexpr uint32_t kMaxLevels = 5;
  /// How far below the window the pyramid starts, as a power of two. 1 is
  /// half in each axis and a quarter of the pixels.
  static constexpr uint32_t kDefaultCaptureShift = 1;

  /// The shift actually in force. `LAVA_BLUR_SHIFT` overrides it, clamped to
  /// 0..2, and 0 restores exactly what this did when every blur was captured
  /// at window size — which is how the two are compared. Read once.
  static uint32_t captureShift();

  /// How many downsample/upsample pairs a radius wants. Public so the
  /// compositor can reason about cost; 1 up to 16 px, 3 at 64 px.
  static uint32_t iterationsFor(float radius);

  /// Kept so existing callers compile; Dual Kawase sizes the pyramid from
  /// the window, not from a single downscale.
  static uint32_t downscaleFor(float radius);

 private:
  struct Level {
    VkImage image = VK_NULL_HANDLE;
    VmaAllocation alloc = VK_NULL_HANDLE;
    VkImageView view = VK_NULL_HANDLE;
    VkFramebuffer fb = VK_NULL_HANDLE;
    VkDescriptorSet set = VK_NULL_HANDLE;
    uint32_t w = 0;
    uint32_t h = 0;
  };

  void createImages(uint32_t width, uint32_t height);
  void destroyImages();
  void createPipeline();
  void createSampler();
  void createSceneRenderPass();
  void createSceneTarget(uint32_t width, uint32_t height);
  void destroySceneTarget();
  void kawasePass(VkCommandBuffer cmd, VkDescriptorSet srcSet,
                  VkFramebuffer dstFb, uint32_t destW, uint32_t destH,
                  float offset, bool upsample);

  RenderDevice &device_;
  RenderWindow *owner_ = nullptr;

  std::array<Level, kMaxLevels> levels_{};
  uint32_t levelCount_ = 0;

  VkSampler sampler_ = VK_NULL_HANDLE;

  VkImage       sceneImage_ = VK_NULL_HANDLE;
  VmaAllocation sceneAlloc_ = VK_NULL_HANDLE;
  VkImageView   sceneView_ = VK_NULL_HANDLE;
  VkFramebuffer  sceneFb_ = VK_NULL_HANDLE;
  VkRenderPass   sceneRenderPass_ = VK_NULL_HANDLE;

  VkRenderPass   renderPass_ = VK_NULL_HANDLE;
  VkDescriptorSetLayout setLayout_ = VK_NULL_HANDLE;
  VkDescriptorPool      pool_ = VK_NULL_HANDLE;
  VkPipelineLayout      pipelineLayout_ = VK_NULL_HANDLE;
  VkPipeline            pipeline_ = VK_NULL_HANDLE;

  VkFormat format_ = VK_FORMAT_R8G8B8A8_UNORM;
  /// The window. Kept because the capture blit reads a window-sized frame and
  /// because `ensureSize` compares against it.
  uint32_t fullWidth_ = 0;
  uint32_t fullHeight_ = 0;
  /// The window at capture scale — every image here is this size or smaller.
  uint32_t captureWidth_ = 0;
  uint32_t captureHeight_ = 0;
};
