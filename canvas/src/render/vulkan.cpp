#include <set>
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>
#include <algorithm>
#include <filesystem>

#define BOOST_STACKTRACE_DYN_LINK
#define BOOST_STACKTRACE_USE_BACKTRACE
#include <boost/stacktrace.hpp>
#include <boost/stacktrace/stacktrace.hpp>

#include <vulkan/vulkan_core.h>

#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>

#ifdef INCLUDE_IMGUI
# include "imgui_impl_vulkan.h"
# include "imgui_impl_glfw.h"
#endif

#include "util/util.hpp"
#include "render/shaders.hpp"
#include "render/vulkan.hpp"
#include "render/texture_manager.hpp"
#include "window/window_platform.hpp"

#define DEBUG_PRINT 0

bool g_ValidationFromResult = false;

// Filled before createLogicalDevice: empty for offscreen, swapchain for windowed.
std::vector<const char *> deviceExtensions = {};

VKAPI_ATTR VkBool32 VKAPI_CALL Vulkan::debugCallback(
  VkDebugUtilsMessageSeverityFlagBitsEXT      messageSeverity,
  VkDebugUtilsMessageTypeFlagsEXT             messageType,
  const VkDebugUtilsMessengerCallbackDataEXT *pCallbackData,
  void                                       *pUserData)
{
  bool *pFromResult = reinterpret_cast<bool *>(pUserData);
  if (!(*pFromResult))
    std::cerr << clr::magenta;

  std::cerr << "Vulkan Validation Layer:\n\t"
    << pCallbackData->pMessage << std::endl;

  if (!(*pFromResult))
    std::cerr << clr::reset;

  // *pFromResult = false;
  return VK_FALSE;
}

VkResult Vulkan::createDebugUtilsMessengerEXT(
  VkInstance                                instance,
  const VkDebugUtilsMessengerCreateInfoEXT *pCreateInfo,
  const VkAllocationCallbacks              *pAllocator,
  VkDebugUtilsMessengerEXT                 *pDebugMessenger)
{
  auto func = (PFN_vkCreateDebugUtilsMessengerEXT)vkGetInstanceProcAddr(
    instance, "vkCreateDebugUtilsMessengerEXT");
  if (func != nullptr) {
    return func(instance, pCreateInfo, pAllocator, pDebugMessenger);
  } else {
    return VK_ERROR_EXTENSION_NOT_PRESENT;
  }
}

void Vulkan::destroyDebugUtilsMessengerEXT(
  VkInstance                   instance,
  VkDebugUtilsMessengerEXT     debugMessenger,
  const VkAllocationCallbacks *pAllocator)
{
  auto func = (PFN_vkDestroyDebugUtilsMessengerEXT)vkGetInstanceProcAddr(
    instance, "vkDestroyDebugUtilsMessengerEXT");
  if (func != nullptr) {
    func(instance, debugMessenger, pAllocator);
  }
}

VkDebugUtilsMessengerCreateInfoEXT Vulkan::createDebugMessengerInfo()
{
  return VkDebugUtilsMessengerCreateInfoEXT {
    .sType           = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
    .messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
                       VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                       VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
    .messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                   VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                   VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
    .pfnUserCallback = debugCallback,
    .pUserData   = &g_ValidationFromResult,
  };
}

void Vulkan::setupDebugMessenger()
{
  if (!enableValidationLayers_) return;

  auto createInfo = createDebugMessengerInfo();
  VR(createDebugUtilsMessengerEXT(
       instance_, &createInfo, nullptr, &debugMessenger_),
     "failed to set up debug messenger!");
}

bool Vulkan::checkValidationLayerSupport(
  const std::vector<const char *> &validationLayers)
{
  uint32_t layerCount;
  vkEnumerateInstanceLayerProperties(&layerCount, nullptr);

  std::vector<VkLayerProperties> availableLayers(layerCount);
  vkEnumerateInstanceLayerProperties(&layerCount, availableLayers.data());

  for (const char *layerName : validationLayers) {
    bool layerFound = false;

    for (const auto &layerProperties : availableLayers) {
      if (strcmp(layerName, layerProperties.layerName) == 0) {
        layerFound = true;
        break;
      }
    }

    if (!layerFound) return false;
  }

  return true;
}

void Vulkan::createVkInstance(
  const char *applicationName)
{
  const std::vector<const char *> validationLayers = {
    "VK_LAYER_KHRONOS_validation"};

  if (enableValidationLayers_ &&
      !checkValidationLayerSupport(validationLayers)) {
    throw std::runtime_error("validation layers requested, but not available!");
  }

  VkApplicationInfo appInfo {
    .sType              = VK_STRUCTURE_TYPE_APPLICATION_INFO,
    .pApplicationName   = applicationName,
    .applicationVersion = VK_MAKE_VERSION(1, 0, 0),
    .pEngineName        = "No Engine",
    .engineVersion      = VK_MAKE_VERSION(1, 0, 0),
    .apiVersion         = VK_API_VERSION_1_0,
  };

  VkInstanceCreateInfo createInfo {
    .sType            = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
    .pApplicationInfo = &appInfo,
  };

  auto instanceExtensions = std::vector<const char *>();

  if (windowed_) {
    uint32_t glfwExtCount = 0;
    const char **glfwExts = glfwGetRequiredInstanceExtensions(&glfwExtCount);
    if (!glfwExts || glfwExtCount == 0) {
      throw std::runtime_error("glfwGetRequiredInstanceExtensions failed");
    }
    for (uint32_t i = 0; i < glfwExtCount; ++i) {
      instanceExtensions.push_back(glfwExts[i]);
    }
  }

  if (enableValidationLayers_)
    instanceExtensions.push_back(VK_EXT_DEBUG_UTILS_EXTENSION_NAME);

  if (!checkExtensionsSupport(instanceExtensions))
    throw std::runtime_error(
      "VkInstance does not support required extensions!");

  createInfo.enabledExtensionCount =
    static_cast<u32>(instanceExtensions.size());
  createInfo.ppEnabledExtensionNames = instanceExtensions.data();

  VkDebugUtilsMessengerCreateInfoEXT debugCreateInfo;
  if (enableValidationLayers_) {
    debugCreateInfo = createDebugMessengerInfo();
    createInfo.enabledLayerCount   = static_cast<u32>(validationLayers.size());
    createInfo.ppEnabledLayerNames = validationLayers.data();
    createInfo.pNext               = &debugCreateInfo;
  }

  // Finally, create the instance
  VR(vkCreateInstance(&createInfo, nullptr, &instance_),
     "failed to create instance!");
}

bool Vulkan::checkExtensionsSupport(
  const std::vector<const char *> &requiredExtensions)
{
  u32 extensionCount = 0;
  vkEnumerateInstanceExtensionProperties(nullptr, &extensionCount, nullptr);

  std::vector<VkExtensionProperties> extensions(extensionCount);
  vkEnumerateInstanceExtensionProperties(
    nullptr, &extensionCount, extensions.data());
#if DEBUG_PRINT
  for (u32 i = 0; i < extensionCount; ++i) {
    std::cout << extensions[i].extensionName << ' ' << extensions[i].specVersion
              << '\n';
  }
#endif

  for (const auto checkExtension : requiredExtensions) {
    if (std::find_if(extensions.begin(),
                     extensions.end(),
                     [checkExtension](const auto &ext) {
                       return strcmp(checkExtension, ext.extensionName) == 0;
                     }) == extensions.end())
      return false;
  }
  return true;
}

void Vulkan::selectSupportedGraphicsCard()
{
  uint32_t deviceCount = 0;
  vkEnumeratePhysicalDevices(instance_, &deviceCount, nullptr);

  if (deviceCount == 0) {
    throw std::runtime_error("failed to find GPUs with Vulkan support!");
  }

  std::vector<VkPhysicalDevice> devices(deviceCount);
  vkEnumeratePhysicalDevices(instance_, &deviceCount, devices.data());

  auto isDeviceSuitable = [](VkPhysicalDevice device) {
    auto checkDeviceExtensionSupport = [device]() {
      uint32_t extensionCount;
      vkEnumerateDeviceExtensionProperties(
        device, nullptr, &extensionCount, nullptr);

      std::vector<VkExtensionProperties> availableExtensions(extensionCount);
      vkEnumerateDeviceExtensionProperties(
        device, nullptr, &extensionCount, availableExtensions.data());

      std::set<std::string> requiredExtensions(deviceExtensions.begin(),
                                               deviceExtensions.end());
      for (const auto &extension : availableExtensions) {
        requiredExtensions.erase(extension.extensionName);
      }

      return requiredExtensions.empty();
    };

    VkPhysicalDeviceProperties deviceProperties;
    vkGetPhysicalDeviceProperties(device, &deviceProperties);

    std::cout << std::format("Limits:\n\tmaxPushConstantsSize: {}\n",
                deviceProperties.limits.maxPushConstantsSize);

    VkPhysicalDeviceFeatures deviceFeatures;
    vkGetPhysicalDeviceFeatures(device, &deviceFeatures);

    return deviceProperties.deviceType ==
             VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU &&
           deviceFeatures.geometryShader && checkDeviceExtensionSupport();
  };

  auto getMaxUsableSampleCount =
    [](const VkPhysicalDeviceProperties &physicalDeviceProperties)
    -> VkSampleCountFlagBits {
    VkSampleCountFlags counts =
      physicalDeviceProperties.limits.framebufferColorSampleCounts &
      physicalDeviceProperties.limits.framebufferDepthSampleCounts;
    if (counts & VK_SAMPLE_COUNT_64_BIT) return VK_SAMPLE_COUNT_64_BIT;
    if (counts & VK_SAMPLE_COUNT_32_BIT) return VK_SAMPLE_COUNT_32_BIT;
    if (counts & VK_SAMPLE_COUNT_16_BIT) return VK_SAMPLE_COUNT_16_BIT;
    if (counts & VK_SAMPLE_COUNT_8_BIT) return VK_SAMPLE_COUNT_8_BIT;
    if (counts & VK_SAMPLE_COUNT_4_BIT) return VK_SAMPLE_COUNT_4_BIT;
    if (counts & VK_SAMPLE_COUNT_2_BIT) return VK_SAMPLE_COUNT_2_BIT;

    return VK_SAMPLE_COUNT_1_BIT;
  };

  if (auto found = std::ranges::find_if(devices, isDeviceSuitable);
      found != devices.end()) {
    physicalDevice_ = *found;
    vkGetPhysicalDeviceProperties(physicalDevice_, &physicalDeviceProperties_);
    msaaSamples_ = getMaxUsableSampleCount(physicalDeviceProperties_);
#if DEBUG_PRINT
    std::cout << physicalDeviceProperties_.deviceName
              << "\n\t MSAA Samples: " << msaaSamples_ << std::endl;
#endif
  } else {
    throw std::runtime_error("No suitable physical device found!");
  }

  vkGetPhysicalDeviceMemoryProperties(physicalDevice_,
                                      &deviceMemoryProperties_);
}

