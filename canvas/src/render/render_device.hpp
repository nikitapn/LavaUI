#pragma once

#include <iostream>
#include <stdexcept>
#include <vector>

#include <boost/stacktrace.hpp>

#include <vulkan/vulkan.h>
#include <vulkan/vulkan_core.h>

#include "vk_mem_alloc.h"

struct GLFWwindow;

#include "util/types.hpp"
#include "util/cout_ext.hpp"
#include "render/vulkan_ptr.hpp"

extern bool g_ValidationFromResult;

#define VR(x, message)                        \
  if (x != VK_SUCCESS) {                      \
    g_ValidationFromResult = true;            \
    std::cerr << clr::red                     \
      << "Vulkan Error: " << message << '\n'  \
      << "\tVkResult: " << x << '\n'          \
      << "\tStack trace:\n"                   \
      << boost::stacktrace::stacktrace()      \
      << clr::reset << std::endl;             \
    throw std::runtime_error(message);        \
  }

class Shaders;

namespace vk {

/// GPU buffer owned through Vulkan/VMA. Prefer `RenderDevice::destroyBuffer` over
/// freeing memory by hand — VMA suballocates and raw `vkFreeMemory` is wrong.
struct Buffer {
  VkBuffer      buffer     = VK_NULL_HANDLE;
  VmaAllocation allocation = VK_NULL_HANDLE;
  u32           size       = 0;

  operator bool() const noexcept { return buffer != VK_NULL_HANDLE; }
};

};

class RenderDevice
{
  bool enableValidationLayers_ = false;
  // Vulkan instance
  VkInstance instance_ = VK_NULL_HANDLE;
  // Debug handle
  VkDebugUtilsMessengerEXT debugMessenger_ = VK_NULL_HANDLE;
  // Used to enumerate physical devices
  VkPhysicalDevice physicalDevice_ = VK_NULL_HANDLE;
  // Cached device properties for the selected device
  VkPhysicalDeviceProperties physicalDeviceProperties_;
  // Logical device
  VkDevice device_ = VK_NULL_HANDLE;
  // Whether VK_KHR_present_mode_fifo_latest_ready was found and enabled at
  // device creation. The present mode it unlocks may only be requested when
  // this is true — see createSwapchain.
  bool fifoLatestReadyEnabled_ = false;
  // GPUOpen VMA — all createBuffer/createImage go through this.
  // Allocations live next to their VkBuffer/VkImage at each call site.
  VmaAllocator allocator_ = VK_NULL_HANDLE;
  // Main graphics queue (also used for present when windowed)
  u32     graphicsAndPresentationQueueFamilyIdx_ = -1;
  VkQueue graphicsQueue_ = VK_NULL_HANDLE;

  // Optional GLFW window present path. When window_ is non-null we create a
  // swapchain and blit the offscreen resolve target into it each frame —
  // no GPU→CPU readback on the hot path.
  bool        windowed_ = false;
  GLFWwindow *window_ = nullptr;
  bool        ownsWindow_ = false; // we called glfwCreateWindow
  VkSurfaceKHR surface_ = VK_NULL_HANDLE;
  VkSwapchainKHR swapchain_ = VK_NULL_HANDLE;
  std::vector<VkImage> swapchainImages_;
  std::vector<VkImageView> swapchainImageViews_;
  VkFormat   swapchainImageFormat_ = VK_FORMAT_B8G8R8A8_SRGB;
  VkExtent2D swapchainExtent_{};

  /// CPU/GPU overlap: while the GPU draws slot N, the CPU builds slot N+1.
  static constexpr uint32_t kMaxFramesInFlight = 2;
  /// Per in-flight frame: signals that the acquired image is ready to use.
  VkSemaphore imageAvailableSemaphores_[kMaxFramesInFlight]{};
  /// Per *swapchain image* (not frame slot): submit → present wait. Reusing a
  /// frame-slot semaphore is illegal until that image is re-acquired; see
  /// https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html
  std::vector<VkSemaphore> renderFinishedSemaphores_;
  VkCommandBuffer commandBuffers_[kMaxFramesInFlight]{};
  VkFence inFlightFences_[kMaxFramesInFlight]{};
  uint32_t currentFrame_ = 0;
  /// Monotonic frame count, for ageing out deferred destructions.
  uint64_t frameCounter_ = 0;

