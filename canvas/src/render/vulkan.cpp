#include <pch.hpp>

#include <set>
#include <cassert>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <algorithm>

#define BOOST_STACKTRACE_DYN_LINK
#define BOOST_STACKTRACE_USE_BACKTRACE
#include <boost/stacktrace.hpp>
#include <boost/stacktrace/stacktrace.hpp>

#include <vulkan/vulkan_core.h>

#include "imgui_impl_vulkan.h"

#include "util/util.hpp"
#include "render/shaders.hpp"
#include "render/vulkan.hpp"
#include "render/texture_manager.hpp"

#define DEBUG_PRINT 0

bool g_ValidationFromResult = false;

// No swapchain anymore (this is an offscreen renderer), so no device
// extensions are required.
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

  // Offscreen renderer: no VK_KHR_surface/platform surface extensions needed,
  // since there's no window to present to.
  auto instanceExtensions = std::vector<const char *>();

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

  // Vulkan requires an implementation to expose at least
  // one queue family with graphics
  graphicsAndPresentationQueueFamilyIdx_ = -1;

  for (uint32_t i = 0; i < count; i++) {
    if ((properties[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0) {
      graphicsAndPresentationQueueFamilyIdx_ = i;
      break;
    }
  }

  if (graphicsAndPresentationQueueFamilyIdx_ == -1) {
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

  VkDeviceCreateInfo deviceCreateInfo = {
    .sType                   = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
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
  VkDeviceMemory       &bufferMemory)
{
  VkBufferCreateInfo bufferInfo {
    .sType       = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
    .size        = size,
    .usage       = usage,
    .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
  };

  VR(vkCreateBuffer(device_, &bufferInfo, nullptr, &buffer),
     "failed to create buffer!");

  // std::cout << "Buffer created: " << buffer << std::endl;
  // auto trace = boost::stacktrace::stacktrace();
  // std::cout << trace << '\n';

  VkMemoryRequirements memRequirements;
  vkGetBufferMemoryRequirements(device_, buffer, &memRequirements);

  VkMemoryAllocateInfo allocInfo {
    .sType          = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
    .allocationSize = memRequirements.size,
    .memoryTypeIndex =
      findMemoryProperties(memRequirements.memoryTypeBits, properties),
  };

  VR(vkAllocateMemory(device_, &allocInfo, nullptr, &bufferMemory),
     "failed to allocate buffer memory!");

  vkBindBufferMemory(device_, buffer, bufferMemory, 0);
}

vk::Buffer Vulkan::createImmutableBuffer(
  const void           *bufferData,
  VkDeviceSize          bufferSize,
  VkBufferUsageFlagBits usageFlagBits)
{
  VkBuffer       vertexBuffer;
  VkDeviceMemory vertexBufferMemory;
  VkBuffer       stagingBuffer;
  VkDeviceMemory stagingBufferMemory;
  createBuffer(
    bufferSize,
    VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    stagingBuffer,
    stagingBufferMemory);

  void *data;
  vkMapMemory(device_, stagingBufferMemory, 0, bufferSize, 0, &data);
  memcpy(data, bufferData, (size_t)bufferSize);
  vkUnmapMemory(device_, stagingBufferMemory);

  createBuffer(bufferSize,
               VK_BUFFER_USAGE_TRANSFER_DST_BIT | usageFlagBits,
               VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
               vertexBuffer,
               vertexBufferMemory);

  copyBuffer(stagingBuffer, vertexBuffer, bufferSize);

  vkDestroyBuffer(device_, stagingBuffer, nullptr);
  vkFreeMemory(device_, stagingBufferMemory, nullptr);

  return vk::Buffer{vertexBuffer, vertexBufferMemory};
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

std::tuple<VkBuffer, VkDeviceMemory> Vulkan::createUniformBuffer(
  VkDeviceSize bufferSize)
{
  VkBuffer       uniformBuffer;
  VkDeviceMemory uniformBufferMemory;

  createBuffer(
    bufferSize,
    VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    uniformBuffer,
    uniformBufferMemory);

  return MT(uniformBuffer, uniformBufferMemory);
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
  VkDeviceMemory       &imageMemory)
{
  assert(mipLevels > 0);

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

  VR(vkCreateImage(device_, &imageInfo, nullptr, &image),
     "failed to create image!");

  VkMemoryRequirements memRequirements;
  vkGetImageMemoryRequirements(device_, image, &memRequirements);

  VkMemoryAllocateInfo allocInfo {
    .sType          = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
    .allocationSize = memRequirements.size,
    .memoryTypeIndex =
      findMemoryProperties(memRequirements.memoryTypeBits, properties),
  };

  VR(vkAllocateMemory(device_, &allocInfo, nullptr, &imageMemory),
     "failed to allocate image memory!");

  vkBindImageMemory(device_, image, imageMemory, 0);
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
              VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT |
                VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
              VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
              colorImage_,
              colorImageMemory_);

  colorImageView_ = createImageView(
    colorImage_, colorFormat_, VK_IMAGE_ASPECT_COLOR_BIT, 1);
}

void Vulkan::createResolveResources()
{
  // Single-sample target the MSAA color attachment resolves into. Unlike
  // colorImage_ (TRANSIENT_ATTACHMENT_BIT, MSAA scratch), this one needs
  // TRANSFER_SRC_BIT since it's what readPixels() copies out of.
  createImage(extent_.width,
              extent_.height,
              1,
              VK_SAMPLE_COUNT_1_BIT,
              colorFormat_,
              VK_IMAGE_TILING_OPTIMAL,
              VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
              VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
              resolveImage_,
              resolveImageMemory_);

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
               stagingBufferMemory_);

  VR(vkMapMemory(
       device_, stagingBufferMemory_, 0, stagingBufferSize_, 0,
       &stagingBufferMapped_),
     "failed to map staging buffer memory!");
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
              depthImageMemory_);

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
              shadowImageMemory_);

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
  std::array<VkAttachmentDescription, 3> attachments {
    // colorAttachment
    VkAttachmentDescription {
      .format         = colorFormat_,
      .samples        = msaaSamples_,
      .loadOp         = VK_ATTACHMENT_LOAD_OP_CLEAR,
      .storeOp        = VK_ATTACHMENT_STORE_OP_STORE,
      .stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
      .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
      .initialLayout  = VK_IMAGE_LAYOUT_UNDEFINED,
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
    // colorAttachmentResolve — this is what readPixels() copies out of, so
    // the render pass transitions it straight to TRANSFER_SRC_OPTIMAL at
    // subpass end instead of PRESENT_SRC_KHR (no swapchain to present to).
    VkAttachmentDescription {
      .format         = colorFormat_,
      .samples        = VK_SAMPLE_COUNT_1_BIT,
      .loadOp         = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
      .storeOp        = VK_ATTACHMENT_STORE_OP_STORE,
      .stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
      .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
      .initialLayout  = VK_IMAGE_LAYOUT_UNDEFINED,
      .finalLayout    = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
    },
  };

  auto &colorAttachment        = attachments[0];
  auto &depthAttachment        = attachments[1];
  auto &colorAttachmentResolve = attachments[2];

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

  // Without this, there's no synchronization guaranteeing the color/resolve
  // write is visible before readPixels()'s vkCmdCopyImageToBuffer (recorded
  // right after this pass ends) reads it. Previously masked by the fact that
  // the only consumer of finalLayout was vkQueuePresentKHR, externally
  // synchronized via a semaphore.
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

  VR(vkCreateRenderPass(device_, &renderPassInfo, nullptr, &renderPass_),
     "failed to create render pass!");
}

void Vulkan::createFramebuffer()
{
  VkImageView attachments[] = {colorImageView_, depthImageView_, resolveImageView_};

  VkFramebufferCreateInfo framebufferInfo {
    .sType           = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
    .renderPass      = renderPass_,
    .attachmentCount = 3,
    .pAttachments    = attachments,
    .width           = extent_.width,
    .height          = extent_.height,
    .layers          = 1,
  };

  VR(vkCreateFramebuffer(device_, &framebufferInfo, nullptr, &framebuffer_),
     "failed to create framebuffer!");
}

void Vulkan::createCommandPool()
{
  assert(graphicsAndPresentationQueueFamilyIdx_ != -1 && "queue family index not set");
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
    .commandBufferCount = 1,
  };
  VR(vkAllocateCommandBuffers(device_, &allocInfo, &commandBuffer_),
     "failed to allocate command buffers!");
}