void Vulkan::createLogicalDevice()
{
  uint32_t count = 0;
  vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice_, &count, nullptr);

  std::vector<VkQueueFamilyProperties> properties(count);
  vkGetPhysicalDeviceQueueFamilyProperties(
    physicalDevice_, &count, properties.data());

  // Prefer a queue family that can do both graphics and present.
  graphicsAndPresentationQueueFamilyIdx_ = std::numeric_limits<u32>::max();

  for (uint32_t i = 0; i < count; i++) {
    if ((properties[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) == 0) continue;
    if (windowed_ && surface_ != VK_NULL_HANDLE) {
      VkBool32 presentSupport = VK_FALSE;
      vkGetPhysicalDeviceSurfaceSupportKHR(
        physicalDevice_, i, surface_, &presentSupport);
      if (!presentSupport) continue;
    }
    graphicsAndPresentationQueueFamilyIdx_ = i;
    break;
  }

  if (graphicsAndPresentationQueueFamilyIdx_ == std::numeric_limits<u32>::max()) {
    throw std::runtime_error("No suitable queue was found");
  }

  std::vector<float>      queuePriorities = {1.0f};
  VkDeviceQueueCreateInfo queueCreateInfo {
    .sType            = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
    .queueFamilyIndex = graphicsAndPresentationQueueFamilyIdx_,
    .queueCount       = static_cast<u32>(queuePriorities.size()),
    .pQueuePriorities = queuePriorities.data(),
  };

  VkPhysicalDeviceFeatures deviceFeatures {};

  // Optional, windowed only: VK_PRESENT_MODE_FIFO_LATEST_READY is MAILBOX's
  // behaviour — present the most recently finished image at the next refresh
  // and discard the ones it overtook — so it is non-tearing without letting
  // latency build up behind a queue. On surfaces that offer it but not MAILBOX
  // (this machine is one) it is the mode we actually want.
  //
  // Requested here rather than in the suitability check on purpose: adding it
  // to `deviceExtensions` up front would make a GPU that lacks it fail to
  // qualify as a device at all.
  if (windowed_) {
    uint32_t extCount = 0;
    vkEnumerateDeviceExtensionProperties(physicalDevice_, nullptr, &extCount, nullptr);
    std::vector<VkExtensionProperties> available(extCount);
    vkEnumerateDeviceExtensionProperties(
      physicalDevice_, nullptr, &extCount, available.data());
    for (const auto &ext : available) {
      if (std::strcmp(ext.extensionName,
                      VK_KHR_PRESENT_MODE_FIFO_LATEST_READY_EXTENSION_NAME) == 0) {
        fifoLatestReadyEnabled_ = true;
        deviceExtensions.push_back(
          VK_KHR_PRESENT_MODE_FIFO_LATEST_READY_EXTENSION_NAME);
        break;
      }
    }
  }

  // Must outlive vkCreateDevice: it is referenced through pNext.
  VkPhysicalDevicePresentModeFifoLatestReadyFeaturesKHR fifoLatestReady {
    .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_MODE_FIFO_LATEST_READY_FEATURES_KHR,
    .pNext = nullptr,
    .presentModeFifoLatestReady = VK_TRUE,
  };

  VkDeviceCreateInfo deviceCreateInfo = {
    .sType                   = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
    .pNext                   = fifoLatestReadyEnabled_ ? &fifoLatestReady : nullptr,
    .queueCreateInfoCount    = 1,
    .pQueueCreateInfos       = &queueCreateInfo,
    .enabledExtensionCount   = static_cast<uint32_t>(deviceExtensions.size()),
    .ppEnabledExtensionNames = deviceExtensions.data(),
    .pEnabledFeatures        = &deviceFeatures,
  };

  VR(vkCreateDevice(physicalDevice_, &deviceCreateInfo, nullptr, &device_),
     "failed to create logical device!");

  vkGetDeviceQueue(
    device_, graphicsAndPresentationQueueFamilyIdx_, 0, &graphicsQueue_);

  createAllocator();
}

void Vulkan::createAllocator()
{
  VmaAllocatorCreateInfo info{};
  info.flags = 0;
  info.physicalDevice = physicalDevice_;
  info.device = device_;
  info.instance = instance_;
  // Match the instance apiVersion (1.0). VMA still works; newer features stay off.
  info.vulkanApiVersion = VK_API_VERSION_1_0;
  VR(vmaCreateAllocator(&info, &allocator_), "failed to create VMA allocator");
}

void Vulkan::destroyAllocator()
{
  if (allocator_ == VK_NULL_HANDLE) return;
  // Callers must destroy every buffer/image first; VMA will assert in debug
  // if anything is still allocated when the allocator is destroyed.
  vmaDestroyAllocator(allocator_);
  allocator_ = VK_NULL_HANDLE;
}

// Find a memory in `memoryTypeBitsRequirement` that includes all of
// `requiredProperties`
uint32_t Vulkan::findMemoryProperties(

  uint32_t memoryTypeBitsRequirement, VkMemoryPropertyFlags requiredProperties)
{
  const uint32_t memoryCount = deviceMemoryProperties_.memoryTypeCount;
  for (uint32_t memoryIndex = 0; memoryIndex < memoryCount; ++memoryIndex) {
    const uint32_t memoryTypeBits = (1 << memoryIndex);
    const bool     isRequiredMemoryType =
      memoryTypeBitsRequirement & memoryTypeBits;

    const VkMemoryPropertyFlags properties =
      deviceMemoryProperties_.memoryTypes[memoryIndex].propertyFlags;
    const bool hasRequiredProperties =
      (properties & requiredProperties) == requiredProperties;

    if (isRequiredMemoryType && hasRequiredProperties) return memoryIndex;
  }

  throw std::runtime_error("failed to find memory type!");
}