  /// GPU resources waiting for the frames that might reference them to retire.
  struct PendingDestroy {
    VkImage       image      = VK_NULL_HANDLE;
    VmaAllocation allocation = VK_NULL_HANDLE;
    VkImageView   view       = VK_NULL_HANDLE;
    uint64_t      retireAt   = 0;
  };
  std::vector<PendingDestroy> trash_;

  // Offscreen render target (always used as the scene render target)
  VkFormat   colorFormat_;
  VkExtent2D extent_;

  VkPhysicalDeviceMemoryProperties deviceMemoryProperties_;
  VkRenderPass                     renderPass_ = VK_NULL_HANDLE;
  /// Same attachments as renderPass_ but LOAD (continue after backdrop blur).
  VkRenderPass                     renderPassContinue_ = VK_NULL_HANDLE;
  VkFramebuffer                    framebuffer_ = VK_NULL_HANDLE;
  /// Framebuffer for continue pass (same images; different render pass object).
  VkFramebuffer                    framebufferContinue_ = VK_NULL_HANDLE;
  VkCommandPool                    commandPool_ = VK_NULL_HANDLE;

  // MSAA sampling stuff
  VkSampleCountFlagBits msaaSamples_ = VK_SAMPLE_COUNT_1_BIT;
  VkImage               colorImage_ = VK_NULL_HANDLE;
  VmaAllocation         colorImageAlloc_ = VK_NULL_HANDLE;
  VkImageView           colorImageView_ = VK_NULL_HANDLE;

  // Single-sample resolve target: what the MSAA color attachment resolves
  // into, and what gets copied out for readback. Not the same image as
  // colorImage_ above (that one is TRANSIENT_ATTACHMENT_BIT and MSAA-only).
  VkImage       resolveImage_ = VK_NULL_HANDLE;
  VmaAllocation resolveImageAlloc_ = VK_NULL_HANDLE;
  VkImageView   resolveImageView_ = VK_NULL_HANDLE;

  // Host-visible staging buffer that resolveImage_ gets copied into every
  // frame, for CPU readback via readPixels().
  VkBuffer      stagingBuffer_ = VK_NULL_HANDLE;
  VmaAllocation stagingBufferAlloc_ = VK_NULL_HANDLE;
  void         *stagingBufferMapped_ = nullptr;
  VkDeviceSize  stagingBufferSize_ = 0;

  /// Host RGBA of the last `captureFrame` — lets multiple region PNGs share one
  /// GPU readback within the same settled frame.
  std::vector<uint8_t> captureCache_;
  uint32_t             captureCacheW_ = 0;
  uint32_t             captureCacheH_ = 0;
  bool                 captureCacheValid_ = false;

  // Depth buffer stuff
  VkImage       depthImage_ = VK_NULL_HANDLE;
  VmaAllocation depthImageAlloc_ = VK_NULL_HANDLE;
  VkImageView   depthImageView_ = VK_NULL_HANDLE;

  // Shadow mapping stuff
  VkImage       shadowImage_ = VK_NULL_HANDLE;
  VmaAllocation shadowImageAlloc_ = VK_NULL_HANDLE;
  VkImageView   shadowImageView_ = VK_NULL_HANDLE;
  VkSampler      shadowSampler_ = VK_NULL_HANDLE;
  VkRenderPass   shadowRenderPass_ = VK_NULL_HANDLE;
  VkFramebuffer  shadowFramebuffer_ = VK_NULL_HANDLE;
  uint32_t       shadowMapSize_ = 2048; // Shadow map resolution

#ifdef INCLUDE_IMGUI
  // ImGui
  VkDescriptorPool imguiDescriptorPool_ = VK_NULL_HANDLE;
  bool             imguiInitialized_ = false;
#endif

  // Step 0: Enable validation layers
  static VKAPI_ATTR VkBool32 VKAPI_CALL
  debugCallback(VkDebugUtilsMessageSeverityFlagBitsEXT      messageSeverity,
                VkDebugUtilsMessageTypeFlagsEXT             messageType,
                const VkDebugUtilsMessengerCallbackDataEXT *pCallbackData,
                void                                       *pUserData);

