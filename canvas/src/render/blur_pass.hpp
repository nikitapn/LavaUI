#pragma once

// The Gaussian behind both blur kinds: downsample a source image into a
// ping-pong pair, run a separable blur (H then V), and leave the result
// sampleable so the quad pipeline can composite it.
//
// The two kinds differ only in what they hand over as the source:
//   BeginBackdropBlur — RenderDevice::resolveImage(), the frame as painted so far.
//   BeginContentBlur  — sceneImage(), a subtree drawn on its own against
//                       transparent black (see beginSceneCapture).
//
// Why downsample rather than widen the kernel: the fragment shader takes a
// fixed 9 taps, so spreading them by `radius` texels does not blur, it stamps
// nine offset copies of the source. A wide blur has to come from bigger texels,
// which keeps tap spacing at or under one texel.
//
// One allocation serves every radius in a frame. It is sized for the finest of
// them, and each blur writes the top-left sub-region matching its own radius, so
// a narrow blur is never forced onto a wide one's grid.

#include <cstdint>
#include <vulkan/vulkan.h>
#include "vk_mem_alloc.h"

#include "util/types.hpp"

class RenderDevice;

class BlurPass {
 public:
  explicit BlurPass(RenderDevice &device) : device_{device} {}
  ~BlurPass() { cleanUp(); }

  BlurPass(const BlurPass &) = delete;
  BlurPass &operator=(const BlurPass &) = delete;

  void init();
  void cleanUp();

  /// Ensure the ping-pong images can serve `finestRadius` — the *smallest*
  /// radius any blur will ask for this frame, since that is the one needing the
  /// most resolution. Wider blurs then use a sub-region of the same images at
  /// their own coarser grid. Call outside command recording (it may wait on the
  /// GPU).
  void ensureSize(uint32_t width, uint32_t height, float finestRadius);

  /// Full-frame capture of `src` (TRANSFER_SRC) → separable blur.
  /// Leaves the result SHADER_READ_ONLY and records which ping-pong image holds it.
  void captureAndBlur(VkCommandBuffer cmd, VkImage src, VkImageLayout srcLayout,
                      float radius);

  // ─── Content blur: the subtree is the source, not the frame ──────────────
  //
  // Backdrop blur reads the resolve, which already holds the UI. Content blur
  // needs the subtree *alone*, so it gets its own window-sized target cleared
  // to transparent black. Window-sized and not rect-sized because draw-list
  // vertices are already in window coordinates — a smaller target would mean
  // translating every one of them, and the blur has to reach outside the rect
  // anyway for the edge to be soft.

  /// Opens the scene pass. Contents are cleared, so each capture starts empty.
  void beginSceneCapture(VkCommandBuffer cmd);
  /// Closes it, leaving the image TRANSFER_SRC ready for `captureAndBlur`.
  void endSceneCapture(VkCommandBuffer cmd);

  VkImage      sceneImage() const { return sceneImage_; }
  VkRenderPass sceneRenderPass() const { return sceneRenderPass_; }
  bool         sceneReady() const { return sceneFb_ != VK_NULL_HANDLE; }

  VkImageView resultView() const { return resultIsA_ ? viewA_ : viewB_; }
  VkSampler sampler() const { return sampler_; }

  /// Fraction of the blur images a blur of `radius` will occupy.
  ///
  /// Deterministic from the current allocation, which is what lets a composite
  /// quad be built during draw-list replay — before any command is recorded.
  vec2 uvScaleFor(float radius) const;

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
  void createSceneRenderPass();
  void createSceneTarget(uint32_t width, uint32_t height);
  void destroySceneTarget();
  /// One H or V pass over the top-left `subW`x`subH` of the images.
  void blurPass(VkCommandBuffer cmd, VkFramebuffer dstFb, VkDescriptorSet srcSet,
                vec2 direction, float spacing, uint32_t subW, uint32_t subH);

  /// Grid one radius gets: the sub-region it writes and its tap spacing.
  struct Sub {
    uint32_t w = 1;
    uint32_t h = 1;
    float spacing = 1.f;
  };
  Sub subFor(float radius) const;

  RenderDevice &device_;

  VkImage       imageA_ = VK_NULL_HANDLE;
  VmaAllocation allocA_ = VK_NULL_HANDLE;
  VkImageView   viewA_ = VK_NULL_HANDLE;

  VkImage       imageB_ = VK_NULL_HANDLE;
  VmaAllocation allocB_ = VK_NULL_HANDLE;
  VkImageView   viewB_ = VK_NULL_HANDLE;

  VkSampler sampler_ = VK_NULL_HANDLE;

  /// Window-sized, single-sample target a subtree renders into for content blur.
  VkImage       sceneImage_ = VK_NULL_HANDLE;
  VmaAllocation sceneAlloc_ = VK_NULL_HANDLE;
  VkImageView   sceneView_ = VK_NULL_HANDLE;
  VkFramebuffer  sceneFb_ = VK_NULL_HANDLE;
  VkRenderPass   sceneRenderPass_ = VK_NULL_HANDLE;

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
  /// Downscale the images were allocated for: the finest any blur may use.
  uint32_t scaleFinest_ = 1;
  bool resultIsA_ = true;
};
