#pragma once

// Dual Kawase blur behind both blur kinds.
//
// Downsample through a half-res pyramid, then upsample the same path back
// to full resolution. Cheaper than a wide Gaussian, and it does not leave
// the 9-tap grid that read as dithering on a sky. The two call sites still
// differ only in the source:
//   BeginBackdropBlur — RenderDevice::resolveImage(), the frame so far.
//   BeginContentBlur  — sceneImage(), a subtree against transparent black.
//
// The result is always full-window size, so the composite UVs are 1:1.

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

  /// Full-frame capture of `src` (TRANSFER_SRC) → Dual Kawase.
  /// Leaves the full-size result SHADER_READ_ONLY.
  void captureAndBlur(VkCommandBuffer cmd, VkImage src, VkImageLayout srcLayout,
                      float radius);

  void beginSceneCapture(VkCommandBuffer cmd);
  void endSceneCapture(VkCommandBuffer cmd);

  VkImage      sceneImage() const { return sceneImage_; }
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

  /// How many downsample/upsample pairs a radius wants. Public so the
  /// compositor can reason about cost; 1 at 8 px, 4 at 64 px.
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
  uint32_t fullWidth_ = 0;
  uint32_t fullHeight_ = 0;
};