  static bool checkValidationLayerSupport(
    const std::vector<const char *> &validationLayers);

  static VkResult createDebugUtilsMessengerEXT(
    VkInstance                                instance,
    const VkDebugUtilsMessengerCreateInfoEXT *pCreateInfo,
    const VkAllocationCallbacks              *pAllocator,
    VkDebugUtilsMessengerEXT                 *pDebugMessenger);

  static void destroyDebugUtilsMessengerEXT(
    VkInstance                   instance,
    VkDebugUtilsMessengerEXT     debugMessenger,
    const VkAllocationCallbacks *pAllocator);

  static VkDebugUtilsMessengerCreateInfoEXT createDebugMessengerInfo();

  void setupDebugMessenger();

  // Step 1: Create instance -> Enumerate physical devices -> Create Device
  void createVkInstance(const char *applicationName);
  bool checkExtensionsSupport(
    const std::vector<const char *> &requiredExtensions);
  VkSampleCountFlagBits getMaxUsableSampleCount();
  void                  selectSupportedGraphicsCard();

  // Step 2: Creates logical device and one graphics queue
  void createLogicalDevice();
  void createAllocator();
  void destroyAllocator();
  void createSyncObjects();

  uint32_t findMemoryProperties(uint32_t              memoryTypeBitsRequirement,
                                VkMemoryPropertyFlags requiredProperties);

  // Offscreen resolve target + host-visible staging buffer readPixels() reads
  // from (replaces the old swapchain + present).
  void createResolveResources();
  void createStagingBuffer();

  vk::Buffer createImmutableBuffer(
    const void           *bufferData,
    VkDeviceSize          bufferSize,
    VkBufferUsageFlagBits usageFlagBits);


  // MSAA sampling stuff
  void createColorResources();
  
  // Depth buffer stuff
  void createDepthResources();
  VkFormat findDepthFormat();
  VkFormat findSupportedFormat(const std::vector<VkFormat>& candidates, VkImageTiling tiling, VkFormatFeatureFlags features);
  bool hasStencilComponent(VkFormat format);

  // Shadow mapping stuff
  void createShadowResources();
  void createShadowRenderPass();
  void createShadowFramebuffer();
  void beginShadowPass(VkCommandBuffer commandBuffer);

  // Step 3: Create render pass, framebuffer, command pool, command buffer
  /// Clear pass (first UI segment) + continue pass (LOAD after blur).
  void createRenderPass();
  void createFramebuffer();
  void createCommandPool();
  void createDescriptorPool();
  void createDescriptorSet();
  void createCommandBuffer();
#ifdef INCLUDE_IMGUI
  void initImGui();
#endif

  void createSwapchain();
  void cleanupSwapchain();
  void createWindowSurface();
  void createPresentSyncObjects();

 public:
  /// Headless / offscreen (smoke tests, optional Image embed).
  void init(const char *applicationName, int width, int height);

  /// Creates a GLFW window and presents into its swapchain each frame.
  void initWithWindow(const char *applicationName, int width, int height,
                      const char *title);

  /// Records shadow + caller-owned main content, then presents.
  /// `mainCallback` owns begin/end of the main UI render pass(es) so it can
  /// interrupt for backdrop blur (end → capture/blur → begin LOAD → continue).
  void renderWithShadows(
    std::function<void(VkCommandBuffer)> shadowCallback,
    std::function<void(VkCommandBuffer, u32)> mainCallback);

  void beginMainRenderPass(VkCommandBuffer commandBuffer, bool clear);
  void endMainRenderPass(VkCommandBuffer commandBuffer);

  VkImage     resolveImage() const { return resolveImage_; }
  VkImageView resolveImageView() const { return resolveImageView_; }
  VkFormat    colorFormat() const { return colorFormat_; }
  VkFramebuffer mainFramebuffer() const { return framebuffer_; }

  /// Block until the *current* frame slot is free (GPU finished its last use).
  /// With 2 frames in flight this does not wait for the other slot, so the CPU
  /// can prepare frame N+1 while the GPU still paints N.
  void waitForInFlightFrame();

