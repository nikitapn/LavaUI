#include <set>
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>
#include <algorithm>
#include <filesystem>

// Prefer a widely-packaged backend: many distros ship
// libboost_stacktrace_basic but not libbacktrace.
#define BOOST_STACKTRACE_DYN_LINK
#if !defined(BOOST_STACKTRACE_USE_BACKTRACE) \
    && !defined(BOOST_STACKTRACE_USE_ADDR2LINE) \
    && !defined(BOOST_STACKTRACE_USE_NOOP)
#define BOOST_STACKTRACE_USE_BASIC
#endif
#include <boost/stacktrace.hpp>
#include <boost/stacktrace/stacktrace.hpp>

#include <vulkan/vulkan_core.h>

// Only for `matchesExportDrmDevice`: a DRM node is identified by its device
// number, and `fstat` is the only thing that knows one from a descriptor.
#include <sys/stat.h>
#include <sys/sysmacros.h>

#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>

#ifdef INCLUDE_IMGUI
# include "imgui_impl_vulkan.h"
# include "imgui_impl_glfw.h"
#endif

#include "util/util.hpp"
#include "render/shaders.hpp"
#include "render/render_device.hpp"
#include "render/render_window.hpp"
#include "render/text_renderer.hpp"
#include "render/texture_manager.hpp"
#include "window/window_platform.hpp"

#define DEBUG_PRINT 0

bool g_ValidationFromResult = false;

// Filled before createLogicalDevice: empty for offscreen, swapchain for windowed.
std::vector<const char *> deviceExtensions = {};