void Vulkan::createSyncObjects()
{
  // No swapchain, so no image-available/render-finished semaphores needed —
  // there's nothing to acquire from or present to. The fence still guards
  // command buffer reuse across ticks.
  VkFenceCreateInfo fenceInfo {
    .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
    .flags = VK_FENCE_CREATE_SIGNALED_BIT,
  };
  VR(vkCreateFence(device_, &fenceInfo, nullptr, &inFlightFence_),
     "vkCreateFence failed.");
}

void Vulkan::beginMainRenderPass(
  VkCommandBuffer commandBuffer, u32 imageIndex)
{
  std::array<VkClearValue, 2> clearValues {};
  clearValues[0].color = {0.0f, 0.0f, 0.0f, 1.0f};
  clearValues[1].depthStencil = {1.0f, 0};

  VkRenderPassBeginInfo renderPassInfo {
    .sType           = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
    .renderPass      = renderPass_,
    .framebuffer     = framebuffer_,
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
  } else if (oldLayout == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL &&
             newLayout == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
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
  if (imguiInitialized_) {
    ImGui_ImplVulkan_Shutdown();
    ImGui::DestroyContext();
    imguiInitialized_ = false;
  }

  if (imguiDescriptorPool_ != VK_NULL_HANDLE) {
    vkDestroyDescriptorPool(device_, imguiDescriptorPool_, nullptr);
    imguiDescriptorPool_ = VK_NULL_HANDLE;
  }

  vkDestroyFence(device_, inFlightFence_, nullptr);

  vkDestroyCommandPool(device_, commandPool_, nullptr);
  vkDestroyFramebuffer(device_, framebuffer_, nullptr);

  if (stagingBufferMapped_) {
    vkUnmapMemory(device_, stagingBufferMemory_);
  }
  vkDestroyBuffer(device_, stagingBuffer_, nullptr);
  vkFreeMemory(device_, stagingBufferMemory_, nullptr);

  vkDestroyImageView(device_, resolveImageView_, nullptr);
  vkDestroyImage(device_, resolveImage_, nullptr);
  vkFreeMemory(device_, resolveImageMemory_, nullptr);

  // MSAA
  vkDestroyImageView(device_, colorImageView_, nullptr);
  vkDestroyImage(device_, colorImage_, nullptr);
  vkFreeMemory(device_, colorImageMemory_, nullptr);

  // Depth buffer
  vkDestroyImageView(device_, depthImageView_, nullptr);
  vkDestroyImage(device_, depthImage_, nullptr);
  vkFreeMemory(device_, depthImageMemory_, nullptr);

  // Shadow mapping
  vkDestroySampler(device_, shadowSampler_, nullptr);
  vkDestroyFramebuffer(device_, shadowFramebuffer_, nullptr);
  vkDestroyImageView(device_, shadowImageView_, nullptr);
  vkDestroyImage(device_, shadowImage_, nullptr);
  vkFreeMemory(device_, shadowImageMemory_, nullptr);
  vkDestroyRenderPass(device_, shadowRenderPass_, nullptr);

  vkDestroyRenderPass(device_, renderPass_, nullptr);

  auto &shaders = getShaders();
  shaders.cleanUp();

  vkDestroyDevice(device_, nullptr);

  if (enableValidationLayers_) {
    destroyDebugUtilsMessengerEXT(instance_, debugMessenger_, nullptr);
  }

  vkDestroyInstance(instance_, nullptr);
}

void Vulkan::renderWithShadows(
  std::function<void(VkCommandBuffer)> shadowCallback,
  std::function<void(VkCommandBuffer, u32)> mainCallback)
{
  // Wait for previous frame to complete and reset fence
  vkWaitForFences(device_, 1, &inFlightFence_, VK_TRUE, UINT64_MAX);
  vkResetFences(device_, 1, &inFlightFence_);

  // No swapchain to acquire from — there's only ever one target
  // (framebuffer_/resolveImage_), so there's no image index to pick.
  const u32 imageIndex = 0;

  vkResetCommandBuffer(commandBuffer_, 0);

  // Begin command buffer
  VkCommandBufferBeginInfo beginInfo {
    VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
  };

  VR(vkBeginCommandBuffer(commandBuffer_, &beginInfo),
     "failed to begin recording command buffer!");

  // 1. Shadow Pass - render depth-only to shadow map
  beginShadowPass(commandBuffer_);
  shadowCallback(commandBuffer_);
  vkCmdEndRenderPass(commandBuffer_);

  // 2. Main Pass - render scene with shadows
  beginMainRenderPass(commandBuffer_, imageIndex);
  mainCallback(commandBuffer_, imageIndex);
  vkCmdEndRenderPass(commandBuffer_); // End main render pass manually

  // 3. Copy the resolved frame out for readPixels(). Safe to record
  // immediately: the render pass's VkSubpassDependency (see
  // createRenderPass) already guarantees the color write is visible to this
  // transfer read, and the render pass's finalLayout already transitioned
  // resolveImage_ to TRANSFER_SRC_OPTIMAL for us.
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

  vkCmdCopyImageToBuffer(commandBuffer_,
                        resolveImage_,
                        VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                        stagingBuffer_,
                        1,
                        &copyRegion);

  // End command buffer recording (only once!)
  VR(vkEndCommandBuffer(commandBuffer_), "failed to record command buffer!");

  // Submit — nothing to wait on or signal, there's no acquire/present to
  // synchronize with anymore.
  VkSubmitInfo submitInfo {
    .sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO,
    .commandBufferCount = 1,
    .pCommandBuffers    = &commandBuffer_,
  };

  VR(vkQueueSubmit(graphicsQueue_, 1, &submitInfo, inFlightFence_),
     "failed to submit draw command buffer!");

  // Wait for the frame (and thus the copy) to complete before readPixels()
  // can safely memcpy from the (HOST_COHERENT) mapped staging buffer.
  vkDeviceWaitIdle(device_);
}

void Vulkan::readPixels(uint8_t *dst, size_t dstSize)
{
  size_t n = std::min(dstSize, static_cast<size_t>(stagingBufferSize_));
  memcpy(dst, stagingBufferMapped_, n);
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

  imguiInitialized_ = true;
}

void Vulkan::init(const char *applicationName, int width, int height)
{
  extent_      = {static_cast<uint32_t>(width), static_cast<uint32_t>(height)};
  colorFormat_ = VK_FORMAT_R8G8B8A8_SRGB;

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
  initImGui();
}