  /// Block until every in-flight frame is done. Required before destroying or
  /// replacing shared GPU resources (glyph atlas grow, buffer recreate).
  void waitForAllFramesInFlight();

  /// Slot the next `waitForInFlightFrame` / record / submit will use (0 or 1).
  uint32_t currentFrameSlot() const { return currentFrame_; }
  static constexpr uint32_t framesInFlight() { return kMaxFramesInFlight; }

  /// Destroys an image once no in-flight frame can still reference it.
  ///
  /// The immediate `destroyImage` is only safe for something the GPU has
  /// provably finished with. Anything that was drawn recently — a texture the
  /// app just stopped using, an atlas page being retired — may still be
  /// referenced by a command buffer that has been submitted and not yet
  /// completed, and freeing it there is a use-after-free the validation layer
  /// reports as a crash somewhere else entirely.
  ///
  /// Queued here instead and released by `collectGarbage()` after
  /// `kMaxFramesInFlight` frames have been presented, which is the point every
  /// command buffer that could name it has retired. Handles are nulled so the
  /// caller cannot use them again.
  void destroyImageDeferred(VkImage &image, VmaAllocation &allocation,
                            VkImageView &view);

  /// Releases anything queued by `destroyImageDeferred` that has aged out.
  /// Called once per presented frame.
  void collectGarbage();

  /// Frames presented since start. Monotonic, unlike `currentFrameSlot()`.
  uint64_t frameCounter() const { return frameCounter_; }

  void cleanUp();

  bool isWindowed() const { return windowed_; }
  GLFWwindow *window() const { return window_; }
  bool windowShouldClose() const;
  /// Ask the main loop to exit (sets GLFW should-close).
  void requestClose();

#ifdef INCLUDE_IMGUI
  /// Call after installing app-level GLFW callbacks so ImGui can chain.
  void initImGuiGlfwBackend();
#endif

  /// Move/resize the GLFW window (screen coordinates). If size changes,
  /// recreates swapchain + offscreen targets to match the framebuffer.
  /// No-op when not windowed.
  void setWindowFrame(int x, int y, int width, int height);

  void setWindowVisible(bool visible);

  /// If the framebuffer size drifted (e.g. after setWindowFrame), rebuild
  /// present/render targets. Returns true if a rebuild happened.
  bool ensureFramebufferSize();

  // Copies the last-rendered frame (RGBA8) into dst. dst must be at least
  // extent_.width * extent_.height * 4 bytes. Prefer `captureFrame` in windowed
  // mode — the present path does not always fill staging every frame.
  void readPixels(uint8_t *dst, size_t dstSize);

  /// Wait for GPU, copy resolve → staging, then `readPixels` into `dst`.
  /// Works in windowed and offscreen modes. `dst` size as for `readPixels`.
  /// Also refreshes the capture cache used by `capturePng`.
  void captureFrame(uint8_t *dst, size_t dstSize);

  /// Drop the host capture cache (call after presenting a new frame).
  void invalidateCaptureCache() { captureCacheValid_ = false; }

  /// Encode a (sub)region of the current resolve as PNG bytes.
  /// `x,y,w,h` in framebuffer pixels; `w` or `h` <= 0 means full frame.
  /// If `maxSide` > 0 and the longer side exceeds it, box-downsamples so
  /// max(outW, outH) <= maxSide (agent overview / token budget).
  /// Reuses the capture cache when still valid (cheap multi-crop).
  /// On success, `outW`/`outH` are the encoded pixel size (after downsample).
  /// Returns false on empty/invalid region or encode failure.
  bool capturePng(std::vector<uint8_t> &outPng, int x, int y, int w, int h,
                  int maxSide = 0, int *outW = nullptr, int *outH = nullptr);

  VkShaderModule createShaderModule(const std::vector<char> &code);

  vk::Buffer createImmutableVertexBuffer(
    const void *bufferData, VkDeviceSize bufferSize);

  vk::Buffer createImmutableIndexBuffer(
    const void *bufferData, VkDeviceSize bufferSize);

