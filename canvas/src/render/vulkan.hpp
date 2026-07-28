#pragma once

#include <iostream>
#include <stdexcept>
#include <vector>

#include <boost/stacktrace.hpp>

#include <vulkan/vulkan.h>
#include <vulkan/vulkan_core.h>

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

struct Buffer {
  vk::Handle<VkBuffer>       buffer;
  vk::Handle<VkDeviceMemory> memory;
  u32                        size;

  operator bool() const noexcept { return buffer.operator bool(); }

  void destroy(VkDevice device) {
    buffer.destroy(device);
    memory.destroy(device);
  }
};

};

class Vulkan
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
  VkSemaphore imageAvailableSemaphore_ = VK_NULL_HANDLE;
  VkSemaphore renderFinishedSemaphore_ = VK_NULL_HANDLE;

  // Offscreen render target (always used as the scene render target)
  VkFormat   colorFormat_;
  VkExtent2D extent_;

  VkPhysicalDeviceMemoryProperties deviceMemoryProperties_;
  VkRenderPass                     renderPass_ = VK_NULL_HANDLE;
  VkFramebuffer                    framebuffer_ = VK_NULL_HANDLE;
  VkCommandBuffer                  commandBuffer_ = VK_NULL_HANDLE;
  VkCommandPool                    commandPool_ = VK_NULL_HANDLE;
  VkFence                          inFlightFence_ = VK_NULL_HANDLE;

  // MSAA sampling stuff
  VkSampleCountFlagBits msaaSamples_ = VK_SAMPLE_COUNT_1_BIT;
  VkImage               colorImage_ = VK_NULL_HANDLE;
  VkDeviceMemory        colorImageMemory_ = VK_NULL_HANDLE;
  VkImageView           colorImageView_ = VK_NULL_HANDLE;

  // Single-sample resolve target: what the MSAA color attachment resolves
  // into, and what gets copied out for readback. Not the same image as
  // colorImage_ above (that one is TRANSIENT_ATTACHMENT_BIT and MSAA-only).
  VkImage        resolveImage_ = VK_NULL_HANDLE;
  VkDeviceMemory resolveImageMemory_ = VK_NULL_HANDLE;
  VkImageView    resolveImageView_ = VK_NULL_HANDLE;

  // Host-visible staging buffer that resolveImage_ gets copied into every
  // frame, for CPU readback via readPixels().
  VkBuffer       stagingBuffer_ = VK_NULL_HANDLE;
  VkDeviceMemory stagingBufferMemory_ = VK_NULL_HANDLE;
  void          *stagingBufferMapped_ = nullptr;
  VkDeviceSize   stagingBufferSize_ = 0;

  // Depth buffer stuff
  VkImage        depthImage_ = VK_NULL_HANDLE;
  VkDeviceMemory depthImageMemory_ = VK_NULL_HANDLE;
  VkImageView    depthImageView_ = VK_NULL_HANDLE;

  // Shadow mapping stuff
  VkImage        shadowImage_ = VK_NULL_HANDLE;
  VkDeviceMemory shadowImageMemory_ = VK_NULL_HANDLE;
  VkImageView    shadowImageView_ = VK_NULL_HANDLE;
  VkSampler      shadowSampler_ = VK_NULL_HANDLE;
  VkRenderPass   shadowRenderPass_ = VK_NULL_HANDLE;
  VkFramebuffer  shadowFramebuffer_ = VK_NULL_HANDLE;
  uint32_t       shadowMapSize_ = 2048; // Shadow map resolution

  // ImGui
  VkDescriptorPool imguiDescriptorPool_ = VK_NULL_HANDLE;
  bool             imguiInitialized_ = false;

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
  void createSyncObjects();

  void beginMainRenderPass(VkCommandBuffer commandBuffer, u32 imageIndex);

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
  void createRenderPass();
  void createFramebuffer();
  void createCommandPool();
  void createDescriptorPool();
  void createDescriptorSet();
  void createCommandBuffer();
  void initImGui();

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

  void renderWithShadows(
    std::function<void(VkCommandBuffer)> shadowCallback,
    std::function<void(VkCommandBuffer, u32)> mainCallback);
  void cleanUp();

  bool isWindowed() const { return windowed_; }
  GLFWwindow *window() const { return window_; }
  bool windowShouldClose() const;

  /// Call after installing app-level GLFW callbacks so ImGui can chain.
  void initImGuiGlfwBackend();

  /// Move/resize the GLFW window (screen coordinates). If size changes,
  /// recreates swapchain + offscreen targets to match the framebuffer.
  /// No-op when not windowed.
  void setWindowFrame(int x, int y, int width, int height);

  void setWindowVisible(bool visible);

  /// If the framebuffer size drifted (e.g. after setWindowFrame), rebuild
  /// present/render targets. Returns true if a rebuild happened.
  bool ensureFramebufferSize();

  // Copies the last-rendered frame (RGBA8) into dst. dst must be at least
  // extent_.width * extent_.height * 4 bytes. Only valid after a repaint in
  // offscreen mode (windowed mode skips the staging copy).
  void readPixels(uint8_t *dst, size_t dstSize);

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
                    VkDeviceMemory       &bufferMemory);

  void copyBuffer(VkBuffer srcBuffer, VkBuffer dstBuffer, VkDeviceSize size);

  std::tuple<VkBuffer, VkDeviceMemory> createUniformBuffer(
    VkDeviceSize bufferSize);

  VkCommandBuffer beginSingleTimeCommands();

  // It blocks until the command buffer finishes execution
  void endSingleTimeCommands(VkCommandBuffer commandBuffer);

  VkDevice                          getDevice() { return device_; }
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
                   VkDeviceMemory       &imageMemory);

  void transitionImageLayout(VkImage               image,
                             VkFormat              format,
                             VkImageLayout         oldLayout,
                             VkImageLayout         newLayout);

  void copyBufferToImage(VkBuffer buffer,
                         VkImage  image,
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