void Vulkan::createBuffer(
  VkDeviceSize          size,
  VkBufferUsageFlags    usage,
  VkMemoryPropertyFlags properties,
  VkBuffer             &buffer,
  VmaAllocation        &allocation)
{
  assert(allocator_ != VK_NULL_HANDLE);

  VkBufferCreateInfo bufferInfo {
    .sType       = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
    .size        = size,
    .usage       = usage,
    .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
  };

  VmaAllocationCreateInfo allocInfo{};
  // Prefer DEVICE_LOCAL when requested; HOST_VISIBLE for staging / UI VB.
  if ((properties & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) &&
      !(properties & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) {
    allocInfo.usage = VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE;
    allocInfo.requiredFlags = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
  } else if (properties & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) {
    allocInfo.usage = VMA_MEMORY_USAGE_AUTO_PREFER_HOST;
    allocInfo.requiredFlags = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;
    if (properties & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) {
      allocInfo.requiredFlags |= VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    }
    // RANDOM covers both CPU→GPU staging uploads and GPU→CPU readback
    // (stagingBuffer_ for readPixels). MAPPED keeps a persistent host pointer.
    allocInfo.flags = VMA_ALLOCATION_CREATE_HOST_ACCESS_RANDOM_BIT |
                      VMA_ALLOCATION_CREATE_MAPPED_BIT;
  } else {
    allocInfo.usage = VMA_MEMORY_USAGE_AUTO;
    allocInfo.requiredFlags = properties;
  }

  allocation = VK_NULL_HANDLE;
  VR(vmaCreateBuffer(allocator_, &bufferInfo, &allocInfo, &buffer, &allocation,
                     nullptr),
     "failed to create buffer (VMA)!");
}

void Vulkan::destroyBuffer(VkBuffer &buffer, VmaAllocation &allocation)
{
  if (buffer == VK_NULL_HANDLE) {
    allocation = VK_NULL_HANDLE;
    return;
  }
  assert(allocation != VK_NULL_HANDLE);
  vmaDestroyBuffer(allocator_, buffer, allocation);
  buffer = VK_NULL_HANDLE;
  allocation = VK_NULL_HANDLE;
}

void *Vulkan::mapBuffer(VmaAllocation allocation)
{
  assert(allocation != VK_NULL_HANDLE);
  void *ptr = nullptr;
  VR(vmaMapMemory(allocator_, allocation, &ptr), "vmaMapMemory failed");
  return ptr;
}

void Vulkan::unmapBuffer(VmaAllocation allocation)
{
  if (allocation == VK_NULL_HANDLE) return;
  vmaUnmapMemory(allocator_, allocation);
}

vk::Buffer Vulkan::createImmutableBuffer(
  const void           *bufferData,
  VkDeviceSize          bufferSize,
  VkBufferUsageFlagBits usageFlagBits)
{
  VkBuffer      vertexBuffer = VK_NULL_HANDLE;
  VmaAllocation vertexAlloc  = VK_NULL_HANDLE;
  VkBuffer      stagingBuffer = VK_NULL_HANDLE;
  VmaAllocation stagingAlloc  = VK_NULL_HANDLE;
  createBuffer(
    bufferSize,
    VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    stagingBuffer,
    stagingAlloc);

  void *data = mapBuffer(stagingAlloc);
  memcpy(data, bufferData, (size_t)bufferSize);
  unmapBuffer(stagingAlloc);

  createBuffer(bufferSize,
               VK_BUFFER_USAGE_TRANSFER_DST_BIT | usageFlagBits,
               VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
               vertexBuffer,
               vertexAlloc);

  copyBuffer(stagingBuffer, vertexBuffer, bufferSize);

  destroyBuffer(stagingBuffer, stagingAlloc);

  return vk::Buffer{vertexBuffer, vertexAlloc, static_cast<u32>(bufferSize)};
}

vk::Buffer Vulkan::createImmutableVertexBuffer(
  const void *bufferData, VkDeviceSize bufferSize)
{
  return createImmutableBuffer(
    bufferData, bufferSize, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
}

vk::Buffer Vulkan::createImmutableIndexBuffer(
  const void *bufferData, VkDeviceSize bufferSize)
{
  return createImmutableBuffer(
    bufferData, bufferSize, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
}

vk::Buffer Vulkan::createImmutableUniformBuffer(
  const void *bufferData, VkDeviceSize bufferSize)
{
  return createImmutableBuffer(
    bufferData, bufferSize, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
}

void Vulkan::copyBuffer(
  VkBuffer srcBuffer, VkBuffer dstBuffer, VkDeviceSize size)
{
  VkCommandBuffer commandBuffer = beginSingleTimeCommands();

  VkBufferCopy copyRegion {
    .srcOffset = 0,
    .dstOffset = 0,
    .size      = size,
  };
  vkCmdCopyBuffer(commandBuffer, srcBuffer, dstBuffer, 1, &copyRegion);

  endSingleTimeCommands(commandBuffer);
}

std::tuple<VkBuffer, VmaAllocation> Vulkan::createUniformBuffer(
  VkDeviceSize bufferSize)
{
  VkBuffer      uniformBuffer = VK_NULL_HANDLE;
  VmaAllocation uniformAlloc  = VK_NULL_HANDLE;

  createBuffer(
    bufferSize,
    VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    uniformBuffer,
    uniformAlloc);

  return std::make_tuple(uniformBuffer, uniformAlloc);
}

void Vulkan::createImage(
  uint32_t              width,
  uint32_t              height,
  uint32_t              mipLevels,
  VkSampleCountFlagBits samples,
  VkFormat              format,
  VkImageTiling         tiling,
  VkImageUsageFlags     usage,
  VkMemoryPropertyFlags properties,
  VkImage              &image,
  VmaAllocation        &allocation)
{
  assert(mipLevels > 0);
  assert(allocator_ != VK_NULL_HANDLE);

  VkImageCreateInfo imageInfo {
    .sType     = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
    .imageType = VK_IMAGE_TYPE_2D,
    .format    = format,
    .extent {
      .width  = width,
      .height = height,
      .depth  = 1,
    },
    .mipLevels     = mipLevels,
    .arrayLayers   = 1,
    .samples       = samples,
    .tiling        = tiling,
    .usage         = usage,
    .sharingMode   = VK_SHARING_MODE_EXCLUSIVE,
    .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
  };

  VmaAllocationCreateInfo allocInfo{};
  if ((properties & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) &&
      !(properties & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) {
    allocInfo.usage = VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE;
    allocInfo.requiredFlags = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
  } else if (properties & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) {
    allocInfo.usage = VMA_MEMORY_USAGE_AUTO_PREFER_HOST;
    allocInfo.requiredFlags = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;
    if (properties & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) {
      allocInfo.requiredFlags |= VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    }
    allocInfo.flags = VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT |
                      VMA_ALLOCATION_CREATE_MAPPED_BIT;
  } else {
    allocInfo.usage = VMA_MEMORY_USAGE_AUTO;
    allocInfo.requiredFlags = properties;
  }

  // Transient MSAA attachments: prefer lazily-allocated memory when available.
  if (usage & VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT) {
    allocInfo.preferredFlags = VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT;
  }

  allocation = VK_NULL_HANDLE;
  VR(vmaCreateImage(allocator_, &imageInfo, &allocInfo, &image, &allocation,
                    nullptr),
     "failed to create image (VMA)!");
}

void Vulkan::destroyImageDeferred(VkImage &image, VmaAllocation &allocation,
                                  VkImageView &view)
{
  if (image == VK_NULL_HANDLE && view == VK_NULL_HANDLE) return;
  // +1 because the frame currently being recorded has not been counted yet:
  // it can still name this image, so it has to retire too.
  trash_.push_back({image, allocation, view,
                    frameCounter_ + kMaxFramesInFlight + 1});
  image      = VK_NULL_HANDLE;
  allocation = VK_NULL_HANDLE;
  view       = VK_NULL_HANDLE;
}

void Vulkan::collectGarbage()
{
  if (trash_.empty()) return;
  size_t keep = 0;
  for (size_t i = 0; i < trash_.size(); ++i) {
    auto &t = trash_[i];
    if (frameCounter_ < t.retireAt) {
      trash_[keep++] = t;
      continue;
    }
    if (t.view != VK_NULL_HANDLE) {
      vkDestroyImageView(device_, t.view, nullptr);
    }
    if (t.image != VK_NULL_HANDLE) {
      vmaDestroyImage(allocator_, t.image, t.allocation);
    }
  }
  trash_.resize(keep);
}

void Vulkan::destroyImage(VkImage &image, VmaAllocation &allocation)
{
  if (image == VK_NULL_HANDLE) {
    allocation = VK_NULL_HANDLE;
    return;
  }
  assert(allocation != VK_NULL_HANDLE);
  vmaDestroyImage(allocator_, image, allocation);
  image = VK_NULL_HANDLE;
  allocation = VK_NULL_HANDLE;
}

VkImageView Vulkan::createImageView(
  VkImage            image,
  VkFormat           format,
  VkImageAspectFlags aspectFlags,
  uint32_t           mipLevels)
{
  VkImageViewCreateInfo viewInfo {
    .sType    = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
    .image    = image,
    .viewType = VK_IMAGE_VIEW_TYPE_2D,
    .format   = format,
    .subresourceRange =
      {
        .aspectMask     = aspectFlags,
        .baseMipLevel   = 0,
        .levelCount     = mipLevels,
        .baseArrayLayer = 0,
        .layerCount     = 1,
      },
  };

  VkImageView imageView;
  VR(vkCreateImageView(device_, &viewInfo, nullptr, &imageView),
     "failed to create texture image view!")

  return imageView;
}

VkSampler Vulkan::createTextureSampler()
{
  VkSamplerCreateInfo samplerInfo {
    .sType                   = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
    .magFilter               = VK_FILTER_LINEAR,
    .minFilter               = VK_FILTER_LINEAR,
    .mipmapMode              = VK_SAMPLER_MIPMAP_MODE_LINEAR,
    .addressModeU            = VK_SAMPLER_ADDRESS_MODE_REPEAT,
    .addressModeV            = VK_SAMPLER_ADDRESS_MODE_REPEAT,
    .addressModeW            = VK_SAMPLER_ADDRESS_MODE_REPEAT,
    .mipLodBias              = 0.0f,
    .anisotropyEnable        = VK_FALSE,
    .maxAnisotropy           = 1.0f,
    .compareEnable           = VK_FALSE,
    .compareOp               = VK_COMPARE_OP_ALWAYS,
    .minLod                  = 0.0f,
    .maxLod                  = 0.0f,
    .borderColor             = VK_BORDER_COLOR_INT_OPAQUE_BLACK,
    .unnormalizedCoordinates = VK_FALSE,
  };

  VkSampler sampler;
  VR(vkCreateSampler(device_, &samplerInfo, nullptr, &sampler),
     "failed to create texture sampler!");

  return sampler;
}

void Vulkan::createColorResources()
{
  createImage(extent_.width,
              extent_.height,
              1,
              msaaSamples_,
              colorFormat_,
              VK_IMAGE_TILING_OPTIMAL,
              // Not TRANSIENT any more: a backdrop blur ends the main pass and
              // reopens it with LOAD_OP_LOAD, and the contents of a transient
              // attachment are undefined between render pass instances.
              VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
              VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
              colorImage_,
              colorImageAlloc_);

  colorImageView_ = createImageView(
    colorImage_, colorFormat_, VK_IMAGE_ASPECT_COLOR_BIT, 1);
}

void Vulkan::createResolveResources()
{
  // Single-sample target the MSAA color attachment resolves into. Unlike
  // colorImage_ (TRANSIENT_ATTACHMENT_BIT, MSAA scratch), this one needs
  // TRANSFER_SRC (readPixels / present blit / blur capture) and TRANSFER_DST
  // (composite blurred region back under glass panels).
  createImage(extent_.width,
              extent_.height,
              1,
              VK_SAMPLE_COUNT_1_BIT,
              colorFormat_,
              VK_IMAGE_TILING_OPTIMAL,
              VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                VK_IMAGE_USAGE_TRANSFER_DST_BIT,
              VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
              resolveImage_,
              resolveImageAlloc_);

  resolveImageView_ = createImageView(
    resolveImage_, colorFormat_, VK_IMAGE_ASPECT_COLOR_BIT, 1);
}

void Vulkan::createStagingBuffer()
{
  stagingBufferSize_ =
    static_cast<VkDeviceSize>(extent_.width) * extent_.height * 4;

  createBuffer(stagingBufferSize_,
               VK_BUFFER_USAGE_TRANSFER_DST_BIT,
               VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                 VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
               stagingBuffer_,
               stagingBufferAlloc_);

  stagingBufferMapped_ = mapBuffer(stagingBufferAlloc_);
  if (!stagingBufferMapped_) {
    throw std::runtime_error("failed to map staging buffer memory!");
  }
}

VkFormat Vulkan::findSupportedFormat(const std::vector<VkFormat>& candidates, VkImageTiling tiling, VkFormatFeatureFlags features)
{
  for (VkFormat format : candidates) {
    VkFormatProperties props;
    vkGetPhysicalDeviceFormatProperties(physicalDevice_, format, &props);

    if (tiling == VK_IMAGE_TILING_LINEAR && (props.linearTilingFeatures & features) == features) {
      return format;
    } else if (tiling == VK_IMAGE_TILING_OPTIMAL && (props.optimalTilingFeatures & features) == features) {
      return format;
    }
  }

  throw std::runtime_error("failed to find supported format!");
}

VkFormat Vulkan::findDepthFormat()
{
  return findSupportedFormat(
    {VK_FORMAT_D32_SFLOAT, VK_FORMAT_D32_SFLOAT_S8_UINT, VK_FORMAT_D24_UNORM_S8_UINT},
    VK_IMAGE_TILING_OPTIMAL,
    VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT
  );
}

bool Vulkan::hasStencilComponent(VkFormat format)
{
  return format == VK_FORMAT_D32_SFLOAT_S8_UINT || format == VK_FORMAT_D24_UNORM_S8_UINT;
}

void Vulkan::createDepthResources()
{
  VkFormat depthFormat = findDepthFormat();

  createImage(extent_.width,
              extent_.height,
              1,
              msaaSamples_,
              depthFormat,
              VK_IMAGE_TILING_OPTIMAL,
              VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
              VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
              depthImage_,
              depthImageAlloc_);

  depthImageView_ = createImageView(depthImage_, depthFormat, VK_IMAGE_ASPECT_DEPTH_BIT, 1);

  // Transition depth image to depth-stencil attachment optimal layout
  transitionImageLayout(depthImage_, depthFormat, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL);
}

void Vulkan::createShadowResources()
{
  VkFormat depthFormat = findDepthFormat();

  // Create shadow map image (depth texture)
  createImage(shadowMapSize_,
              shadowMapSize_,
              1,
              VK_SAMPLE_COUNT_1_BIT, // No MSAA for shadow maps
              depthFormat,
              VK_IMAGE_TILING_OPTIMAL,
              VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
              VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
              shadowImage_,
              shadowImageAlloc_);

  // Create shadow map image view
  shadowImageView_ = createImageView(shadowImage_, depthFormat, VK_IMAGE_ASPECT_DEPTH_BIT, 1);

  // Create shadow map sampler
  VkSamplerCreateInfo samplerInfo {
    .sType                   = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
    .magFilter               = VK_FILTER_LINEAR,
    .minFilter               = VK_FILTER_LINEAR,
    .mipmapMode              = VK_SAMPLER_MIPMAP_MODE_LINEAR,
    .addressModeU            = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
    .addressModeV            = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
    .addressModeW            = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
    .mipLodBias              = 0.0f,
    .anisotropyEnable        = VK_FALSE,
    .maxAnisotropy           = 1.0f,
    .compareEnable           = VK_TRUE, // Enable depth comparison for PCF
    .compareOp               = VK_COMPARE_OP_LESS_OR_EQUAL,
    .minLod                  = 0.0f,
    .maxLod                  = 1.0f,
    .borderColor             = VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE, // Outside shadow map = lit
    .unnormalizedCoordinates = VK_FALSE,
  };

  VR(vkCreateSampler(device_, &samplerInfo, nullptr, &shadowSampler_),
     "failed to create shadow sampler!");

  // Don't transition initially - let the render pass handle the transition
  // The shadow render pass will transition from UNDEFINED to SHADER_READ_ONLY_OPTIMAL
}

void Vulkan::createShadowRenderPass()
{
  VkAttachmentDescription depthAttachment {
    .format         = findDepthFormat(),
    .samples        = VK_SAMPLE_COUNT_1_BIT,
    .loadOp         = VK_ATTACHMENT_LOAD_OP_CLEAR,
    .storeOp        = VK_ATTACHMENT_STORE_OP_STORE,
    .stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
    .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
    .initialLayout  = VK_IMAGE_LAYOUT_UNDEFINED,
    .finalLayout    = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
  };

  VkAttachmentReference depthAttachmentRef {
    .attachment = 0,
    .layout     = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
  };

  VkSubpassDescription subpass {
    .pipelineBindPoint       = VK_PIPELINE_BIND_POINT_GRAPHICS,
    .colorAttachmentCount    = 0, // No color attachments for shadow pass
    .pColorAttachments       = nullptr,
    .pDepthStencilAttachment = &depthAttachmentRef,
  };

  // Subpass dependency for layout transitions
  VkSubpassDependency dependency {
    .srcSubpass    = VK_SUBPASS_EXTERNAL,
    .dstSubpass    = 0,
    .srcStageMask  = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    .dstStageMask  = VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
    .srcAccessMask = VK_ACCESS_SHADER_READ_BIT,
    .dstAccessMask = VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
  };

  VkRenderPassCreateInfo renderPassInfo {
    .sType           = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
    .attachmentCount = 1,
    .pAttachments    = &depthAttachment,
    .subpassCount    = 1,
    .pSubpasses      = &subpass,
    .dependencyCount = 1,
    .pDependencies   = &dependency,
  };

  VR(vkCreateRenderPass(device_, &renderPassInfo, nullptr, &shadowRenderPass_),
     "failed to create shadow render pass!");
}

void Vulkan::createShadowFramebuffer()
{
  VkFramebufferCreateInfo framebufferInfo {
    .sType           = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
    .renderPass      = shadowRenderPass_,
    .attachmentCount = 1,
    .pAttachments    = &shadowImageView_,
    .width           = shadowMapSize_,
    .height          = shadowMapSize_,
    .layers          = 1,
  };

  VR(vkCreateFramebuffer(device_, &framebufferInfo, nullptr, &shadowFramebuffer_),
     "failed to create shadow framebuffer!");
}

void Vulkan::beginShadowPass(VkCommandBuffer commandBuffer)
{
  VkClearValue clearDepth {};
  clearDepth.depthStencil = {1.0f, 0};

  VkRenderPassBeginInfo renderPassInfo {
    .sType           = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
    .renderPass      = shadowRenderPass_,
    .framebuffer     = shadowFramebuffer_,
    .renderArea      = {.offset = {0, 0}, .extent = {shadowMapSize_, shadowMapSize_}},
    .clearValueCount = 1,
    .pClearValues    = &clearDepth,
  };

  vkCmdBeginRenderPass(
    commandBuffer, &renderPassInfo, VK_SUBPASS_CONTENTS_INLINE);

  // Set viewport for shadow map
  VkViewport viewport {
    .x        = 0.0f,
    .y        = 0.0f,
    .width    = static_cast<float>(shadowMapSize_),
    .height   = static_cast<float>(shadowMapSize_),
    .minDepth = 0.0f,
    .maxDepth = 1.0f,
  };

  vkCmdSetViewport(commandBuffer, 0, 1, &viewport);

  VkRect2D scissor {
    .offset = {0, 0},
    .extent = {shadowMapSize_, shadowMapSize_},
  };

  vkCmdSetScissor(commandBuffer, 0, 1, &scissor);
}

void Vulkan::createRenderPass()
{
  auto makePass = [&](bool clear, VkRenderPass *out) {
    std::array<VkAttachmentDescription, 3> attachments {
      // colorAttachment (MSAA)
      VkAttachmentDescription {
        .format         = colorFormat_,
        .samples        = msaaSamples_,
        .loadOp         = clear ? VK_ATTACHMENT_LOAD_OP_CLEAR
                                : VK_ATTACHMENT_LOAD_OP_LOAD,
        .storeOp        = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout  = clear ? VK_IMAGE_LAYOUT_UNDEFINED
                                : VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .finalLayout    = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
      },
      // depthAttachment
      VkAttachmentDescription {
        .format         = findDepthFormat(),
        .samples        = msaaSamples_,
        .loadOp         = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp        = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout  = VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout    = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
      },
      // resolve — sampleable / transferable after the pass
      VkAttachmentDescription {
        .format         = colorFormat_,
        .samples        = VK_SAMPLE_COUNT_1_BIT,
        .loadOp         = clear ? VK_ATTACHMENT_LOAD_OP_DONT_CARE
                                : VK_ATTACHMENT_LOAD_OP_LOAD,
        .storeOp        = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout  = clear ? VK_IMAGE_LAYOUT_UNDEFINED
                                : VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .finalLayout    = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
      },
    };

    VkAttachmentReference colorAttachmentRef {
      .attachment = 0,
      .layout     = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    VkAttachmentReference depthAttachmentRef {
      .attachment = 1,
      .layout     = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    };
    VkAttachmentReference colorAttachmentResolveRef {
      .attachment = 2,
      .layout     = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    VkSubpassDescription subpass {
      .pipelineBindPoint       = VK_PIPELINE_BIND_POINT_GRAPHICS,
      .colorAttachmentCount    = 1,
      .pColorAttachments       = &colorAttachmentRef,
      .pResolveAttachments     = &colorAttachmentResolveRef,
      .pDepthStencilAttachment = &depthAttachmentRef,
    };

    VkSubpassDependency dependency {
      .srcSubpass    = 0,
      .dstSubpass    = VK_SUBPASS_EXTERNAL,
      .srcStageMask  = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
      .dstStageMask  = VK_PIPELINE_STAGE_TRANSFER_BIT,
      .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
      .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
    };

    VkRenderPassCreateInfo renderPassInfo {
      .sType           = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
      .attachmentCount = 3,
      .pAttachments    = attachments.data(),
      .subpassCount    = 1,
      .pSubpasses      = &subpass,
      .dependencyCount = 1,
      .pDependencies   = &dependency,
    };

    const char *msg = clear ? "failed to create render pass!"
                            : "failed to create continue render pass!";
    VR(vkCreateRenderPass(device_, &renderPassInfo, nullptr, out), msg);
  };

  makePass(true, &renderPass_);
  makePass(false, &renderPassContinue_);
}

void Vulkan::createFramebuffer()
{
  VkImageView attachments[] = {colorImageView_, depthImageView_, resolveImageView_};

  auto makeFb = [&](VkRenderPass rp, VkFramebuffer *out) {
    VkFramebufferCreateInfo framebufferInfo {
      .sType           = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
      .renderPass      = rp,
      .attachmentCount = 3,
      .pAttachments    = attachments,
      .width           = extent_.width,
      .height          = extent_.height,
      .layers          = 1,
    };
    VR(vkCreateFramebuffer(device_, &framebufferInfo, nullptr, out),
       "failed to create framebuffer!");
  };
  makeFb(renderPass_, &framebuffer_);
  makeFb(renderPassContinue_, &framebufferContinue_);
}

void Vulkan::createCommandPool()
{
  assert(graphicsAndPresentationQueueFamilyIdx_ != std::numeric_limits<u32>::max() && "queue family index not set");
  VkCommandPoolCreateInfo poolInfo {
    .sType            = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
    .flags            = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
    .queueFamilyIndex = graphicsAndPresentationQueueFamilyIdx_,
  };
  VR(vkCreateCommandPool(device_, &poolInfo, nullptr, &commandPool_),
     "failed to create command pool!");
}

VkShaderModule Vulkan::createShaderModule(
  const std::vector<char> &code)
{
  VkShaderModuleCreateInfo createInfo {
    .sType    = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
    .codeSize = code.size(),
    .pCode    = reinterpret_cast<const uint32_t *>(code.data()),
  };

  VkShaderModule shaderModule;
  VR(vkCreateShaderModule(device_, &createInfo, nullptr, &shaderModule),
     "failed to create shader module!");

  return shaderModule;
}

void Vulkan::createCommandBuffer()
{
  VkCommandBufferAllocateInfo allocInfo {
    .sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
    .commandPool        = commandPool_,
    .level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
    .commandBufferCount = kMaxFramesInFlight,
  };
  VR(vkAllocateCommandBuffers(device_, &allocInfo, commandBuffers_),
     "failed to allocate command buffers!");
}

void Vulkan::createSyncObjects()
{
  VkFenceCreateInfo fenceInfo {
    .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
    .flags = VK_FENCE_CREATE_SIGNALED_BIT,  // first use of each slot is free
  };
  for (uint32_t i = 0; i < kMaxFramesInFlight; ++i) {
    VR(vkCreateFence(device_, &fenceInfo, nullptr, &inFlightFences_[i]),
       "vkCreateFence failed.");
  }
  currentFrame_ = 0;
}

void Vulkan::createPresentSyncObjects()
{
  // Acquire semaphores are per frames-in-flight (safe: tied to the frame fence).
  // Present-wait (renderFinished) semaphores live with the swapchain images —
  // see createSwapchain / cleanupSwapchain.
  VkSemaphoreCreateInfo semInfo {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
  for (uint32_t i = 0; i < kMaxFramesInFlight; ++i) {
    VR(vkCreateSemaphore(device_, &semInfo, nullptr, &imageAvailableSemaphores_[i]),
       "imageAvailable semaphore");
  }
}

void Vulkan::createWindowSurface()
{
  VR(glfwCreateWindowSurface(instance_, window_, nullptr, &surface_),
     "failed to create window surface");
}

void Vulkan::createSwapchain()
{
  VkSurfaceCapabilitiesKHR caps {};
  vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physicalDevice_, surface_, &caps);

  uint32_t formatCount = 0;
  vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice_, surface_, &formatCount, nullptr);
  std::vector<VkSurfaceFormatKHR> formats(formatCount);
  vkGetPhysicalDeviceSurfaceFormatsKHR(
    physicalDevice_, surface_, &formatCount, formats.data());

  VkSurfaceFormatKHR chosen = formats[0];
  for (const auto &f : formats) {
    if (f.format == VK_FORMAT_B8G8R8A8_SRGB &&
        f.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
      chosen = f;
      break;
    }
  }
  swapchainImageFormat_ = chosen.format;

  if (caps.currentExtent.width != UINT32_MAX) {
    swapchainExtent_ = caps.currentExtent;
  } else {
    int fbW = 0, fbH = 0;
    glfwGetFramebufferSize(window_, &fbW, &fbH);
    swapchainExtent_.width = std::clamp(
      static_cast<uint32_t>(fbW), caps.minImageExtent.width, caps.maxImageExtent.width);
    swapchainExtent_.height = std::clamp(
      static_cast<uint32_t>(fbH), caps.minImageExtent.height, caps.maxImageExtent.height);
  }

  // Keep offscreen target size in sync with the window framebuffer.
  extent_ = swapchainExtent_;

  uint32_t imageCount = caps.minImageCount + 1;
  if (caps.maxImageCount > 0 && imageCount > caps.maxImageCount) {
    imageCount = caps.maxImageCount;
  }

  uint32_t presentModeCount = 0;
  vkGetPhysicalDeviceSurfacePresentModesKHR(
    physicalDevice_, surface_, &presentModeCount, nullptr);
  std::vector<VkPresentModeKHR> presentModes(presentModeCount);
  vkGetPhysicalDeviceSurfacePresentModesKHR(
    physicalDevice_, surface_, &presentModeCount, presentModes.data());

  // MAILBOX preferred, FIFO as the fallback.
  //
  // The history is worth keeping, because two of these were tried in anger:
  //
  //   FIFO      classic vsync, the only mode the spec guarantees. Correct and
  //             non-tearing, but presenting blocks until the next refresh, and
  //             that latency is felt directly in pointer work — dragging a
  //             boundary in TraceLoom (button down + move) visibly trailed the
  //             cursor. That is what drove us off it.
  //   IMMEDIATE no blocking and no queue, so the lowest latency available, at
  //             the cost of tearing. Ran this for a while; no tearing was
  //             actually observed, but it is a real risk we were simply
  //             getting away with.
  //   MAILBOX   non-tearing like FIFO, but present replaces the queued image
  //             instead of blocking, so a drag does not acquire FIFO's lag.
  //             Best of both, and where we settled.
  //
  // Only FIFO is guaranteed by the spec, and asking for a mode the surface did
  // not report is a validation error (VUID-VkSwapchainCreateInfoKHR-
  // presentMode-01281), not a silent downgrade — so this picks from what was
  // actually queried rather than naming a constant and hoping. That is what
  // makes the code portable to a driver without MAILBOX (MoltenVK being the
  // obvious question mark) without anyone having to know in advance.
  //
  // LAVA_PRESENT_MODE=fifo|mailbox|immediate forces one, for measuring the
  // latency trade above without a rebuild. An unsupported request still falls
  // back rather than crashing.
  auto hasMode = [&presentModes](VkPresentModeKHR m) {
    return std::find(presentModes.begin(), presentModes.end(), m) != presentModes.end();
  };

  // FIFO is the guaranteed floor; each branch below is an upgrade on it,
  // preferred in order.
  VkPresentModeKHR presentMode = VK_PRESENT_MODE_FIFO_KHR;
  const char *presentName = "FIFO";
  if (hasMode(VK_PRESENT_MODE_MAILBOX_KHR)) {
    presentMode = VK_PRESENT_MODE_MAILBOX_KHR;
    presentName = "MAILBOX";
  } else if (fifoLatestReadyEnabled_ && hasMode(VK_PRESENT_MODE_FIFO_LATEST_READY_KHR)) {
    // Same guarantee as MAILBOX, different spelling.
    presentMode = VK_PRESENT_MODE_FIFO_LATEST_READY_KHR;
    presentName = "FIFO_LATEST_READY";
  } else if (hasMode(VK_PRESENT_MODE_IMMEDIATE_KHR)) {
    // Ranked above plain FIFO deliberately. FIFO's blocking present is the
    // lag that drove this app off it for pointer work, and IMMEDIATE ran for
    // a long stretch here without tearing being observed. A surface offering
    // neither MAILBOX nor latest-ready leaves this as the only low-latency
    // option, and latency is the property this UI cares about most.
    presentMode = VK_PRESENT_MODE_IMMEDIATE_KHR;
    presentName = "IMMEDIATE";
  }

  if (const char *forced = std::getenv("LAVA_PRESENT_MODE")) {
    const std::string want(forced);
    VkPresentModeKHR requested = presentMode;
    const char *requestedName = nullptr;
    if (want == "fifo") {
      requested = VK_PRESENT_MODE_FIFO_KHR;
      requestedName = "FIFO";
    } else if (want == "mailbox") {
      requested = VK_PRESENT_MODE_MAILBOX_KHR;
      requestedName = "MAILBOX";
    } else if (want == "immediate") {
      requested = VK_PRESENT_MODE_IMMEDIATE_KHR;
      requestedName = "IMMEDIATE";
    } else if (want == "latest") {
      requested = VK_PRESENT_MODE_FIFO_LATEST_READY_KHR;
      requestedName = "FIFO_LATEST_READY";
    }
    if (requestedName != nullptr) {
      if (requested == VK_PRESENT_MODE_FIFO_LATEST_READY_KHR
          && !fifoLatestReadyEnabled_) {
        std::cout << "Present mode FIFO_LATEST_READY needs "
                  << VK_KHR_PRESENT_MODE_FIFO_LATEST_READY_EXTENSION_NAME
                  << ", which this device does not expose; using " << presentName << "\n";
      } else if (hasMode(requested)) {
        presentMode = requested;
        presentName = requestedName;
      } else {
        std::cout << "Present mode " << requestedName
                  << " not supported by this surface; using " << presentName << "\n";
      }
    }
  }

  // MAILBOX needs a spare image to swap in, or it degrades to FIFO's pacing
  // with none of the latency benefit that is the whole reason for choosing it.
  if (presentMode == VK_PRESENT_MODE_MAILBOX_KHR && imageCount < 3) {
    imageCount = 3;
    if (caps.maxImageCount > 0 && imageCount > caps.maxImageCount) {
      imageCount = caps.maxImageCount;
    }
  }

  VkSwapchainCreateInfoKHR sci {
    .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
    .surface = surface_,
    .minImageCount = imageCount,
    .imageFormat = swapchainImageFormat_,
    .imageColorSpace = chosen.colorSpace,
    .imageExtent = swapchainExtent_,
    .imageArrayLayers = 1,
    .imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
    .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
    .preTransform = caps.currentTransform,
    .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
    .presentMode = presentMode,
    .clipped = VK_TRUE,
    .oldSwapchain = VK_NULL_HANDLE,
  };

  VR(vkCreateSwapchainKHR(device_, &sci, nullptr, &swapchain_),
     "failed to create swapchain");

  uint32_t actualCount = 0;
  vkGetSwapchainImagesKHR(device_, swapchain_, &actualCount, nullptr);
  swapchainImages_.resize(actualCount);
  vkGetSwapchainImagesKHR(device_, swapchain_, &actualCount, swapchainImages_.data());

  swapchainImageViews_.resize(actualCount);
  for (uint32_t i = 0; i < actualCount; ++i) {
    swapchainImageViews_[i] = createImageView(
      swapchainImages_[i], swapchainImageFormat_, VK_IMAGE_ASPECT_COLOR_BIT, 1);
  }

  // One present-wait semaphore per swapchain image. Index by acquired image
  // index so a semaphore is only reused after that image is re-acquired
  // (which means the previous present that waited on it has finished).
  VkSemaphoreCreateInfo semInfo {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
  renderFinishedSemaphores_.assign(actualCount, VK_NULL_HANDLE);
  for (uint32_t i = 0; i < actualCount; ++i) {
    VR(vkCreateSemaphore(device_, &semInfo, nullptr, &renderFinishedSemaphores_[i]),
       "renderFinished semaphore");
  }

  std::cout << "Swapchain: " << swapchainExtent_.width << "x"
            << swapchainExtent_.height << " (" << actualCount
            << " images, present=" << presentName
            << ", framesInFlight=" << kMaxFramesInFlight << ")\n";
}

void Vulkan::cleanupSwapchain()
{
  for (auto sem : renderFinishedSemaphores_) {
    if (sem != VK_NULL_HANDLE) vkDestroySemaphore(device_, sem, nullptr);
  }
  renderFinishedSemaphores_.clear();

  for (auto view : swapchainImageViews_) {
    if (view != VK_NULL_HANDLE) vkDestroyImageView(device_, view, nullptr);
  }
  swapchainImageViews_.clear();
  swapchainImages_.clear();
  if (swapchain_ != VK_NULL_HANDLE) {
    vkDestroySwapchainKHR(device_, swapchain_, nullptr);
    swapchain_ = VK_NULL_HANDLE;
  }
}

void Vulkan::beginMainRenderPass(VkCommandBuffer commandBuffer, bool clear)
{
  if (!clear) {
    // After a blur segment, resolve is TRANSFER_SRC; continue pass needs it
    // as a color attachment with LOAD.
    VkImageMemoryBarrier toColor{
      .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
      .srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_SHADER_READ_BIT,
      .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_READ_BIT |
                       VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
      .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
      .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .image = resolveImage_,
      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    // Both source stages, since the resolve was read by the capture blit
    // (TRANSFER) and SHADER_READ is in the access mask.
    vkCmdPipelineBarrier(
      commandBuffer,
      VK_PIPELINE_STAGE_TRANSFER_BIT | VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
      VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, nullptr, 0, nullptr,
      1, &toColor);
  }

  std::array<VkClearValue, 2> clearValues {};
  clearValues[0].color = {{0.0f, 0.0f, 0.0f, 1.0f}};
  clearValues[1].depthStencil = {1.0f, 0};

  VkRenderPassBeginInfo renderPassInfo {
    .sType           = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
    .renderPass      = clear ? renderPass_ : renderPassContinue_,
    .framebuffer     = clear ? framebuffer_ : framebufferContinue_,
    .renderArea      = {.offset = {0, 0}, .extent = extent_},
    .clearValueCount = static_cast<uint32_t>(clearValues.size()),
    .pClearValues    = clearValues.data(),
  };

  vkCmdBeginRenderPass(
    commandBuffer, &renderPassInfo, VK_SUBPASS_CONTENTS_INLINE);

  VkViewport viewport {
    .x        = 0.0f,
    .y        = 0.0f,
    .width    = static_cast<float>(extent_.width),
    .height   = static_cast<float>(extent_.height),
    .minDepth = 0.0f,
    .maxDepth = 1.0f,
  };

  vkCmdSetViewport(commandBuffer, 0, 1, &viewport);

  VkRect2D scissor {
    .offset = {0, 0},
    .extent = extent_,
  };

  vkCmdSetScissor(commandBuffer, 0, 1, &scissor);
}

void Vulkan::endMainRenderPass(VkCommandBuffer commandBuffer)
{
  vkCmdEndRenderPass(commandBuffer);
}

VkCommandBuffer Vulkan::beginSingleTimeCommands()
{
  assert(device_ != VK_NULL_HANDLE && "device not initialized");
  assert(commandPool_ != VK_NULL_HANDLE && "command pool not initialized");

  VkCommandBufferAllocateInfo allocInfo {
    .sType              = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
    .commandPool        = commandPool_,
    .level              = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
    .commandBufferCount = 1,
  };

  VkCommandBuffer commandBuffer;
  vkAllocateCommandBuffers(device_, &allocInfo, &commandBuffer);

  VkCommandBufferBeginInfo beginInfo {
    .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
  };

  vkBeginCommandBuffer(commandBuffer, &beginInfo);

  return commandBuffer;
}

void Vulkan::endSingleTimeCommands(
  VkCommandBuffer commandBuffer)
{
  vkEndCommandBuffer(commandBuffer);

  VkSubmitInfo submitInfo {
    .sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO,
    .commandBufferCount = 1,
    .pCommandBuffers    = &commandBuffer,
  };

  VR(vkQueueSubmit(graphicsQueue_, 1, &submitInfo, VK_NULL_HANDLE),
     "failed to submit single time command buffer!");

  // Wait until the command buffer has finished executing
  vkQueueWaitIdle(graphicsQueue_);
  vkFreeCommandBuffers(device_, commandPool_, 1, &commandBuffer);
}

void Vulkan::transitionImageLayout(
  VkImage       image,
  VkFormat      format,
  VkImageLayout oldLayout,
  VkImageLayout newLayout)
{
  VkCommandBuffer commandBuffer = beginSingleTimeCommands();

  VkImageMemoryBarrier barrier {
    .sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
    .oldLayout           = oldLayout,
    .newLayout           = newLayout,
    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
    .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
    .image               = image,
    .subresourceRange =
      {
        .aspectMask     = static_cast<VkImageAspectFlags>(
          newLayout == VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL ? VK_IMAGE_ASPECT_DEPTH_BIT : VK_IMAGE_ASPECT_COLOR_BIT),
        .baseMipLevel   = 0,
        .levelCount     = 1,
        .baseArrayLayer = 0,
        .layerCount     = 1,
      },
  };

  if (hasStencilComponent(format)) {
    barrier.subresourceRange.aspectMask |= VK_IMAGE_ASPECT_STENCIL_BIT;
  }

  VkPipelineStageFlags sourceStage;
  VkPipelineStageFlags destinationStage;

  if (oldLayout == VK_IMAGE_LAYOUT_UNDEFINED &&
      newLayout == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) {
    barrier.srcAccessMask = 0;
    barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;

    sourceStage      = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
    destinationStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
  } else if (oldLayout == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL &&
             newLayout == VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL) {
    // Sampled image becoming a copy source — used when the glyph atlas grows
    // and its contents are blitted into a larger image.
    barrier.srcAccessMask = VK_ACCESS_SHADER_READ_BIT;
    barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;

    sourceStage      = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    destinationStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
  } else if (oldLayout == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL &&
             newLayout == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;

    sourceStage      = VK_PIPELINE_STAGE_TRANSFER_BIT;
    destinationStage = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
  } else if (oldLayout == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL &&
             newLayout == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) {
    // Re-uploading into an image already being sampled: an atlas page takes a
    // new cell while the rest of it is live. Without this the helper throws,
    // and a C++ exception crossing back into Swift aborts the process rather
    // than surfacing as an error.
    barrier.srcAccessMask = VK_ACCESS_SHADER_READ_BIT;
    barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;

    sourceStage      = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    destinationStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
  } else if (oldLayout == VK_IMAGE_LAYOUT_UNDEFINED &&
             newLayout == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
    // Direct transition for images that don't need initial data upload
    barrier.srcAccessMask = 0;
    barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;

    sourceStage      = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
    destinationStage = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
  } else if (oldLayout == VK_IMAGE_LAYOUT_UNDEFINED &&
             newLayout == VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL) {
    barrier.srcAccessMask = 0;
    barrier.dstAccessMask = VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;

    sourceStage      = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
    destinationStage = VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
  } else {
    throw std::invalid_argument("unsupported layout transition: " +
                                std::to_string(oldLayout) + " to " +
                                std::to_string(newLayout));
  }

  vkCmdPipelineBarrier(commandBuffer,
                       sourceStage,
                       destinationStage,
                       0,
                       0,
                       nullptr,
                       0,
                       nullptr,
                       1,
                       &barrier);

  endSingleTimeCommands(commandBuffer);
}

void Vulkan::copyBufferToImageRegion(
  VkBuffer buffer, VkImage image, int32_t dstX, int32_t dstY,
  uint32_t width, uint32_t height)
{
  VkCommandBuffer commandBuffer = beginSingleTimeCommands();

  VkBufferImageCopy region {
    .bufferOffset      = 0,
    .bufferRowLength   = 0,
    .bufferImageHeight = 0,
    .imageSubresource =
      {
        .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
        .mipLevel       = 0,
        .baseArrayLayer = 0,
        .layerCount     = 1,
      },
    .imageOffset = {dstX, dstY, 0},
    .imageExtent = {width, height, 1},
  };

  vkCmdCopyBufferToImage(commandBuffer,
                         buffer,
                         image,
                         VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                         1,
                         &region);

  endSingleTimeCommands(commandBuffer);
}

void Vulkan::copyBufferToImage(
  VkBuffer buffer, VkImage image, uint32_t width, uint32_t height)
{
  VkCommandBuffer commandBuffer = beginSingleTimeCommands();

  VkBufferImageCopy region {
    .bufferOffset      = 0,
    .bufferRowLength   = 0,
    .bufferImageHeight = 0,
    .imageSubresource =
      {
        .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
        .mipLevel       = 0,
        .baseArrayLayer = 0,
        .layerCount     = 1,
      },
    .imageOffset = {0, 0, 0},
    .imageExtent = {width, height, 1},
  };

  vkCmdCopyBufferToImage(commandBuffer,
                         buffer,
                         image,
                         VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                         1,
                         &region);

  endSingleTimeCommands(commandBuffer);
}

void Vulkan::cleanUp()
{
  if (device_ != VK_NULL_HANDLE) {
    vkDeviceWaitIdle(device_);
  }

  // The wait above means nothing in the trash can still be referenced, so
  // everything queued is releasable regardless of its retire frame.
  for (auto &t : trash_) {
    if (t.view != VK_NULL_HANDLE) vkDestroyImageView(device_, t.view, nullptr);
    if (t.image != VK_NULL_HANDLE) vmaDestroyImage(allocator_, t.image, t.allocation);
  }
  trash_.clear();

#ifdef INCLUDE_IMGUI
  if (imguiInitialized_) {
    if (windowed_) {
      ImGui_ImplGlfw_Shutdown();
    }
    ImGui_ImplVulkan_Shutdown();
    ImGui::DestroyContext();
    imguiInitialized_ = false;
  }

  if (imguiDescriptorPool_ != VK_NULL_HANDLE) {
    vkDestroyDescriptorPool(device_, imguiDescriptorPool_, nullptr);
    imguiDescriptorPool_ = VK_NULL_HANDLE;
  }
#endif

  for (uint32_t i = 0; i < kMaxFramesInFlight; ++i) {
    if (imageAvailableSemaphores_[i] != VK_NULL_HANDLE) {
      vkDestroySemaphore(device_, imageAvailableSemaphores_[i], nullptr);
      imageAvailableSemaphores_[i] = VK_NULL_HANDLE;
    }
    if (inFlightFences_[i] != VK_NULL_HANDLE) {
      vkDestroyFence(device_, inFlightFences_[i], nullptr);
      inFlightFences_[i] = VK_NULL_HANDLE;
    }
    commandBuffers_[i] = VK_NULL_HANDLE;  // freed with command pool
  }
  // renderFinishedSemaphores_ are destroyed in cleanupSwapchain().

  if (commandPool_ != VK_NULL_HANDLE) {
    vkDestroyCommandPool(device_, commandPool_, nullptr);
    commandPool_ = VK_NULL_HANDLE;
  }
  if (framebuffer_ != VK_NULL_HANDLE) {
    vkDestroyFramebuffer(device_, framebuffer_, nullptr);
    framebuffer_ = VK_NULL_HANDLE;
  }
  if (framebufferContinue_ != VK_NULL_HANDLE) {
    vkDestroyFramebuffer(device_, framebufferContinue_, nullptr);
    framebufferContinue_ = VK_NULL_HANDLE;
  }

  cleanupSwapchain();

  if (stagingBufferMapped_) {
    if (stagingBufferAlloc_ != VK_NULL_HANDLE) unmapBuffer(stagingBufferAlloc_);
    stagingBufferMapped_ = nullptr;
  }
  destroyBuffer(stagingBuffer_, stagingBufferAlloc_);

  if (resolveImageView_ != VK_NULL_HANDLE) {
    vkDestroyImageView(device_, resolveImageView_, nullptr);
    resolveImageView_ = VK_NULL_HANDLE;
  }
  destroyImage(resolveImage_, resolveImageAlloc_);

  // MSAA
  if (colorImageView_ != VK_NULL_HANDLE) {
    vkDestroyImageView(device_, colorImageView_, nullptr);
    colorImageView_ = VK_NULL_HANDLE;
  }
  destroyImage(colorImage_, colorImageAlloc_);

  // Depth buffer
  if (depthImageView_ != VK_NULL_HANDLE) {
    vkDestroyImageView(device_, depthImageView_, nullptr);
    depthImageView_ = VK_NULL_HANDLE;
  }
  destroyImage(depthImage_, depthImageAlloc_);

  // Shadow mapping
  if (shadowSampler_ != VK_NULL_HANDLE) {
    vkDestroySampler(device_, shadowSampler_, nullptr);
    shadowSampler_ = VK_NULL_HANDLE;
  }
  if (shadowFramebuffer_ != VK_NULL_HANDLE) {
    vkDestroyFramebuffer(device_, shadowFramebuffer_, nullptr);
    shadowFramebuffer_ = VK_NULL_HANDLE;
  }
  if (shadowImageView_ != VK_NULL_HANDLE) {
    vkDestroyImageView(device_, shadowImageView_, nullptr);
    shadowImageView_ = VK_NULL_HANDLE;
  }
  destroyImage(shadowImage_, shadowImageAlloc_);
  if (shadowRenderPass_ != VK_NULL_HANDLE) {
    vkDestroyRenderPass(device_, shadowRenderPass_, nullptr);
    shadowRenderPass_ = VK_NULL_HANDLE;
  }

  if (renderPass_ != VK_NULL_HANDLE) {
    vkDestroyRenderPass(device_, renderPass_, nullptr);
    renderPass_ = VK_NULL_HANDLE;
  }
  if (renderPassContinue_ != VK_NULL_HANDLE) {
    vkDestroyRenderPass(device_, renderPassContinue_, nullptr);
    renderPassContinue_ = VK_NULL_HANDLE;
  }

  auto &shaders = getShaders();
  shaders.cleanUp();

  // Allocator must outlive every VMA-owned buffer/image (already destroyed
  // above). Destroy before the logical device.
  destroyAllocator();

  if (device_ != VK_NULL_HANDLE) {
    vkDestroyDevice(device_, nullptr);
    device_ = VK_NULL_HANDLE;
  }

  if (surface_ != VK_NULL_HANDLE) {
    vkDestroySurfaceKHR(instance_, surface_, nullptr);
    surface_ = VK_NULL_HANDLE;
  }

  if (enableValidationLayers_ && debugMessenger_ != VK_NULL_HANDLE) {
    destroyDebugUtilsMessengerEXT(instance_, debugMessenger_, nullptr);
    debugMessenger_ = VK_NULL_HANDLE;
  }

  if (instance_ != VK_NULL_HANDLE) {
    vkDestroyInstance(instance_, nullptr);
    instance_ = VK_NULL_HANDLE;
  }

  if (ownsWindow_ && window_) {
    glfwDestroyWindow(window_);
    window_ = nullptr;
    ownsWindow_ = false;
    glfwTerminate();
  }
  windowed_ = false;
}

void Vulkan::waitForInFlightFrame()
{
  if (inFlightFences_[currentFrame_] == VK_NULL_HANDLE) return;
  vkWaitForFences(device_, 1, &inFlightFences_[currentFrame_], VK_TRUE,
                  UINT64_MAX);
}

void Vulkan::waitForAllFramesInFlight()
{
  // Gather non-null fences (init order may leave some unset during teardown).
  VkFence fences[kMaxFramesInFlight];
  uint32_t n = 0;
  for (uint32_t i = 0; i < kMaxFramesInFlight; ++i) {
    if (inFlightFences_[i] != VK_NULL_HANDLE) {
      fences[n++] = inFlightFences_[i];
    }
  }
  if (n == 0) return;
  vkWaitForFences(device_, n, fences, VK_TRUE, UINT64_MAX);
}

void Vulkan::renderWithShadows(
  std::function<void(VkCommandBuffer)> shadowCallback,
  std::function<void(VkCommandBuffer, u32)> mainCallback)
{
  // Wait only for *this* slot. The other slot may still be on the GPU — that
  // is the whole point of frames-in-flight. Application should already have
  // waited this slot before rewriting its host-visible buffers.
  //
  // Fence is reset only after we know we will submit: an early return with a
  // reset fence leaves the slot stuck unsignalled forever.
  waitForInFlightFrame();

  const uint32_t frame = currentFrame_;
  VkCommandBuffer cmd = commandBuffers_[frame];
  VkFence fence = inFlightFences_[frame];

  uint32_t swapImageIndex = 0;
  if (windowed_) {
    VkResult acq = vkAcquireNextImageKHR(
      device_, swapchain_, UINT64_MAX, imageAvailableSemaphores_[frame],
      VK_NULL_HANDLE, &swapImageIndex);
    if (acq == VK_ERROR_OUT_OF_DATE_KHR) {
      // Swapchain is stale; ensureFramebufferSize() rebuilds it. Fence stays
      // signalled so the next attempt on this slot is free.
      return;
    }
    if (acq != VK_SUCCESS && acq != VK_SUBOPTIMAL_KHR) {
      VR(acq, "vkAcquireNextImageKHR failed");
    }
  }

  vkResetFences(device_, 1, &fence);

  const u32 imageIndex = 0; // offscreen framebuffer index (single target)

  vkResetCommandBuffer(cmd, 0);

  VkCommandBufferBeginInfo beginInfo {
    VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
  };

  VR(vkBeginCommandBuffer(cmd, &beginInfo),
     "failed to begin recording command buffer!");

  // 1. Shadow Pass
  beginShadowPass(cmd);
  shadowCallback(cmd);
  vkCmdEndRenderPass(cmd);

  // 2. Main UI — callback owns begin/end of main pass(es) for blur interrupts.
  mainCallback(cmd, imageIndex);

  if (windowed_) {
    // 3a. Blit offscreen resolve → swapchain image, then present.
    VkImage swapImage = swapchainImages_[swapImageIndex];

    VkImageMemoryBarrier toDst {
      .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
      .srcAccessMask = 0,
      .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
      .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
      .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .image = swapImage,
      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    vkCmdPipelineBarrier(
      cmd,
      VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
      VK_PIPELINE_STAGE_TRANSFER_BIT,
      0, 0, nullptr, 0, nullptr, 1, &toDst);

    VkImageBlit blit {
      .srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
      .srcOffsets = {{0, 0, 0},
                     {static_cast<int32_t>(extent_.width),
                      static_cast<int32_t>(extent_.height), 1}},
      .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
      .dstOffsets = {{0, 0, 0},
                     {static_cast<int32_t>(swapchainExtent_.width),
                      static_cast<int32_t>(swapchainExtent_.height), 1}},
    };
    vkCmdBlitImage(
      cmd,
      resolveImage_, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
      swapImage, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
      1, &blit, VK_FILTER_LINEAR);

    VkImageMemoryBarrier toPresent {
      .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
      .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
      .dstAccessMask = 0,
      .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
      .newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .image = swapImage,
      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
    };
    vkCmdPipelineBarrier(
      cmd,
      VK_PIPELINE_STAGE_TRANSFER_BIT,
      VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
      0, 0, nullptr, 0, nullptr, 1, &toPresent);
  } else {
    // 3b. Offscreen: copy resolve → staging for readPixels().
    VkBufferImageCopy copyRegion {
      .bufferOffset      = 0,
      .bufferRowLength    = 0,
      .bufferImageHeight = 0,
      .imageSubresource =
        {
          .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
          .mipLevel       = 0,
          .baseArrayLayer = 0,
          .layerCount     = 1,
        },
      .imageOffset = {0, 0, 0},
      .imageExtent = {extent_.width, extent_.height, 1},
    };

    vkCmdCopyImageToBuffer(cmd,
                          resolveImage_,
                          VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                          stagingBuffer_,
                          1,
                          &copyRegion);
  }

  VR(vkEndCommandBuffer(cmd), "failed to record command buffer!");

  VkSubmitInfo submitInfo {
    .sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO,
    .commandBufferCount = 1,
    .pCommandBuffers    = &cmd,
  };

  VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
  // Present-wait semaphore is keyed by swapchain image index, not frame slot.
  VkSemaphore renderFinished = VK_NULL_HANDLE;
  if (windowed_) {
    assert(swapImageIndex < renderFinishedSemaphores_.size());
    renderFinished = renderFinishedSemaphores_[swapImageIndex];
    submitInfo.waitSemaphoreCount = 1;
    submitInfo.pWaitSemaphores = &imageAvailableSemaphores_[frame];
    submitInfo.pWaitDstStageMask = &waitStage;
    submitInfo.signalSemaphoreCount = 1;
    submitInfo.pSignalSemaphores = &renderFinished;
  }

  VR(vkQueueSubmit(graphicsQueue_, 1, &submitInfo, fence),
     "failed to submit draw command buffer!");

  if (windowed_) {
    VkPresentInfoKHR presentInfo {
      .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
      .waitSemaphoreCount = 1,
      .pWaitSemaphores = &renderFinished,
      .swapchainCount = 1,
      .pSwapchains = &swapchain_,
      .pImageIndices = &swapImageIndex,
    };
    VkResult pr = vkQueuePresentKHR(graphicsQueue_, &presentInfo);
    if (pr != VK_SUCCESS && pr != VK_SUBOPTIMAL_KHR &&
        pr != VK_ERROR_OUT_OF_DATE_KHR) {
      VR(pr, "vkQueuePresentKHR failed");
    }
  } else {
    // Offscreen readback needs the staging copy finished.
    vkDeviceWaitIdle(device_);
  }

  // Next record/submit uses the other slot (CPU can overlap with this GPU work).
  currentFrame_ = (currentFrame_ + 1) % kMaxFramesInFlight;
  ++frameCounter_;
  collectGarbage();

  // Presented content changed — any prior capture cache is stale.
  invalidateCaptureCache();
}

void Vulkan::readPixels(uint8_t *dst, size_t dstSize)
{
  size_t n = std::min(dstSize, static_cast<size_t>(stagingBufferSize_));
  memcpy(dst, stagingBufferMapped_, n);
}

void Vulkan::captureFrame(uint8_t *dst, size_t dstSize)
{
  assert(resolveImage_ != VK_NULL_HANDLE);
  assert(stagingBuffer_ != VK_NULL_HANDLE);
  assert(stagingBufferMapped_ != nullptr);

  // Main pass finalLayout leaves resolve as TRANSFER_SRC (also the present blit source).
  waitForAllFramesInFlight();

  VkCommandBuffer cmd = beginSingleTimeCommands();

  VkBufferImageCopy copyRegion{
    .bufferOffset = 0,
    .bufferRowLength = 0,
    .bufferImageHeight = 0,
    .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
    .imageOffset = {0, 0, 0},
    .imageExtent = {extent_.width, extent_.height, 1},
  };
  vkCmdCopyImageToBuffer(cmd, resolveImage_,
                         VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, stagingBuffer_, 1,
                         &copyRegion);

  VkBufferMemoryBarrier bufBarrier{
    .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
    .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
    .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
    .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
    .buffer = stagingBuffer_,
    .offset = 0,
    .size = VK_WHOLE_SIZE,
  };
  vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
                       VK_PIPELINE_STAGE_HOST_BIT, 0, 0, nullptr, 1,
                       &bufBarrier, 0, nullptr);

  endSingleTimeCommands(cmd);
  readPixels(dst, dstSize);

  // Refresh shared cache for subsequent region crops.
  const size_t need =
    static_cast<size_t>(extent_.width) * extent_.height * 4;
  if (dstSize >= need) {
    captureCache_.assign(dst, dst + need);
    captureCacheW_ = extent_.width;
    captureCacheH_ = extent_.height;
    captureCacheValid_ = true;
  } else {
    captureCacheValid_ = false;
  }
}

namespace {

struct PngWriteCtx {
  std::vector<uint8_t> *out = nullptr;
};

void pngWriteFunc(void *context, void *data, int size)
{
  auto *ctx = static_cast<PngWriteCtx *>(context);
  auto *bytes = static_cast<const uint8_t *>(data);
  ctx->out->insert(ctx->out->end(), bytes, bytes + size);
}

}  // namespace

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

bool Vulkan::capturePng(std::vector<uint8_t> &outPng, int x, int y, int w, int h,
                        int maxSide, int *outW, int *outH)
{
  const int fullW = static_cast<int>(extent_.width);
  const int fullH = static_cast<int>(extent_.height);
  if (fullW < 1 || fullH < 1) return false;

  if (w <= 0 || h <= 0) {
    x = 0;
    y = 0;
    w = fullW;
    h = fullH;
  }

  // Clamp to framebuffer.
  if (x < 0) {
    w += x;
    x = 0;
  }
  if (y < 0) {
    h += y;
    y = 0;
  }
  if (x >= fullW || y >= fullH) return false;
  w = std::min(w, fullW - x);
  h = std::min(h, fullH - y);
  if (w < 1 || h < 1) return false;

  // One GPU readback per settled frame; further crops are pure CPU.
  if (!captureCacheValid_ || captureCacheW_ != extent_.width ||
      captureCacheH_ != extent_.height ||
      captureCache_.size() !=
        static_cast<size_t>(fullW) * static_cast<size_t>(fullH) * 4) {
    captureCache_.resize(static_cast<size_t>(fullW) * static_cast<size_t>(fullH) *
                         4);
    captureFrame(captureCache_.data(), captureCache_.size());
  }

  std::vector<uint8_t> region(static_cast<size_t>(w) * static_cast<size_t>(h) * 4);
  for (int row = 0; row < h; ++row) {
    const uint8_t *src =
      captureCache_.data() + (static_cast<size_t>(y + row) * fullW + x) * 4;
    uint8_t *dst = region.data() + static_cast<size_t>(row) * w * 4;
    std::memcpy(dst, src, static_cast<size_t>(w) * 4);
  }

  // Optional box downsample: longer side ≤ maxSide (agent overview budget).
  int encW = w;
  int encH = h;
  const uint8_t *pngPixels = region.data();
  std::vector<uint8_t> scaled;
  if (maxSide > 0) {
    const int longSide = std::max(w, h);
    if (longSide > maxSide) {
      encW = std::max(1, (w * maxSide + longSide / 2) / longSide);
      encH = std::max(1, (h * maxSide + longSide / 2) / longSide);
      scaled.resize(static_cast<size_t>(encW) * static_cast<size_t>(encH) * 4);
      // Box filter: average each dest pixel's source footprint.
      for (int dy = 0; dy < encH; ++dy) {
        const int y0 = dy * h / encH;
        const int y1 = std::max(y0 + 1, (dy + 1) * h / encH);
        for (int dx = 0; dx < encW; ++dx) {
          const int x0 = dx * w / encW;
          const int x1 = std::max(x0 + 1, (dx + 1) * w / encW);
          uint32_t sum[4] = {0, 0, 0, 0};
          uint32_t count = 0;
          for (int sy = y0; sy < y1; ++sy) {
            const uint8_t *row =
              region.data() + (static_cast<size_t>(sy) * w + x0) * 4;
            for (int sx = x0; sx < x1; ++sx) {
              sum[0] += row[0];
              sum[1] += row[1];
              sum[2] += row[2];
              sum[3] += row[3];
              row += 4;
              ++count;
            }
          }
          uint8_t *out =
            scaled.data() + (static_cast<size_t>(dy) * encW + dx) * 4;
          if (count == 0) {
            out[0] = out[1] = out[2] = out[3] = 0;
          } else {
            out[0] = static_cast<uint8_t>(sum[0] / count);
            out[1] = static_cast<uint8_t>(sum[1] / count);
            out[2] = static_cast<uint8_t>(sum[2] / count);
            out[3] = static_cast<uint8_t>(sum[3] / count);
          }
        }
      }
      pngPixels = scaled.data();
    }
  }

  outPng.clear();
  PngWriteCtx ctx{&outPng};
  const int ok =
    stbi_write_png_to_func(pngWriteFunc, &ctx, encW, encH, 4, pngPixels, encW * 4);
  if (ok == 0 || outPng.empty()) return false;
  if (outW) *outW = encW;
  if (outH) *outH = encH;
  return true;
}

Shaders &Vulkan::getShaders()
{
  static Shaders shaders(*this);
  return shaders;
}

// Compute shader support implementations
VkDescriptorSetLayout Vulkan::createComputeDescriptorSetLayout()
{
  // Binding 0: Storage buffer for particles
  VkDescriptorSetLayoutBinding storageBufferBinding {
    .binding = 0,
    .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
    .descriptorCount = 1,
    .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
  };

  // Binding 1: Uniform buffer for simulation parameters
  VkDescriptorSetLayoutBinding uniformBufferBinding {
    .binding = 1,
    .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
    .descriptorCount = 1,
    .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
  };

  std::array<VkDescriptorSetLayoutBinding, 2> bindings = {
    storageBufferBinding, uniformBufferBinding
  };

  VkDescriptorSetLayoutCreateInfo layoutInfo {
    .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    .bindingCount = static_cast<uint32_t>(bindings.size()),
    .pBindings = bindings.data(),
  };

  VkDescriptorSetLayout descriptorSetLayout;
  VR(vkCreateDescriptorSetLayout(device_, &layoutInfo, nullptr, &descriptorSetLayout),
     "failed to create compute descriptor set layout!");

  return descriptorSetLayout;
}

VkPipelineLayout Vulkan::createComputePipelineLayout(VkDescriptorSetLayout descriptorSetLayout)
{
  VkPipelineLayoutCreateInfo pipelineLayoutInfo {
    .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    .setLayoutCount = 1,
    .pSetLayouts = &descriptorSetLayout,
  };

  VkPipelineLayout pipelineLayout;
  VR(vkCreatePipelineLayout(device_, &pipelineLayoutInfo, nullptr, &pipelineLayout),
     "failed to create compute pipeline layout!");

  return pipelineLayout;
}

VkPipeline Vulkan::createComputePipeline(VkPipelineLayout pipelineLayout, const std::string& shaderPath)
{
  auto computeShaderCode = utils::readFile(shaderPath);
  VkShaderModule computeShaderModule = createShaderModule(computeShaderCode);

  VkPipelineShaderStageCreateInfo computeShaderStageInfo {
    .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
    .stage = VK_SHADER_STAGE_COMPUTE_BIT,
    .module = computeShaderModule,
    .pName = "main",
  };

  VkComputePipelineCreateInfo pipelineInfo {
    .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
    .stage = computeShaderStageInfo,
    .layout = pipelineLayout,
  };

  VkPipeline computePipeline;
  VR(vkCreateComputePipelines(device_, VK_NULL_HANDLE, 1, &pipelineInfo, nullptr, &computePipeline),
     "failed to create compute pipeline!");

  vkDestroyShaderModule(device_, computeShaderModule, nullptr);

  return computePipeline;
}

VkDescriptorPool Vulkan::createComputeDescriptorPool(uint32_t maxSets)
{
  std::array<VkDescriptorPoolSize, 2> poolSizes = {{
    {
      .type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
      .descriptorCount = maxSets,
    },
    {
      .type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
      .descriptorCount = maxSets,
    }
  }};

  VkDescriptorPoolCreateInfo poolInfo {
    .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
    .maxSets = maxSets,
    .poolSizeCount = static_cast<uint32_t>(poolSizes.size()),
    .pPoolSizes = poolSizes.data(),
  };

  VkDescriptorPool descriptorPool;
  VR(vkCreateDescriptorPool(device_, &poolInfo, nullptr, &descriptorPool),
     "failed to create compute descriptor pool!");

  return descriptorPool;
}

VkDescriptorSet Vulkan::allocateComputeDescriptorSet(VkDescriptorPool pool, VkDescriptorSetLayout layout)
{
  VkDescriptorSetAllocateInfo allocInfo {
    .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
    .descriptorPool = pool,
    .descriptorSetCount = 1,
    .pSetLayouts = &layout,
  };

  VkDescriptorSet descriptorSet;
  VR(vkAllocateDescriptorSets(device_, &allocInfo, &descriptorSet),
     "failed to allocate compute descriptor set!");

  return descriptorSet;
}

void Vulkan::dispatchCompute(VkCommandBuffer commandBuffer, VkPipeline pipeline, VkPipelineLayout layout, VkDescriptorSet descriptorSet, uint32_t groupCountX, uint32_t groupCountY, uint32_t groupCountZ)
{
  vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
  vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &descriptorSet, 0, nullptr);
  vkCmdDispatch(commandBuffer, groupCountX, groupCountY, groupCountZ);
}

#ifdef INCLUDE_IMGUI
void Vulkan::initImGui()
{
  // Setup ImGui context
  IMGUI_CHECKVERSION();
  ImGui::CreateContext();
  ImGuiIO &io = ImGui::GetIO();
  io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard; // Enable Keyboard Controls
  // io.ConfigFlags |= ImGuiConfigFlags_NavEnableGamepad; // Enable Gamepad Controls

  // Setup ImGui style
  ImGui::StyleColorsDark();

  // No platform backend (imgui_impl_glfw) — this is headless. io.DisplaySize
  // and io.DeltaTime are set manually each frame instead (see
  // Application::renderDebugUI). Only the Vulkan render backend is needed.

  // Create Descriptor Pool for ImGui
  VkDescriptorPoolSize pool_sizes[] = {
    {VK_DESCRIPTOR_TYPE_SAMPLER, 1000},
    {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1000},
    {VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1000},
    {VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1000},
    {VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 1000},
    {VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 1000},
    {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1000},
    {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1000},
    {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, 1000},
    {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, 1000},
    {VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, 1000}
  };
  VkDescriptorPoolCreateInfo pool_info = {
    .sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
    .flags         = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
    .maxSets       = 1000 * IM_ARRAYSIZE(pool_sizes),
    .poolSizeCount = static_cast<uint32_t>(IM_ARRAYSIZE(pool_sizes)),
    .pPoolSizes    = pool_sizes,
  };
  VR(vkCreateDescriptorPool(device_, &pool_info, nullptr, &imguiDescriptorPool_),
     "failed to create ImGui descriptor pool!");

  ImGui_ImplVulkan_InitInfo initInfo = {
    .ApiVersion      = VK_API_VERSION_1_0,
    .Instance        = instance_,
    .PhysicalDevice  = physicalDevice_,
    .Device          = device_,
    .QueueFamily     = graphicsAndPresentationQueueFamilyIdx_,
    .Queue           = graphicsQueue_,
    .DescriptorPool  = imguiDescriptorPool_,
    .RenderPass      = renderPass_,
    // ImGui's Vulkan backend asserts MinImageCount >= 2 (it manages its own
    // double-buffered internal vertex/index buffers regardless of how many
    // real framebuffers we have) — we only have one real framebuffer, but
    // that's an implementation detail ImGui doesn't need to know about.
    .MinImageCount   = 2,
    .ImageCount      = 2,
    .MSAASamples     = getMSAASamples(),
    // Optional
    .PipelineCache   = VK_NULL_HANDLE,
    .Subpass         = 0,
    // (Optional) Allocation, Debugging
    .Allocator       = nullptr,
    .CheckVkResultFn = [](VkResult err) {
        if (err != VK_SUCCESS) {
          throw std::runtime_error("ImGui Vulkan error: " + std::to_string(err));
        }
      }
  };

  // Initialize ImGui for Vulkan
  ImGui_ImplVulkan_Init(&initInfo);

  // Upload Fonts
  // Command buffer is not needed, backend creates its own
  // to upload fonts
  ImGui_ImplVulkan_CreateFontsTexture();
  ImGui_ImplVulkan_DestroyFontsTexture();

  // GLFW platform backend is installed by Application after it registers
  // its own input callbacks (ImGui will chain onto those when
  // install_callbacks=true). See Application::initWithWindow.
  imguiInitialized_ = true;
}
#endif

void Vulkan::init(const char *applicationName, int width, int height)
{
  windowed_ = false;
  window_ = nullptr;
  extent_      = {static_cast<uint32_t>(width), static_cast<uint32_t>(height)};
  colorFormat_ = VK_FORMAT_R8G8B8A8_SRGB;
  deviceExtensions.clear();

  enableValidationLayers_ = utils::envFlag("CANVAS_VK_VALIDATION", false);

  createVkInstance(applicationName);
  setupDebugMessenger();

  selectSupportedGraphicsCard();
  createLogicalDevice();
  createCommandPool();
  createColorResources();
  createResolveResources();
  createStagingBuffer();
  createDepthResources();
  createRenderPass();
  createShadowResources();
  createShadowRenderPass();
  createShadowFramebuffer();
  createFramebuffer();
  createCommandBuffer();
  createSyncObjects();
#ifdef INCLUDE_IMGUI
  initImGui();
#endif
}

void Vulkan::initWithWindow(
  const char *applicationName, int width, int height, const char *title)
{
  windowed_ = true;
  deviceExtensions = {VK_KHR_SWAPCHAIN_EXTENSION_NAME};

  enableValidationLayers_ = utils::envFlag("CANVAS_VK_VALIDATION", false);

  if (!glfwInit()) {
    throw std::runtime_error("glfwInit failed");
  }
  glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
  glfwWindowHint(GLFW_RESIZABLE, GLFW_TRUE);
  // Tool-style canvas surface: no title bar / system menu / border chrome.
  // (Drag-to-move can be added later via a custom hit region.)
  // glfwWindowHint(GLFW_DECORATED, GLFW_FALSE);
  // Stay above the Gtk chrome window so the layout-slot overlay isn't buried.
  // glfwWindowHint(GLFW_FLOATING, GLFW_TRUE);
  // Prefer not stealing focus from the Swift chrome window on open.
  glfwWindowHint(GLFW_FOCUS_ON_SHOW, GLFW_FALSE);
  // Wayland: share app_id with the host if possible so the compositor may
  // group surfaces (does not hide from dock — see window_platform.cpp).
  // glfwWindowHintString(GLFW_WAYLAND_APP_ID, "com.example.HelloWorld");
  // X11: fixed WM_CLASS so the surface is identifiable / not a random title.
  // glfwWindowHintString(GLFW_X11_CLASS_NAME, "HelloWorldCanvas");
  // glfwWindowHintString(GLFW_X11_INSTANCE_NAME, "helloworld-canvas");

  window_ = glfwCreateWindow(width, height, title ? title : "Canvas", nullptr, nullptr);
  if (!window_) {
    glfwTerminate();
    throw std::runtime_error("glfwCreateWindow failed");
  }
  ownsWindow_ = true;

  extent_      = {static_cast<uint32_t>(width), static_cast<uint32_t>(height)};
  colorFormat_ = VK_FORMAT_R8G8B8A8_SRGB;

  createVkInstance(applicationName);
  setupDebugMessenger();
  createWindowSurface();
  selectSupportedGraphicsCard();
  createLogicalDevice();
  createSwapchain(); // may adjust extent_ to framebuffer size
  createCommandPool();
  createColorResources();
  createResolveResources();
  // Staging still created so readPixels remains available if needed, but
  // the present path does not copy into it every frame.
  createStagingBuffer();
  createDepthResources();
  createRenderPass();
  createShadowResources();
  createShadowRenderPass();
  createShadowFramebuffer();
  createFramebuffer();
  createCommandBuffer();
  createSyncObjects();
  createPresentSyncObjects();
#ifdef INCLUDE_IMGUI
  initImGui();
#endif
}

bool Vulkan::windowShouldClose() const
{
  return window_ && glfwWindowShouldClose(window_);
}

void Vulkan::requestClose()
{
  if (window_) glfwSetWindowShouldClose(window_, GLFW_TRUE);
}

#ifdef INCLUDE_IMGUI
void Vulkan::initImGuiGlfwBackend()
{
  if (windowed_ && window_ && imguiInitialized_) {
    ImGui_ImplGlfw_InitForVulkan(window_, true);
  }
}
#endif

void Vulkan::setWindowFrame(int x, int y, int width, int height)
{
  if (!windowed_ || !window_) return;
  if (width < 1) width = 1;
  if (height < 1) height = 1;

  glfwSetWindowPos(window_, x, y);

  int curW = 0, curH = 0;
  glfwGetWindowSize(window_, &curW, &curH);
  if (curW != width || curH != height) {
    glfwSetWindowSize(window_, width, height);
  }
  // Framebuffer size may lag a frame; ensureFramebufferSize() in the render
  // loop rebuilds swapchain/targets when it changes.
}

void Vulkan::setWindowVisible(bool visible)
{
  if (!windowed_ || !window_) return;
  if (visible) {
    glfwShowWindow(window_);
  } else {
    glfwHideWindow(window_);
  }
}

bool Vulkan::ensureFramebufferSize()
{
  if (!windowed_ || !window_) return false;

  int fbW = 0, fbH = 0;
  glfwGetFramebufferSize(window_, &fbW, &fbH);
  if (fbW < 1 || fbH < 1) return false;

  if (static_cast<uint32_t>(fbW) == extent_.width &&
      static_cast<uint32_t>(fbH) == extent_.height &&
      static_cast<uint32_t>(fbW) == swapchainExtent_.width &&
      static_cast<uint32_t>(fbH) == swapchainExtent_.height) {
    return false;
  }

  vkDeviceWaitIdle(device_);

  // Tear down size-dependent resources (keep pipelines/render pass).
  if (framebuffer_ != VK_NULL_HANDLE) {
    vkDestroyFramebuffer(device_, framebuffer_, nullptr);
    framebuffer_ = VK_NULL_HANDLE;
  }
  if (framebufferContinue_ != VK_NULL_HANDLE) {
    vkDestroyFramebuffer(device_, framebufferContinue_, nullptr);
    framebufferContinue_ = VK_NULL_HANDLE;
  }
  cleanupSwapchain();

  if (stagingBufferMapped_) {
    if (stagingBufferAlloc_ != VK_NULL_HANDLE) unmapBuffer(stagingBufferAlloc_);
    stagingBufferMapped_ = nullptr;
  }
  destroyBuffer(stagingBuffer_, stagingBufferAlloc_);

  if (colorImageView_ != VK_NULL_HANDLE) {
    vkDestroyImageView(device_, colorImageView_, nullptr);
    colorImageView_ = VK_NULL_HANDLE;
  }
  destroyImage(colorImage_, colorImageAlloc_);
  if (resolveImageView_ != VK_NULL_HANDLE) {
    vkDestroyImageView(device_, resolveImageView_, nullptr);
    resolveImageView_ = VK_NULL_HANDLE;
  }
  destroyImage(resolveImage_, resolveImageAlloc_);
  if (depthImageView_ != VK_NULL_HANDLE) {
    vkDestroyImageView(device_, depthImageView_, nullptr);
    depthImageView_ = VK_NULL_HANDLE;
  }
  destroyImage(depthImage_, depthImageAlloc_);

  extent_ = {static_cast<uint32_t>(fbW), static_cast<uint32_t>(fbH)};

  createSwapchain();
  createColorResources();
  createResolveResources();
  createStagingBuffer();
  createDepthResources();
  createFramebuffer();

  std::cout << "Framebuffer resized to " << extent_.width << "x" << extent_.height << '\n';
  return true;
}