  vk::Buffer createImmutableUniformBuffer(
    const void *bufferData, VkDeviceSize bufferSize);

  VkSampler createTextureSampler();

  void createBuffer(VkDeviceSize          size,
                    VkBufferUsageFlags    usage,
                    VkMemoryPropertyFlags properties,
                    VkBuffer             &buffer,
                    VmaAllocation        &allocation);

  /// Destroy a buffer created with `createBuffer` (VMA-owned). Nulls both.
  void destroyBuffer(VkBuffer &buffer, VmaAllocation &allocation);

  /// Map/unmap host-visible buffers created with `createBuffer`.
  void *mapBuffer(VmaAllocation allocation);
  void  unmapBuffer(VmaAllocation allocation);

  void copyBuffer(VkBuffer srcBuffer, VkBuffer dstBuffer, VkDeviceSize size);

  std::tuple<VkBuffer, VmaAllocation> createUniformBuffer(
    VkDeviceSize bufferSize);

  VkCommandBuffer beginSingleTimeCommands();

  // It blocks until the command buffer finishes execution
  void endSingleTimeCommands(VkCommandBuffer commandBuffer);

  VkDevice                          getDevice() { return device_; }
  VmaAllocator                      getAllocator() { return allocator_; }
  VkCommandPool                     getCommandPool() { return commandPool_; }
  VkRenderPass                      getRenderPass() { return renderPass_; }
  VkRenderPass                      getShadowRenderPass() { return shadowRenderPass_; }
  VkFramebuffer                     getShadowFramebuffer() { return shadowFramebuffer_; }
  VkImageView                       getShadowImageView() { return shadowImageView_; }
  VkSampler                         getShadowSampler() { return shadowSampler_; }
  uint32_t                          getShadowMapSize() { return shadowMapSize_; }
  const VkExtent2D                 &getExtent() const { return extent_; }
  const VkPhysicalDeviceProperties &getDeviceProperties()
  {
    return physicalDeviceProperties_;
  }

  auto     getMSAASamples() const noexcept { return msaaSamples_; }
  Shaders &getShaders();


  void createImage(uint32_t              width,
                   uint32_t              height,
                   uint32_t              mipLevels,
                   VkSampleCountFlagBits samples,
                   VkFormat              format,
                   VkImageTiling         tiling,
                   VkImageUsageFlags     usage,
                   VkMemoryPropertyFlags properties,
                   VkImage              &image,
                   VmaAllocation        &allocation);

  /// Destroy an image created with `createImage` (VMA-owned). Nulls both.
  /// Does not destroy image views — caller frees views first.
  void destroyImage(VkImage &image, VmaAllocation &allocation);

  void transitionImageLayout(VkImage               image,
                             VkFormat              format,
                             VkImageLayout         oldLayout,
                             VkImageLayout         newLayout);

  void copyBufferToImage(VkBuffer buffer,
                         VkImage  image,
                         uint32_t width,
                         uint32_t height);

  /// Copies into a sub-rect, for packing many images into one atlas page.
  void copyBufferToImageRegion(VkBuffer buffer,
                               VkImage  image,
                               int32_t  dstX,
                               int32_t  dstY,
                               uint32_t width,
                               uint32_t height);

  VkImageView createImageView(VkImage            image,
                              VkFormat           format,
                              VkImageAspectFlags aspectFlags,
                              uint32_t           mipLevels);

  // Compute shader support
  VkDescriptorSetLayout createComputeDescriptorSetLayout();
  VkPipelineLayout createComputePipelineLayout(VkDescriptorSetLayout descriptorSetLayout);
  VkPipeline createComputePipeline(VkPipelineLayout pipelineLayout, const std::string& shaderPath);
  VkDescriptorPool createComputeDescriptorPool(uint32_t maxSets);
  VkDescriptorSet allocateComputeDescriptorSet(VkDescriptorPool pool, VkDescriptorSetLayout layout);
  void dispatchCompute(VkCommandBuffer commandBuffer, VkPipeline pipeline, VkPipelineLayout layout, VkDescriptorSet descriptorSet, uint32_t groupCountX, uint32_t groupCountY = 1, uint32_t groupCountZ = 1);
};