VKAPI_ATTR VkBool32 VKAPI_CALL RenderDevice::debugCallback(
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

VkResult RenderDevice::createDebugUtilsMessengerEXT(
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

void RenderDevice::destroyDebugUtilsMessengerEXT(
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

VkDebugUtilsMessengerCreateInfoEXT RenderDevice::createDebugMessengerInfo()
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

void RenderDevice::setupDebugMessenger()
{
  if (!enableValidationLayers_) return;

  auto createInfo = createDebugMessengerInfo();
  VR(createDebugUtilsMessengerEXT(
       instance_, &createInfo, nullptr, &debugMessenger_),
     "failed to set up debug messenger!");
}

bool RenderDevice::checkValidationLayerSupport(
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

void RenderDevice::createVkInstance(
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
    // Descriptor indexing is core in 1.2 and the quad renderer relies on its
    // non-uniform sampled-image arrays. Export also needs the group of memory
    // and format features promoted by the same version.
    .apiVersion = VK_API_VERSION_1_2,
  };

  VkInstanceCreateInfo createInfo {
    .sType            = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
    .pApplicationInfo = &appInfo,
  };

  auto instanceExtensions = std::vector<const char *>();

  if (presentCapable_) {
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

bool RenderDevice::checkExtensionsSupport(
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

bool RenderDevice::matchesExportDrmDevice(VkPhysicalDevice device) const
{
  struct stat st {};
  if (fstat(exportDrmFd_, &st) != 0) return false;
  const unsigned wantMajor = major(st.st_rdev);
  const unsigned wantMinor = minor(st.st_rdev);

  VkPhysicalDeviceDrmPropertiesEXT drm {
    .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT,
  };
  VkPhysicalDeviceProperties2 props {
    .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
    .pNext = &drm,
  };
  vkGetPhysicalDeviceProperties2(device, &props);

  // Either node names the same GPU. Which one arrives depends on the caller's
  // backend — wlroots hands out a render node or a primary one — and a device
  // that reports neither simply does not match, which is the right answer for
  // a driver without `VK_EXT_physical_device_drm`.
  if (drm.hasRender && static_cast<unsigned>(drm.renderMajor) == wantMajor &&
      static_cast<unsigned>(drm.renderMinor) == wantMinor) {
    return true;
  }
  return drm.hasPrimary &&
         static_cast<unsigned>(drm.primaryMajor) == wantMajor &&
         static_cast<unsigned>(drm.primaryMinor) == wantMinor;
}

void RenderDevice::selectSupportedGraphicsCard()
{
  uint32_t deviceCount = 0;
  vkEnumeratePhysicalDevices(instance_, &deviceCount, nullptr);

  if (deviceCount == 0) {
    throw std::runtime_error("failed to find GPUs with Vulkan support!");
  }

  std::vector<VkPhysicalDevice> devices(deviceCount);
  vkEnumeratePhysicalDevices(instance_, &deviceCount, devices.data());

  auto isDeviceSuitable = [this](VkPhysicalDevice device) {
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

    // Exporting overrides the preference entirely. The GPU is not ours to
    // pick: it has to be the one the consumer already renders on, or the
    // buffer we hand over is one it cannot read. "Discrete, with a geometry
    // shader" is a good default and the wrong question here — on a hybrid
    // laptop it reliably chooses the *other* card.
    if (exportDrmFd_ >= 0) {
      return checkDeviceExtensionSupport() && matchesExportDrmDevice(device);
    }

    VkPhysicalDeviceProperties deviceProperties;
    vkGetPhysicalDeviceProperties(device, &deviceProperties);

    if (deviceProperties.apiVersion < VK_API_VERSION_1_2) return false;

    VkPhysicalDeviceVulkan12Features v12{
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
    };
    VkPhysicalDeviceFeatures2 features2{
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
      .pNext = &v12,
    };
    vkGetPhysicalDeviceFeatures2(device, &features2);
    if (!v12.runtimeDescriptorArray || !v12.descriptorBindingPartiallyBound ||
        !v12.shaderSampledImageArrayNonUniformIndexing) {
      return false;
    }

    std::cout << std::format("Limits:\n\tmaxPushConstantsSize: {}\n",
                deviceProperties.limits.maxPushConstantsSize);

    VkPhysicalDeviceFeatures deviceFeatures;
    vkGetPhysicalDeviceFeatures(device, &deviceFeatures);

    return deviceProperties.deviceType ==
             VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU &&
           deviceFeatures.geometryShader && checkDeviceExtensionSupport();
  };

  // The highest count the device supports for colour *and* depth, and then no
  // higher than `sampleCap_`.
  //
  // The cap is the whole point of this function now. Taking the device maximum
  // was free-looking and is not: every window allocates a multisampled colour
  // attachment and a multisampled depth attachment, so the count multiplies the
  // two largest things in `gpuLedger()`. On an RTX 3060 the maximum is 8, which
  // made a single 1920×1080 surface 128 MiB of attachments before anything was
  // drawn into it — and a compositor has one of those per client window, plus
  // one per title bar, shadow and frost surface.
  auto usableSampleCount =
    [this](const VkPhysicalDeviceProperties &physicalDeviceProperties)
    -> VkSampleCountFlagBits {
    const VkSampleCountFlags counts =
      physicalDeviceProperties.limits.framebufferColorSampleCounts &
      physicalDeviceProperties.limits.framebufferDepthSampleCounts;
    for (const VkSampleCountFlagBits candidate :
         {VK_SAMPLE_COUNT_64_BIT, VK_SAMPLE_COUNT_32_BIT,
          VK_SAMPLE_COUNT_16_BIT, VK_SAMPLE_COUNT_8_BIT,
          VK_SAMPLE_COUNT_4_BIT, VK_SAMPLE_COUNT_2_BIT}) {
      if (static_cast<uint32_t>(candidate) > sampleCap_) continue;
      if (counts & candidate) return candidate;
    }
    return VK_SAMPLE_COUNT_1_BIT;
  };

  if (auto found = std::ranges::find_if(devices, isDeviceSuitable);
      found != devices.end()) {
    physicalDevice_ = *found;
    vkGetPhysicalDeviceProperties(physicalDevice_, &physicalDeviceProperties_);
    msaaSamples_ = usableSampleCount(physicalDeviceProperties_);
#if DEBUG_PRINT
    std::cout << physicalDeviceProperties_.deviceName
              << "\n\t MSAA Samples: " << msaaSamples_ << std::endl;
#endif
  } else if (exportDrmFd_ >= 0) {
    // Worth naming precisely rather than falling back to the other GPU. On a
    // hybrid laptop this means the card the consumer renders on has no Vulkan
    // driver installed, and rendering on the one that does would produce a
    // buffer nothing on the other side can import.
    throw std::runtime_error(
      std::format("No Vulkan device for the GPU behind the given DRM node "
                  "({} Vulkan device(s) present, none matching)",
                  devices.size()));
  } else {
    throw std::runtime_error("No suitable physical device found!");
  }

  vkGetPhysicalDeviceMemoryProperties(physicalDevice_,
                                      &deviceMemoryProperties_);
}

void RenderDevice::createLogicalDevice()
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
    if (presentCapable_ && probeSurface_ != VK_NULL_HANDLE) {
      VkBool32 presentSupport = VK_FALSE;
      vkGetPhysicalDeviceSurfaceSupportKHR(
        physicalDevice_, i, probeSurface_, &presentSupport);
      if (!presentSupport) continue;
    }
    graphicsAndPresentationQueueFamilyIdx_ = i;
    break;
  }

  if (graphicsAndPresentationQueueFamilyIdx_ == std::numeric_limits<u32>::max()) {
    throw std::runtime_error("No suitable queue was found");
  }

  const uint32_t queueCount = std::max(1u, properties[
    graphicsAndPresentationQueueFamilyIdx_].queueCount);
  std::vector<float> queuePriorities(queueCount, 1.0f);
  VkDeviceQueueCreateInfo queueCreateInfo {
    .sType            = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
    .queueFamilyIndex = graphicsAndPresentationQueueFamilyIdx_,
    .queueCount       = static_cast<u32>(queuePriorities.size()),
    .pQueuePriorities = queuePriorities.data(),
  };

  VkPhysicalDeviceFeatures deviceFeatures {};
  VkPhysicalDeviceFeatures supportedFeatures {};
  vkGetPhysicalDeviceFeatures(physicalDevice_, &supportedFeatures);
  if (supportedFeatures.samplerAnisotropy) {
    deviceFeatures.samplerAnisotropy = VK_TRUE;
    samplerAnisotropy_ = true;
  }

  VkPhysicalDeviceVulkan12Features descriptorIndexing{
    .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
  };
  descriptorIndexing.shaderSampledImageArrayNonUniformIndexing = VK_TRUE;
  descriptorIndexing.descriptorBindingPartiallyBound = VK_TRUE;
  descriptorIndexing.runtimeDescriptorArray = VK_TRUE;

  // Optional, windowed only: VK_PRESENT_MODE_FIFO_LATEST_READY is MAILBOX's
  // behaviour — present the most recently finished image at the next refresh
  // and discard the ones it overtook — so it is non-tearing without letting
  // latency build up behind a queue. On surfaces that offer it but not MAILBOX
  // (this machine is one) it is the mode we actually want.
  //
  // Requested here rather than in the suitability check on purpose: adding it
  // to `deviceExtensions` up front would make a GPU that lacks it fail to
  // qualify as a device at all.
  if (presentCapable_) {
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

  // Also optional, and for the same reason: without it the handover to another
  // driver falls back to a CPU wait, which is slower but not wrong. Requiring
  // it would disqualify a GPU over a performance property.
  if (exportDrmFd_ >= 0) {
    uint32_t extCount = 0;
    vkEnumerateDeviceExtensionProperties(physicalDevice_, nullptr, &extCount,
                                         nullptr);
    std::vector<VkExtensionProperties> available(extCount);
    vkEnumerateDeviceExtensionProperties(physicalDevice_, nullptr, &extCount,
                                         available.data());
    const bool haveExtension = std::ranges::any_of(
      available, [](const VkExtensionProperties &ext) {
        return std::strcmp(ext.extensionName,
                           VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME) == 0;
      });

    // Having the extension is not the same as supporting the handle type.
    VkPhysicalDeviceExternalSemaphoreInfo semaphoreInfo {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO,
      .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
    };
    VkExternalSemaphoreProperties semaphoreProps {
      .sType = VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES,
    };
    vkGetPhysicalDeviceExternalSemaphoreProperties(
      physicalDevice_, &semaphoreInfo, &semaphoreProps);

    exportSyncFd_ = haveExtension &&
                    (semaphoreProps.externalSemaphoreFeatures &
                     VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT) != 0;
    if (exportSyncFd_) {
      deviceExtensions.push_back(VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME);
    }
  }

  // Must outlive vkCreateDevice: it is referenced through pNext.
  VkPhysicalDevicePresentModeFifoLatestReadyFeaturesKHR fifoLatestReady {
    .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_MODE_FIFO_LATEST_READY_FEATURES_KHR,
    .pNext = &descriptorIndexing,
    .presentModeFifoLatestReady = VK_TRUE,
  };

  VkDeviceCreateInfo deviceCreateInfo = {
    .sType                   = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
    .pNext                   = fifoLatestReadyEnabled_
                                 ? static_cast<void *>(&fifoLatestReady)
                                 : static_cast<void *>(&descriptorIndexing),
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
  graphicsQueues_.reserve(queueCount);
  for (uint32_t i = 0; i < queueCount; ++i) {
    auto slot = std::make_unique<QueueSlot>();
    vkGetDeviceQueue(device_, graphicsAndPresentationQueueFamilyIdx_, i,
                     &slot->queue);
    graphicsQueues_.push_back(std::move(slot));
  }

  if (exportDrmFd_ >= 0) {
    getMemoryFd_ = reinterpret_cast<PFN_vkGetMemoryFdKHR>(
      vkGetDeviceProcAddr(device_, "vkGetMemoryFdKHR"));
    getMemoryFdProperties_ = reinterpret_cast<PFN_vkGetMemoryFdPropertiesKHR>(
      vkGetDeviceProcAddr(device_, "vkGetMemoryFdPropertiesKHR"));
    getModifierProps_ =
      reinterpret_cast<PFN_vkGetImageDrmFormatModifierPropertiesEXT>(
        vkGetDeviceProcAddr(device_,
                            "vkGetImageDrmFormatModifierPropertiesEXT"));
    if (!getMemoryFd_ || !getModifierProps_) {
      throw std::runtime_error(
        "device claims the dmabuf export extensions but has no entry points");
    }
    if (exportSyncFd_) {
      getSemaphoreFd_ = reinterpret_cast<PFN_vkGetSemaphoreFdKHR>(
        vkGetDeviceProcAddr(device_, "vkGetSemaphoreFdKHR"));
      exportSyncFd_ = getSemaphoreFd_ != nullptr;
    }
    std::cout << "dmabuf export ready on '"
              << physicalDeviceProperties_.deviceName << "'; handover is "
              << (exportSyncFd_ ? "fenced (sync_file)"
                                : "a CPU wait (no sync_file export)")
              << '\n';
  }

  createAllocator();
}

RenderDevice::QueueLease RenderDevice::leaseGraphicsQueue()
{
  assert(!graphicsQueues_.empty());
  QueueSlot &slot = *graphicsQueues_[nextQueue_.fetch_add(1) % graphicsQueues_.size()];
  return {slot.queue, &slot.mutex};
}

void RenderDevice::createAllocator()
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

void RenderDevice::destroyAllocator()
{
  if (allocator_ == VK_NULL_HANDLE) return;
  // Callers must destroy every buffer/image first; VMA will assert in debug
  // if anything is still allocated when the allocator is destroyed.
  vmaDestroyAllocator(allocator_);
  allocator_ = VK_NULL_HANDLE;
}

// Find a memory in `memoryTypeBitsRequirement` that includes all of
// `requiredProperties`
uint32_t RenderDevice::findMemoryProperties(

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

void RenderDevice::createBuffer(
  VkDeviceSize          size,
  VkBufferUsageFlags    usage,
  VkMemoryPropertyFlags properties,
  VkBuffer             &buffer,
  VmaAllocation        &allocation,
  const canvas::GpuTag &tag)
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
  VmaAllocationInfo info{};
  VR(vmaCreateBuffer(allocator_, &bufferInfo, &allocInfo, &buffer, &allocation,
                     &info),
     "failed to create buffer (VMA)!");
  // `info.size` rather than `size`: what the allocation actually occupies,
  // which is what a memory report is asking about.
  gpuLedger_.addBuffer(allocation, info.size, tag, usage);
}

void RenderDevice::destroyBuffer(VkBuffer &buffer, VmaAllocation &allocation)
{
  if (buffer == VK_NULL_HANDLE) {
    allocation = VK_NULL_HANDLE;
    return;
  }
  assert(allocation != VK_NULL_HANDLE);
  gpuLedger_.remove(allocation);
  vmaDestroyBuffer(allocator_, buffer, allocation);
  buffer = VK_NULL_HANDLE;
  allocation = VK_NULL_HANDLE;
}

void *RenderDevice::mapBuffer(VmaAllocation allocation)
{
  assert(allocation != VK_NULL_HANDLE);
  void *ptr = nullptr;
  VR(vmaMapMemory(allocator_, allocation, &ptr), "vmaMapMemory failed");
  return ptr;
}

void RenderDevice::unmapBuffer(VmaAllocation allocation)
{
  if (allocation == VK_NULL_HANDLE) return;
  vmaUnmapMemory(allocator_, allocation);
}

vk::Buffer RenderDevice::createImmutableBuffer(
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

vk::Buffer RenderDevice::createImmutableVertexBuffer(
  const void *bufferData, VkDeviceSize bufferSize)
{
  return createImmutableBuffer(
    bufferData, bufferSize, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
}

vk::Buffer RenderDevice::createImmutableIndexBuffer(
  const void *bufferData, VkDeviceSize bufferSize)
{
  return createImmutableBuffer(
    bufferData, bufferSize, VK_BUFFER_USAGE_INDEX_BUFFER_BIT);
}

vk::Buffer RenderDevice::createImmutableUniformBuffer(
  const void *bufferData, VkDeviceSize bufferSize)
{
  return createImmutableBuffer(
    bufferData, bufferSize, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
}

void RenderDevice::copyBuffer(
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

std::tuple<VkBuffer, VmaAllocation> RenderDevice::createUniformBuffer(
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

void RenderDevice::createImage(
  uint32_t              width,
  uint32_t              height,
  uint32_t              mipLevels,
  VkSampleCountFlagBits samples,
  VkFormat              format,
  VkImageTiling         tiling,
  VkImageUsageFlags     usage,
  VkMemoryPropertyFlags properties,
  VkImage              &image,
  VmaAllocation        &allocation,
  const canvas::GpuTag &tag)
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
  VmaAllocationInfo info{};
  VR(vmaCreateImage(allocator_, &imageInfo, &allocInfo, &image, &allocation,
                    &info),
     "failed to create image (VMA)!");
  // The size VMA actually reserved, which for a multisampled attachment is the
  // one that matters: `width * height * 4` understates it by the sample count.
  gpuLedger_.addImage(allocation, info.size, tag, width, height,
                      static_cast<uint32_t>(samples), mipLevels,
                      static_cast<uint32_t>(format),
                      static_cast<uint32_t>(usage));
}

void RenderDevice::destroyImageDeferred(VkImage &image, VmaAllocation &allocation,
                                  VkImageView &view)
{
  std::lock_guard lock(sharedStateMutex_);
  if (image == VK_NULL_HANDLE && view == VK_NULL_HANDLE) return;
  // The index the *next* submission will take. Every submission from here on
  // is recorded after these handles were nulled, so none of them can name the
  // resource; only submissions already claimed might.
  trash_.push_back({image, allocation, view, nextSubmission_.load()});
  // Still in the ledger, and still in memory: this is queued, not freed. A
  // report that dropped it here would claim less VRAM in use than the driver
  // sees, which is the opposite of the point.
  gpuLedger_.markRetiring(allocation);
  image      = VK_NULL_HANDLE;
  allocation = VK_NULL_HANDLE;
  view       = VK_NULL_HANDLE;
}

uint64_t RenderDevice::collectGarbage()
{
  // Exclusive: `oldestUnretiredSubmission()` below calls `vkGetFenceStatus` on
  // every window's fences, and a window submitting on its own thread holds
  // those exclusively. This is the call the validation layer catches first.
  std::unique_lock frameLock(frameMutex_);
  std::lock_guard lock(sharedStateMutex_);

  // The oldest submission still running anywhere. A resource queued before
  // that point may still be named by it; anything queued at or after it is
  // provably unreferenced.
  //
  // This has to span every window, and that is the whole reason the retire
  // clock is a submission index rather than a frame count. With one window
  // "three frames have passed" was a fine proxy for "the GPU is done with it".
  // With two it is not: window A presenting twice says nothing about whether
  // window B's frame — which sampled the same atlas page — has retired, and
  // freeing on A's count alone is a use-after-free that surfaces as a crash in
  // whatever unrelated draw happens to reuse the memory.
  uint64_t safe = UINT64_MAX;
  for (const RenderWindow *w : windows_) {
    safe = std::min(safe, w->oldestUnretiredSubmission());
  }

  if (trash_.empty()) return safe;

  size_t keep = 0;
  for (size_t i = 0; i < trash_.size(); ++i) {
    auto &t = trash_[i];
    if (t.queuedAt > safe) {
      trash_[keep++] = t;
      continue;
    }
    if (t.view != VK_NULL_HANDLE) {
      vkDestroyImageView(device_, t.view, nullptr);
    }
    if (t.image != VK_NULL_HANDLE) {
      gpuLedger_.remove(t.allocation);
      vmaDestroyImage(allocator_, t.image, t.allocation);
    }
  }
  trash_.resize(keep);
  return safe;
}

void RenderDevice::destroyImage(VkImage &image, VmaAllocation &allocation)
{
  if (image == VK_NULL_HANDLE) {
    allocation = VK_NULL_HANDLE;
    return;
  }
  assert(allocation != VK_NULL_HANDLE);
  gpuLedger_.remove(allocation);
  vmaDestroyImage(allocator_, image, allocation);
  image = VK_NULL_HANDLE;
  allocation = VK_NULL_HANDLE;
}

VkImageView RenderDevice::createImageView(
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

VkSampler RenderDevice::createTextureSampler()
{
  // maxLod used to be 0, so even a mipped image never left level 0. Scene3D
  // cards sit at ~64° — that is a large dFdx and looks like nearest-neighbour
  // without a mip chain. 1-level images (atlas pages, glyphs) still clamp to
  // the one level they have.
  VkSamplerCreateInfo samplerInfo {
    .sType                   = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
    .magFilter               = VK_FILTER_LINEAR,
    .minFilter               = VK_FILTER_LINEAR,
    .mipmapMode              = VK_SAMPLER_MIPMAP_MODE_LINEAR,
    .addressModeU            = VK_SAMPLER_ADDRESS_MODE_REPEAT,
    .addressModeV            = VK_SAMPLER_ADDRESS_MODE_REPEAT,
    .addressModeW            = VK_SAMPLER_ADDRESS_MODE_REPEAT,
    .mipLodBias              = 0.0f,
    .anisotropyEnable        = samplerAnisotropy_ ? VK_TRUE : VK_FALSE,
    .maxAnisotropy           = samplerAnisotropy_
                                 ? physicalDeviceProperties_.limits.maxSamplerAnisotropy
                                 : 1.0f,
    .compareEnable           = VK_FALSE,
    .compareOp               = VK_COMPARE_OP_ALWAYS,
    .minLod                  = 0.0f,
    .maxLod                  = VK_LOD_CLAMP_NONE,
    .borderColor             = VK_BORDER_COLOR_INT_OPAQUE_BLACK,
    .unnormalizedCoordinates = VK_FALSE,
  };

  VkSampler sampler;
  VR(vkCreateSampler(device_, &samplerInfo, nullptr, &sampler),
     "failed to create texture sampler!");

  return sampler;
}

VkFormat RenderDevice::findSupportedFormat(const std::vector<VkFormat>& candidates, VkImageTiling tiling, VkFormatFeatureFlags features)
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

VkFormat RenderDevice::findDepthFormat()
{
  return findSupportedFormat(
    {VK_FORMAT_D32_SFLOAT, VK_FORMAT_D32_SFLOAT_S8_UINT, VK_FORMAT_D24_UNORM_S8_UINT},
    VK_IMAGE_TILING_OPTIMAL,
    VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT
  );
}

bool RenderDevice::hasStencilComponent(VkFormat format)
{
  return format == VK_FORMAT_D32_SFLOAT_S8_UINT || format == VK_FORMAT_D24_UNORM_S8_UINT;
}

void RenderDevice::createRenderPass()
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

void RenderDevice::createCommandPool()
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

VkShaderModule RenderDevice::createShaderModule(
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

VkCommandBuffer RenderDevice::beginSingleTimeCommands()
{
  assert(device_ != VK_NULL_HANDLE && "device not initialized");
  assert(commandPool_ != VK_NULL_HANDLE && "command pool not initialized");

  // Released by the matching `endSingleTimeCommands`, so the allocate, the
  // recording and the free are one critical section on `commandPool_`. See
  // `singleTimeMutex_`. Pairs must not nest — none do; every caller is a
  // straight-line begin..end.
  //
  // Locked bare rather than through a `unique_lock` member. A member would be
  // shared mutable state between the two threads this exists to separate:
  // `unique_lock::unlock()` releases the mutex *before* clearing its own
  // ownership flag, so the next thread in acquires and assigns to the same
  // member while the leaving thread is still writing it. The losing write
  // clears ownership of a held mutex and nothing ever unlocks it again — the
  // renderer stops answering RPCs and every client times out.
  singleTimeMutex_.lock();

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

void RenderDevice::endSingleTimeCommands(
  VkCommandBuffer commandBuffer)
{
  vkEndCommandBuffer(commandBuffer);

  VkSubmitInfo submitInfo {
    .sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO,
    .commandBufferCount = 1,
    .pCommandBuffers    = &commandBuffer,
  };

  {
    // Queue zero may also be leased to a window. Host access to one VkQueue
    // requires external synchronization even when other queues run in parallel.
    std::lock_guard queueLock(graphicsQueues_.front()->mutex);
    VR(vkQueueSubmit(graphicsQueue_, 1, &submitInfo, VK_NULL_HANDLE),
       "failed to submit single time command buffer!");

    // Wait until the command buffer has finished executing
    vkQueueWaitIdle(graphicsQueue_);
  }
  vkFreeCommandBuffers(device_, commandPool_, 1, &commandBuffer);
  // Balances the acquire in `beginSingleTimeCommands`.
  singleTimeMutex_.unlock();
}

void RenderDevice::transitionImageLayout(
  VkImage       image,
  VkFormat      format,
  VkImageLayout oldLayout,
  VkImageLayout newLayout,
  uint32_t      mipLevels)
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
        .levelCount     = std::max(1u, mipLevels),
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
  } else if (oldLayout == VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL &&
             newLayout == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
    // The way back from a readback. `readImagePixels` borrows a live image —
    // an atlas page — copies it out and has to leave it exactly as it found
    // it; without this the restore throws and the caller has read the pixels
    // of an image it then left in the wrong layout.
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;

    sourceStage      = VK_PIPELINE_STAGE_TRANSFER_BIT;
    destinationStage = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
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

void RenderDevice::setSharedDepth(bool shared)
{
  // The escape hatch is a "0", not a "1": sharing is the thing a caller opts
  // into in code, having promised it does not render two windows at once, and
  // the variable exists to take that promise back for a comparison.
  if (const char *override = std::getenv("LAVA_SHARED_DEPTH")) {
    if (std::atoi(override) == 0) shared = false;
  }
  sharedDepth_ = shared;
}

VkImageView RenderDevice::sharedDepthView(uint32_t width, uint32_t height)
{
  if (!sharedDepth_) return VK_NULL_HANDLE;

  // Rounded up, and grow-only. A drag resizes a window every frame, and an
  // image that tracked the exact maximum would be reallocated — and every
  // framebuffer in the process rebuilt — on the way through each pixel.
  constexpr uint32_t kStep = 256;
  const auto stepped = [](uint32_t size) {
    return ((std::max(size, 1u) + kStep - 1) / kStep) * kStep;
  };
  const uint32_t wanted[2] = {
    std::max(stepped(width), sharedDepthExtent_.width),
    std::max(stepped(height), sharedDepthExtent_.height),
  };
  if (sharedDepthView_ != VK_NULL_HANDLE
      && wanted[0] == sharedDepthExtent_.width
      && wanted[1] == sharedDepthExtent_.height) {
    return sharedDepthView_;
  }

  // Every window may be mid-flight against the image about to be replaced.
  // This is the one place that needs the wait, and it is a resize — not a
  // frame — so paying for it here costs nothing per frame.
  waitForAllFramesInFlight();

  if (sharedDepthView_ != VK_NULL_HANDLE) {
    vkDestroyImageView(device_, sharedDepthView_, nullptr);
    sharedDepthView_ = VK_NULL_HANDLE;
  }
  destroyImage(sharedDepthImage_, sharedDepthAlloc_);

  const VkFormat depthFormat = findDepthFormat();
  createImage(wanted[0], wanted[1], 1, msaaSamples_, depthFormat,
              VK_IMAGE_TILING_OPTIMAL,
              VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
              VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, sharedDepthImage_,
              sharedDepthAlloc_,
              canvas::GpuTag{canvas::GpuCategory::WindowDepth, 0,
                             "shared by every window"});
  sharedDepthView_ = createImageView(sharedDepthImage_, depthFormat,
                                     VK_IMAGE_ASPECT_DEPTH_BIT, 1);
  transitionImageLayout(sharedDepthImage_, depthFormat,
                        VK_IMAGE_LAYOUT_UNDEFINED,
                        VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL);
  sharedDepthExtent_ = {wanted[0], wanted[1]};

  // Everyone else is now holding a framebuffer built against a destroyed view.
  // The window that asked is not in the list yet (it is being constructed) or
  // is about to build its own framebuffer from the value we return, so it is
  // excluded either way by rebuilding *before* returning.
  for (RenderWindow *window : windows_) window->rebuildFramebuffer();

  return sharedDepthView_;
}

void RenderDevice::setSampleCap(uint32_t samples)
{
  // `LAVA_MSAA` wins, so a session can be compared at 8, 4, 2 and 1 without
  // rebuilding or editing a config file — which is how the default came to be
  // 4. Read here rather than in `init` so the log line below tells the truth
  // about where the number came from.
  if (const char *override = std::getenv("LAVA_MSAA")) {
    const int wanted = std::atoi(override);
    if (wanted > 0) samples = static_cast<uint32_t>(wanted);
  }
  if (samples == 0) return;  // "leave the default"

  // Down to a power of two: Vulkan's sample counts are bit flags, and a cap of
  // 3 must mean 2 rather than nothing.
  uint32_t capped = 1;
  while (capped * 2 <= samples && capped < 64) capped *= 2;
  sampleCap_ = capped;
}

RenderDevice::GpuMemoryTotals RenderDevice::gpuMemoryTotals() const
{
  GpuMemoryTotals totals;
  totals.deviceName = physicalDeviceProperties_.deviceName;
  totals.samples    = static_cast<uint32_t>(msaaSamples_);
  totals.maxSamples = static_cast<uint32_t>(
    physicalDeviceProperties_.limits.framebufferColorSampleCounts &
    physicalDeviceProperties_.limits.framebufferDepthSampleCounts);
  if (allocator_ == VK_NULL_HANDLE) return totals;

  VmaTotalStatistics stats{};
  vmaCalculateStatistics(allocator_, &stats);
  totals.vmaAllocatedBytes = stats.total.statistics.allocationBytes;
  totals.vmaBlockBytes     = stats.total.statistics.blockBytes;

  // Only the device-local heaps. A discrete GPU also exposes host heaps, and
  // adding those to a VRAM figure is how a report ends up disagreeing with
  // `nvidia-smi` for a reason nobody can find.
  VmaBudget budgets[VK_MAX_MEMORY_HEAPS]{};
  vmaGetHeapBudgets(allocator_, budgets);
  for (uint32_t i = 0; i < deviceMemoryProperties_.memoryHeapCount; ++i) {
    if ((deviceMemoryProperties_.memoryHeaps[i].flags &
         VK_MEMORY_HEAP_DEVICE_LOCAL_BIT) == 0) {
      continue;
    }
    totals.heapUsageBytes  += budgets[i].usage;
    totals.heapBudgetBytes += budgets[i].budget;
    totals.heapSizeBytes   += deviceMemoryProperties_.memoryHeaps[i].size;
  }
  return totals;
}

bool RenderDevice::readImagePixels(VkImage image, uint32_t width,
                                   uint32_t height, VkFormat format,
                                   VkImageLayout currentLayout,
                                   std::vector<uint8_t> &outRgba)
{
  if (image == VK_NULL_HANDLE || width == 0 || height == 0) return false;

  uint32_t sourceBytesPerPixel = 0;
  switch (format) {
  case VK_FORMAT_R8_UNORM:      sourceBytesPerPixel = 1; break;
  case VK_FORMAT_R8G8B8A8_UNORM:
  case VK_FORMAT_R8G8B8A8_SRGB:
  case VK_FORMAT_B8G8R8A8_UNORM:
  case VK_FORMAT_B8G8R8A8_SRGB: sourceBytesPerPixel = 4; break;
  default:
    // Depth, compressed and multisampled formats are not pictures, and a
    // report that showed one would be showing noise.
    std::cerr << "readImagePixels: unsupported format " << format << '\n';
    return false;
  }
  const bool swizzle = format == VK_FORMAT_B8G8R8A8_UNORM
                       || format == VK_FORMAT_B8G8R8A8_SRGB;

  const VkDeviceSize bytes =
    static_cast<VkDeviceSize>(width) * height * sourceBytesPerPixel;

  VkBuffer      staging      = VK_NULL_HANDLE;
  VmaAllocation stagingAlloc = VK_NULL_HANDLE;
  createBuffer(bytes, VK_BUFFER_USAGE_TRANSFER_DST_BIT,
               VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                 VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
               staging, stagingAlloc,
               canvas::GpuTag{canvas::GpuCategory::Staging, 0,
                              "atlas readback"});

  // Whatever the caller says the image is in, and back again: this runs
  // alongside a live compositor and must leave the atlas exactly as it found
  // it.
  transitionImageLayout(image, format, currentLayout,
                        VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
  {
    VkCommandBuffer commandBuffer = beginSingleTimeCommands();
    VkBufferImageCopy region{
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
    vkCmdCopyImageToBuffer(commandBuffer, image,
                           VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging, 1,
                           &region);
    endSingleTimeCommands(commandBuffer);
  }
  transitionImageLayout(image, format, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                        currentLayout);

  const auto *src = static_cast<const uint8_t *>(mapBuffer(stagingAlloc));
  outRgba.assign(static_cast<size_t>(width) * height * 4, 0);
  for (size_t i = 0, pixels = static_cast<size_t>(width) * height; i < pixels;
       ++i) {
    uint8_t *dst = outRgba.data() + i * 4;
    if (sourceBytesPerPixel == 1) {
      // A coverage atlas as grey-on-opaque, which is what makes the packing
      // visible. Alpha would render the whole page as transparent nothing.
      dst[0] = dst[1] = dst[2] = src[i];
      dst[3] = 0xff;
    } else {
      const uint8_t *s = src + i * 4;
      dst[0] = swizzle ? s[2] : s[0];
      dst[1] = s[1];
      dst[2] = swizzle ? s[0] : s[2];
      dst[3] = s[3];
    }
  }
  unmapBuffer(stagingAlloc);
  destroyBuffer(staging, stagingAlloc);
  return true;
}

void RenderDevice::copyBufferToImageRegion(
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

void RenderDevice::updateSampledImageRegion(
  VkBuffer buffer, VkImage image, int32_t dstX, int32_t dstY,
  uint32_t width, uint32_t height)
{
  VkCommandBuffer commandBuffer = beginSingleTimeCommands();

  VkImageMemoryBarrier toTransfer{
    .sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
    .srcAccessMask       = VK_ACCESS_SHADER_READ_BIT,
    .dstAccessMask       = VK_ACCESS_TRANSFER_WRITE_BIT,
    .oldLayout           = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    .newLayout           = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
    .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
    .image               = image,
    .subresourceRange    = {
      .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
      .baseMipLevel = 0, .levelCount = 1,
      .baseArrayLayer = 0, .layerCount = 1,
    },
  };
  vkCmdPipelineBarrier(commandBuffer,
                       VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                       VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                       0, nullptr, 0, nullptr, 1, &toTransfer);

  VkBufferImageCopy region{
    .bufferOffset = 0,
    .bufferRowLength = 0,
    .bufferImageHeight = 0,
    .imageSubresource = {
      .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
      .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1,
    },
    .imageOffset = {dstX, dstY, 0},
    .imageExtent = {width, height, 1},
  };
  vkCmdCopyBufferToImage(commandBuffer, buffer, image,
                         VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

  VkImageMemoryBarrier toSample = toTransfer;
  toSample.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
  toSample.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
  toSample.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
  toSample.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
  vkCmdPipelineBarrier(commandBuffer,
                       VK_PIPELINE_STAGE_TRANSFER_BIT,
                       VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0,
                       0, nullptr, 0, nullptr, 1, &toSample);

  endSingleTimeCommands(commandBuffer);
}

void RenderDevice::copyBufferToImage(
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

bool RenderDevice::formatSupportsLinearBlit(VkFormat format) const
{
  VkFormatProperties props{};
  vkGetPhysicalDeviceFormatProperties(physicalDevice_, format, &props);
  const VkFormatFeatureFlags need =
    VK_FORMAT_FEATURE_BLIT_SRC_BIT | VK_FORMAT_FEATURE_BLIT_DST_BIT |
    VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;
  return (props.optimalTilingFeatures & need) == need;
}

void RenderDevice::generateMipmaps(VkImage image, int32_t width, int32_t height,
                                   uint32_t mipLevels)
{
  if (image == VK_NULL_HANDLE || width < 1 || height < 1 || mipLevels < 1) {
    return;
  }

  VkCommandBuffer cmd = beginSingleTimeCommands();

  VkImageMemoryBarrier barrier{
    .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
    .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
    .image = image,
    .subresourceRange =
      {
        .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
      },
  };

  int32_t mipW = width;
  int32_t mipH = height;
  for (uint32_t i = 1; i < mipLevels; ++i) {
    barrier.subresourceRange.baseMipLevel = i - 1;
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0,
                         nullptr, 1, &barrier);

    const int32_t nextW = mipW > 1 ? mipW / 2 : 1;
    const int32_t nextH = mipH > 1 ? mipH / 2 : 1;
    VkImageBlit blit{};
    blit.srcOffsets[0] = {0, 0, 0};
    blit.srcOffsets[1] = {mipW, mipH, 1};
    blit.srcSubresource = {
      .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
      .mipLevel = i - 1,
      .baseArrayLayer = 0,
      .layerCount = 1,
    };
    blit.dstOffsets[0] = {0, 0, 0};
    blit.dstOffsets[1] = {nextW, nextH, 1};
    blit.dstSubresource = {
      .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
      .mipLevel = i,
      .baseArrayLayer = 0,
      .layerCount = 1,
    };
    vkCmdBlitImage(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, image,
                   VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit,
                   VK_FILTER_LINEAR);

    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, nullptr,
                         0, nullptr, 1, &barrier);

    mipW = nextW;
    mipH = nextH;
  }

  barrier.subresourceRange.baseMipLevel = mipLevels - 1;
  barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
  barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
  barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
  barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
  vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
                       VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, nullptr, 0,
                       nullptr, 1, &barrier);

  endSingleTimeCommands(cmd);
}

void RenderDevice::cleanUp()
{
  if (device_ != VK_NULL_HANDLE) {
    vkDeviceWaitIdle(device_);
  }

  // Windows own their own teardown and must be gone before this runs; if one
  // is still registered it holds attachments and sync objects allocated from
  // resources about to be destroyed.
  assert(windows_.empty() && "destroy every RenderWindow before the device");

  if (sharedDepthView_ != VK_NULL_HANDLE) {
    vkDestroyImageView(device_, sharedDepthView_, nullptr);
    sharedDepthView_ = VK_NULL_HANDLE;
  }
  destroyImage(sharedDepthImage_, sharedDepthAlloc_);
  sharedDepthExtent_ = {};

  // The wait above means nothing in the trash can still be referenced, so
  // everything queued is releasable regardless of its submission index.
  for (auto &t : trash_) {
    if (t.view != VK_NULL_HANDLE) vkDestroyImageView(device_, t.view, nullptr);
    if (t.image != VK_NULL_HANDLE) {
      gpuLedger_.remove(t.allocation);
      vmaDestroyImage(allocator_, t.image, t.allocation);
    }
  }
  trash_.clear();

#ifdef INCLUDE_IMGUI
  if (imguiInitialized_) {
    if (presentCapable_) {
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

  if (text_) {
    text_->cleanUp();
    text_.reset();
  }

  if (commandPool_ != VK_NULL_HANDLE) {
    vkDestroyCommandPool(device_, commandPool_, nullptr);
    commandPool_ = VK_NULL_HANDLE;
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

  if (enableValidationLayers_ && debugMessenger_ != VK_NULL_HANDLE) {
    destroyDebugUtilsMessengerEXT(instance_, debugMessenger_, nullptr);
    debugMessenger_ = VK_NULL_HANDLE;
  }

  if (instance_ != VK_NULL_HANDLE) {
    vkDestroyInstance(instance_, nullptr);
    instance_ = VK_NULL_HANDLE;
  }

  // GLFW was ours to start (see init) and no window is left to need it.
  if (presentCapable_) {
    glfwTerminate();
    presentCapable_ = false;
  }
}

Shaders &RenderDevice::getShaders()
{
  static Shaders shaders(*this);
  return shaders;
}

// Compute shader support implementations
VkDescriptorSetLayout RenderDevice::createComputeDescriptorSetLayout()
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

VkPipelineLayout RenderDevice::createComputePipelineLayout(VkDescriptorSetLayout descriptorSetLayout)
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

VkPipeline RenderDevice::createComputePipeline(VkPipelineLayout pipelineLayout, const std::string& shaderPath)
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

VkDescriptorPool RenderDevice::createComputeDescriptorPool(uint32_t maxSets)
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

VkDescriptorSet RenderDevice::allocateComputeDescriptorSet(VkDescriptorPool pool, VkDescriptorSetLayout layout)
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

void RenderDevice::dispatchCompute(VkCommandBuffer commandBuffer, VkPipeline pipeline, VkPipelineLayout layout, VkDescriptorSet descriptorSet, uint32_t groupCountX, uint32_t groupCountY, uint32_t groupCountZ)
{
  vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
  vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &descriptorSet, 0, nullptr);
  vkCmdDispatch(commandBuffer, groupCountX, groupCountY, groupCountZ);
}

#ifdef INCLUDE_IMGUI
void RenderDevice::initImGui()
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

/// Brings up everything shared: instance, GPU, logical device, allocator,
/// command pool, render passes.
///
/// Note what is *not* here any more — no swapchain, no attachments, no
/// framebuffer, no per-frame sync. Those belong to a `RenderWindow`, and this
/// runs to completion before the first one is constructed.
void RenderDevice::init(const char *applicationName, bool presentCapable)
{
  // Applies `LAVA_MSAA` even when nobody called the setter, and re-clamps
  // whatever did. Cheap, and it means every device in the tree — compositor,
  // windowed app, offscreen test — honours the same override.
  setSampleCap(sampleCap_);

  deviceExtensions.clear();
  if (presentCapable) {
    deviceExtensions = {VK_KHR_SWAPCHAIN_EXTENSION_NAME};
    if (!glfwInit()) {
      throw std::runtime_error("glfwInit failed");
    }
  }
  if (exportDrmFd_ >= 0) {
    // Required, so they go in before device selection: a GPU that cannot
    // export is not a GPU this device can be built on, and finding that out
    // at `vkCreateImage` time is a much more confusing failure.
    deviceExtensions.insert(
      deviceExtensions.end(),
      {VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
       VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
       VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
       // Handing an image to a driver that is not this one means releasing
       // queue ownership to `VK_QUEUE_FAMILY_FOREIGN_EXT`, and naming that
       // family is only legal with this enabled. Required rather than
       // optional: without it the release barrier is undefined behaviour that
       // happens to work, which is worse than not exporting at all.
       VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME});
  }

  enableValidationLayers_ = utils::envFlag("CANVAS_VK_VALIDATION", false);
  presentCapable_ = presentCapable;

  createVkInstance(applicationName);
  setupDebugMessenger();

  // Present support is a property of (physical device, queue family, surface),
  // so choosing a device that can present needs a surface — and there is no
  // real window yet, by design. A hidden 1x1 window supplies one for the
  // question and is gone before anything else runs.
  //
  // The alternative is what this used to do: create the device *from* the
  // first window, which makes the device's lifetime hostage to that window's
  // and leaves every window after it hoping the queue family it inherited
  // happens to fit. `RenderWindow` re-checks each surface anyway; this just
  // makes the answer be yes.
  GLFWwindow *probeWindow = nullptr;
  VkSurfaceKHR probeSurface = VK_NULL_HANDLE;
  if (presentCapable) {
    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
    glfwWindowHint(GLFW_VISIBLE, GLFW_FALSE);
    probeWindow = glfwCreateWindow(1, 1, "", nullptr, nullptr);
    if (!probeWindow) {
      throw std::runtime_error("glfwCreateWindow failed (present probe)");
    }
    VR(glfwCreateWindowSurface(instance_, probeWindow, nullptr, &probeSurface),
       "failed to create probe surface");
  }
  probeSurface_ = probeSurface;

  selectSupportedGraphicsCard();
  createLogicalDevice();

  if (probeSurface != VK_NULL_HANDLE) {
    vkDestroySurfaceKHR(instance_, probeSurface, nullptr);
    probeSurface_ = VK_NULL_HANDLE;
  }
  if (probeWindow) glfwDestroyWindow(probeWindow);

  createCommandPool();
  createRenderPass();
  text_ = std::make_unique<TextRenderer>(*this);
#ifdef INCLUDE_IMGUI
  initImGui();
#endif
}

TextRenderer &RenderDevice::textRenderer()
{
  assert(text_ && "textRenderer() before init() / after cleanUp()");
  return *text_;
}

void RenderDevice::syncGlyphAtlas()
{
  // Exclusive, and for a stronger reason than the fences: growing frees the
  // old atlas image outright and rewrites every window's descriptor set. A
  // window recording concurrently is naming both.
  std::unique_lock frameLock(frameMutex_);
  std::lock_guard lock(sharedStateMutex_);
  if (!text_) return;
  // Replacing the image is only safe once nothing can still sample the old
  // one — and "nothing" spans every window, not just the one about to draw.
  if (text_->atlasNeedsGrow()) {
    waitForAllFramesInFlight();
  }
  if (text_->growAtlasIfNeeded()) {
    for (RenderWindow *w : windows_) {
      w->setGlyphAtlas(text_->atlasView(), text_->atlasSampler());
    }
  }
}

void RenderDevice::registerWindow(RenderWindow *window)
{
  if (!window) return;
  windows_.push_back(window);
  // A window opened after the atlas already has content must not start out
  // bound to QuadRenderer's 1x1 white placeholder.
  if (text_) window->setGlyphAtlas(text_->atlasView(), text_->atlasSampler());
}

std::vector<RenderWindow *> RenderDevice::windowsSnapshot() const
{
  return windows_;
}

void RenderDevice::unregisterWindow(RenderWindow *window)
{
  windows_.erase(std::remove(windows_.begin(), windows_.end(), window),
                 windows_.end());
}

void RenderDevice::waitForAllFramesInFlight()
{
  for (RenderWindow *w : windows_) w->waitForAllFrames();
}
