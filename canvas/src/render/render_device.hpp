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

class RenderWindow;

/// The GPU, and everything on it that outlives any one window.
///
/// Instance, physical and logical device, allocator, queue, command pool,
/// render passes, and the buffer/image helpers every renderer calls. Windows
/// attach to it (`RenderWindow`) and share all of it: the glyph atlas, the
/// texture manager and the pipeline set are created once no matter how many
/// surfaces are open. That sharing is the point — a second window should cost
/// its attachments, not a second copy of every font it draws.
///
/// The device is created before any window exists. Picking a physical device
/// needs a surface to test present support against, so `init(presentCapable)`
/// makes a throwaway hidden window, probes it, and destroys it. Without that,
/// device creation is chained to the first window's lifetime and the second
/// window has to hope the queue family it inherited happens to fit.
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

  /// Whether the device was brought up able to present. Drives the instance
  /// and device extension sets, and whether a queue family has to prove it can
  /// present before being chosen.
  bool presentCapable_ = false;
  /// Live only during `init`: the throwaway surface present support is tested
  /// against, since no real window exists yet. See `init`.
  VkSurfaceKHR probeSurface_ = VK_NULL_HANDLE;

  /// Every open window, so device-wide questions ("is anything still using
  /// this?", "wait for all GPU work") can be answered without a window having
  /// to volunteer itself. Windows register in their constructor.
  std::vector<RenderWindow *> windows_;

  /// Monotonically increasing, one per queue submission across all windows.
  /// This is the clock deferred destruction is measured on — a frame counter
  /// cannot be, because with two windows "three frames have passed" says
  /// nothing about whether the *other* window's frame has retired.
  uint64_t nextSubmission_ = 1;

  /// GPU resources waiting for every submission that might reference them.
  struct PendingDestroy {
    VkImage       image      = VK_NULL_HANDLE;
    VmaAllocation allocation = VK_NULL_HANDLE;
    VkImageView   view       = VK_NULL_HANDLE;
    /// Submission index at the moment of the request. Anything submitted at
    /// or after this point was recorded after the handle was nulled, so it
    /// cannot name the resource.
    uint64_t      queuedAt   = 0;
  };
  std::vector<PendingDestroy> trash_;

  /// Format every window renders into. Fixed, and deliberately not the
  /// swapchain's: the swapchain is a blit destination, so surfaces disagreeing
  /// about their preferred format costs a blit, not a second render pass.
  VkFormat colorFormat_ = VK_FORMAT_R8G8B8A8_SRGB;

  VkPhysicalDeviceMemoryProperties deviceMemoryProperties_;
  VkRenderPass                     renderPass_ = VK_NULL_HANDLE;
  /// Same attachments as renderPass_ but LOAD (continue after backdrop blur).
  VkRenderPass                     renderPassContinue_ = VK_NULL_HANDLE;
  VkCommandPool                    commandPool_ = VK_NULL_HANDLE;

  /// Sample count every render pass and pipeline is built for. Device-wide,
  /// so every window's attachments must agree with it.
  VkSampleCountFlagBits msaaSamples_ = VK_SAMPLE_COUNT_1_BIT;

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

  uint32_t findMemoryProperties(uint32_t              memoryTypeBitsRequirement,
                                VkMemoryPropertyFlags requiredProperties);

  vk::Buffer createImmutableBuffer(
    const void           *bufferData,
    VkDeviceSize          bufferSize,
    VkBufferUsageFlagBits usageFlagBits);

  VkFormat findSupportedFormat(const std::vector<VkFormat>& candidates, VkImageTiling tiling, VkFormatFeatureFlags features);
  bool hasStencilComponent(VkFormat format);

  // Shadow mapping stuff
  void createShadowResources();
  void createShadowRenderPass();
  void createShadowFramebuffer();

  // Step 3: Create render pass, command pool
  /// Clear pass (first UI segment) + continue pass (LOAD after blur).
  void createRenderPass();
  void createCommandPool();
  void createDescriptorPool();
  void createDescriptorSet();
