#pragma once

// Backdrop blur: downsample the main resolve into a sampleable image, run a
// separable Gaussian (H then V, repeated), and leave the result sampleable so
// the quad pipeline can composite it under a glass panel.
//
// Used when the draw list hits BeginBackdropBlur — UI drawn so far must already
// be resolved into Vulkan::resolveImage().
//
// Why downsample rather than widen the kernel: the fragment shader takes a
// fixed 9 taps, so spreading them by `radius` texels does not blur, it stamps
// nine offset copies of the UI. A wide blur has to come from bigger texels and
// repeated passes, both of which keep tap spacing at or under one texel.

#include <cstdint>
#include <vulkan/vulkan.h>

#include "util/types.hpp"

class Vulkan;

class BlurPass {
 public:
  explicit BlurPass(Vulkan &vulkan) : vulkan_{vulkan} {}
  ~BlurPass() { cleanUp(); }

  BlurPass(const BlurPass &) = delete;
  BlurPass &operator=(const BlurPass &) = delete;

  void init();
  void cleanUp();

  /// Ensure the ping-pong images match the main render extent, downscaled to
  /// suit `maxRadius` — the widest radius any glass rect will ask for this
  /// frame. Call outside command recording (it may wait on the GPU).
  void ensureSize(uint32_t width, uint32_t height, float maxRadius);

  /// Full-frame capture of `src` (TRANSFER_SRC) → separable blur.
  /// Leaves the result SHADER_READ_ONLY and records which ping-pong image holds it.
  void captureAndBlur(VkCommandBuffer cmd, VkImage src, VkImageLayout srcLayout,
                      float radius);

  VkImageView resultView() const { return resultIsA_ ? viewA_ : viewB_; }
  VkSampler sampler() const { return sampler_; }

  bool ready() const { return pipeline_ != VK_NULL_HANDLE && imageA_ != VK_NULL_HANDLE; }

  /// Widest radius (screen pixels) the pass will honour.
  static constexpr float kMaxRadius = 16.f;

  /// Downscale that puts `radius` at about two texels of the blur image.
  ///
  /// Both halves of that matter. Too little downscale and the 9-tap kernel
  /// cannot reach the width without spreading its taps past a texel, which
  /// ghosts. Too much and the bilinear upsample of the result shows its own
  /// grid — which is what a fixed quarter-res did to a two-pixel blur: the
  /// Gaussian had nothing left to smooth and the 4×4 blocks came through bare.
  /// Keeping the ratio fixed means the content is always smooth over a couple
  /// of texels, so the upsample has nothing to expose.
  static uint32_t downscaleFor(float radius);

 private:
  void createImages(uint32_t width, uint32_t height);
  void destroyImages();
  void createPipeline();
  void createSampler();
  void blurPass(VkCommandBuffer cmd, VkFramebuffer dstFb, VkDescriptorSet srcSet,
                vec2 direction, float spacing);

  Vulkan &vulkan_;

  VkImage        imageA_ = VK_NULL_HANDLE;
  VkDeviceMemory memoryA_ = VK_NULL_HANDLE;
  VkImageView    viewA_ = VK_NULL_HANDLE;

  VkImage        imageB_ = VK_NULL_HANDLE;
  VkDeviceMemory memoryB_ = VK_NULL_HANDLE;
  VkImageView    viewB_ = VK_NULL_HANDLE;

  VkSampler sampler_ = VK_NULL_HANDLE;

  VkRenderPass   renderPass_ = VK_NULL_HANDLE;
  VkFramebuffer  fbA_ = VK_NULL_HANDLE;
  VkFramebuffer  fbB_ = VK_NULL_HANDLE;

  VkDescriptorSetLayout setLayout_ = VK_NULL_HANDLE;
  VkDescriptorPool      pool_ = VK_NULL_HANDLE;
  VkDescriptorSet       setA_ = VK_NULL_HANDLE;  // samples A
  VkDescriptorSet       setB_ = VK_NULL_HANDLE;  // samples B
  VkPipelineLayout      pipelineLayout_ = VK_NULL_HANDLE;
  VkPipeline            pipeline_ = VK_NULL_HANDLE;

  VkFormat format_ = VK_FORMAT_R8G8B8A8_UNORM;
  /// Blur-image size, i.e. the main extent divided by `scale_`.
  uint32_t width_ = 0;
  uint32_t height_ = 0;
  /// Main render extent, kept so the capture blit knows its source rect
  /// exactly rather than reconstructing it from width_ * scale_.
  uint32_t fullWidth_ = 0;
  uint32_t fullHeight_ = 0;
  uint32_t scale_ = 1;
  bool resultIsA_ = true;
};