#ifdef INCLUDE_IMGUI
  void initImGui();
#endif

 public:
  /// Creates instance, picks a GPU, and brings up the device and everything
  /// shared between windows.
  ///
  /// `presentCapable` enables the surface/swapchain extensions and picks a
  /// queue family that can present — checked against a throwaway hidden GLFW
  /// window, since present support is a property of a (device, family,
  /// surface) triple and there is no real surface yet. Pass false for headless
  /// use (smoke tests, offscreen render).
  void init(const char *applicationName, bool presentCapable);

  VkFormat colorFormat() const { return colorFormat_; }

  // ─── Windows ─────────────────────────────────────────────────────────────

  /// Called by `RenderWindow`'s constructor/destructor. Not for general use —
  /// the device only needs the list to answer questions that span windows.
  void registerWindow(RenderWindow *window);
  void unregisterWindow(RenderWindow *window);

  /// Reserves the next submission index. Called by `RenderWindow::render`
  /// immediately before `vkQueueSubmit`.
  uint64_t nextSubmission() { return nextSubmission_++; }

  /// Block until *every* window has finished every frame it has in flight.
  /// This is the one to call before destroying or replacing anything shared —
  /// growing the glyph atlas, recreating a buffer every window samples. A
  /// single window's `waitForAllFrames()` is not enough: the other window's
  /// command buffer names the same atlas.
  void waitForAllFramesInFlight();

  /// Destroys an image once no submission that might reference it is still
  /// running.
  ///
  /// The immediate `destroyImage` is only safe for something the GPU has
  /// provably finished with. Anything that was drawn recently — a texture the
  /// app just stopped using, an atlas page being retired — may still be
  /// referenced by a command buffer that has been submitted and not yet
  /// completed, and freeing it there is a use-after-free the validation layer
  /// reports as a crash somewhere else entirely.
  ///
  /// Queued here instead and released by `collectGarbage()`. Handles are
  /// nulled so the caller cannot use them again.
  void destroyImageDeferred(VkImage &image, VmaAllocation &allocation,
                            VkImageView &view);

  /// Releases anything queued by `destroyImageDeferred` whose submission has
  /// retired *in every window*. Called once per presented frame.
  void collectGarbage();

  void cleanUp();

#ifdef INCLUDE_IMGUI
  bool imguiInitialized() const { return imguiInitialized_; }
#endif

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
  VkInstance                        instance() const { return instance_; }
  VkPhysicalDevice                  physicalDevice() const { return physicalDevice_; }
  VkQueue                           graphicsQueue() const { return graphicsQueue_; }
  uint32_t graphicsQueueFamily() const
  {
    return graphicsAndPresentationQueueFamilyIdx_;
  }
  bool fifoLatestReadyEnabled() const { return fifoLatestReadyEnabled_; }

  VmaAllocator                      getAllocator() { return allocator_; }
  VkCommandPool                     getCommandPool() { return commandPool_; }
  VkRenderPass                      getRenderPass() { return renderPass_; }
  VkRenderPass                      renderPassContinue() const { return renderPassContinue_; }
  VkRenderPass                      getShadowRenderPass() { return shadowRenderPass_; }
  VkFramebuffer                     getShadowFramebuffer() { return shadowFramebuffer_; }
  VkImageView                       getShadowImageView() { return shadowImageView_; }
  VkSampler                         getShadowSampler() { return shadowSampler_; }
  uint32_t                          getShadowMapSize() { return shadowMapSize_; }
  const VkPhysicalDeviceProperties &getDeviceProperties()
  {
    return physicalDeviceProperties_;
  }

  auto     getMSAASamples() const noexcept { return msaaSamples_; }
  Shaders &getShaders();

  /// Depth format the render passes were built with. Windows need it to make
  /// a matching attachment.
  VkFormat findDepthFormat();

  /// Records the shadow pass into `commandBuffer`. Device-scope because the
  /// shadow map is one 2048² image shared by every window.
  void beginShadowPass(VkCommandBuffer commandBuffer);


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
