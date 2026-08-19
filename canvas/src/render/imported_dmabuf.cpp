#include "render/imported_dmabuf.hpp"

#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <cstdint>
#include <format>
#include <iostream>
#include <vector>

#include <poll.h>

extern "C" {
#include <drm_fourcc.h>
#include <linux/dma-buf.h>
}

#include "render/render_device.hpp"

namespace canvas {
namespace {

constexpr VkImageUsageFlags kUsage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
constexpr VkFormatFeatureFlags kRequiredFeatures =
  VK_FORMAT_FEATURE_TRANSFER_SRC_BIT | VK_FORMAT_FEATURE_BLIT_SRC_BIT;

constexpr VkImageSubresourceRange kWholeImage{
  VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};

void logFail(const char *why)
{
  static std::atomic<int> remaining{4};
  const int left = remaining.fetch_sub(1);
  if (left > 0) {
    std::cerr << "ImportedDmabuf: " << why << '\n';
  }
}

struct MappedFormat {
  VkFormat vk           = VK_FORMAT_UNDEFINED;
  bool     opaqueAlpha  = false;
};

MappedFormat mapDrmFormat(uint32_t fourcc)
{
  // Same pairing `DmabufImage` exports: little-endian ARGB8888 is
  // `B8G8R8A8`, ABGR8888 is `R8G8B8A8`. Tagged UNORM so a blit into the
  // engine's `R8G8B8A8_UNORM` dest copies encoded bytes rather than
  // putting a transfer function between the two — matching the CPU path,
  // which only swizzles channels.
  switch (fourcc) {
  case DRM_FORMAT_ARGB8888:
    return {VK_FORMAT_B8G8R8A8_UNORM, false};
  case DRM_FORMAT_XRGB8888:
    return {VK_FORMAT_B8G8R8A8_UNORM, true};
  case DRM_FORMAT_ABGR8888:
    return {VK_FORMAT_R8G8B8A8_UNORM, false};
  case DRM_FORMAT_XBGR8888:
    return {VK_FORMAT_R8G8B8A8_UNORM, true};
  default:
    return {};
  }
}

bool sameFile(int a, int b)
{
  if (a < 0 || b < 0) return false;
  if (a == b) return true;
  struct stat sa {}, sb {};
  if (fstat(a, &sa) != 0 || fstat(b, &sb) != 0) return false;
  return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino;
}

bool planesShareMemory(const DmabufImport &src)
{
  if (src.planeCount < 1) return false;
  for (int i = 1; i < src.planeCount; ++i) {
    if (!sameFile(src.fd[0], src.fd[i])) return false;
  }
  return true;
}

bool modifierImportable(VkPhysicalDevice physical, VkFormat format,
                        uint64_t modifier)
{
  VkDrmFormatModifierPropertiesListEXT list{
    .sType = VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT,
  };
  VkFormatProperties2 props{
    .sType = VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2,
    .pNext = &list,
  };
  vkGetPhysicalDeviceFormatProperties2(physical, format, &props);
  if (list.drmFormatModifierCount == 0) return false;

  std::vector<VkDrmFormatModifierPropertiesEXT> entries(
    list.drmFormatModifierCount);
  list.pDrmFormatModifierProperties = entries.data();
  vkGetPhysicalDeviceFormatProperties2(physical, format, &props);

  const VkDrmFormatModifierPropertiesEXT *found = nullptr;
  for (const auto &entry : entries) {
    if (entry.drmFormatModifier == modifier) {
      found = &entry;
      break;
    }
  }
  if (found == nullptr) return false;
  if ((found->drmFormatModifierTilingFeatures & kRequiredFeatures) !=
      kRequiredFeatures) {
    return false;
  }

  VkPhysicalDeviceExternalImageFormatInfo external{
    .sType      = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO,
    .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
  };
  VkPhysicalDeviceImageDrmFormatModifierInfoEXT modifierInfo{
    .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT,
    .pNext             = &external,
    .drmFormatModifier = modifier,
    .sharingMode       = VK_SHARING_MODE_EXCLUSIVE,
  };
  VkPhysicalDeviceImageFormatInfo2 formatInfo{
    .sType  = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
    .pNext  = &modifierInfo,
    .format = format,
    .type   = VK_IMAGE_TYPE_2D,
    .tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
    .usage  = kUsage,
  };
  VkExternalImageFormatProperties externalProps{
    .sType = VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES,
  };
  VkImageFormatProperties2 imageProps{
    .sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2,
    .pNext = &externalProps,
  };
  if (vkGetPhysicalDeviceImageFormatProperties2(physical, &formatInfo,
                                                &imageProps) != VK_SUCCESS) {
    return false;
  }
  return (externalProps.externalMemoryProperties.externalMemoryFeatures &
          VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT) != 0;
}

void fillPlaneLayouts(const DmabufImport                  &src,
                      VkSubresourceLayout                 *layouts)
{
  for (int i = 0; i < src.planeCount; ++i) {
    layouts[i] = {};
    layouts[i].offset   = src.offset[i];
    layouts[i].rowPitch = src.stride[i];
  }
}

}  // namespace

bool ImportedDmabuf::bindImportedMemory(ImportedDmabuf &self, int srcFd)
{
  RenderDevice &device = *self.device_;
  VkDevice      vk     = device.getDevice();
  if (device.getMemoryFdProperties() == nullptr) return false;

  // Vulkan takes ownership of the fd even on some failures, so the dup
  // is what keeps the caller's descriptor alive.
  const int importedFd = dup(srcFd);
  if (importedFd < 0) {
    logFail("dup of dma-buf fd failed");
    return false;
  }

  VkMemoryRequirements reqs{};
  vkGetImageMemoryRequirements(vk, self.image_, &reqs);

  VkMemoryFdPropertiesKHR fdProps{
    .sType = VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR,
  };
  if (device.getMemoryFdProperties()(
        vk, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, importedFd,
        &fdProps) != VK_SUCCESS) {
    logFail("vkGetMemoryFdPropertiesKHR failed");
    close(importedFd);
    return false;
  }

  const uint32_t typeBits = reqs.memoryTypeBits & fdProps.memoryTypeBits;
  if (typeBits == 0) {
    logFail("no memory type in common between the image and the dma-buf");
    close(importedFd);
    return false;
  }

  VkPhysicalDeviceMemoryProperties memProps{};
  vkGetPhysicalDeviceMemoryProperties(device.physicalDevice(), &memProps);
  uint32_t typeIndex = UINT32_MAX;
  for (uint32_t i = 0; i < memProps.memoryTypeCount; ++i) {
    if ((typeBits & (1u << i)) == 0) continue;
    if (memProps.memoryTypes[i].propertyFlags &
        VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) {
      typeIndex = i;
      break;
    }
    if (typeIndex == UINT32_MAX) typeIndex = i;
  }
  if (typeIndex == UINT32_MAX) {
    close(importedFd);
    return false;
  }

  VkMemoryDedicatedAllocateInfo dedicated{
    .sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
    .image = self.image_,
  };
  VkImportMemoryFdInfoKHR importFd{
    .sType      = VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR,
    .pNext      = &dedicated,
    .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    .fd         = importedFd,
  };
  VkMemoryAllocateInfo alloc{
    .sType           = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
    .pNext           = &importFd,
    .allocationSize  = reqs.size,
    .memoryTypeIndex = typeIndex,
  };
  if (vkAllocateMemory(vk, &alloc, nullptr, &self.memory_) != VK_SUCCESS) {
    // Spec: a failed import may or may not have consumed the fd. Closing
    // a consumed one is a double-close; leaking one is worse on a path
    // that retries every backdrop refresh. Prefer the leak: importedFd
    // is a dup.
    logFail("vkAllocateMemory import failed");
    return false;
  }
  if (vkBindImageMemory(vk, self.image_, self.memory_, 0) != VK_SUCCESS) {
    logFail("vkBindImageMemory failed");
    return false;
  }
  // Reported, but as somebody else's memory: this is a client's buffer mapped
  // in, so counting it against this process would double-count the pixels the
  // client already paid for. `GpuCategory::ImportedSurface` is the one
  // category the totals keep separate.
  device.gpuLedger().addExternal(
    self.memory_, reqs.size,
    canvas::GpuTag{canvas::GpuCategory::ImportedSurface, 0,
                   "client buffer mapped for sampling"},
    self.width_, self.height_, static_cast<uint32_t>(self.vkFormat_));
  return true;
}

std::unique_ptr<ImportedDmabuf> ImportedDmabuf::createTiled(
  RenderDevice &device, const DmabufImport &src, VkFormat format,
  bool opaqueAlpha)
{
  std::unique_ptr<ImportedDmabuf> self(new ImportedDmabuf());
  self->device_      = &device;
  self->vkFormat_    = format;
  self->width_       = src.width;
  self->height_      = src.height;
  self->opaqueAlpha_ = opaqueAlpha;
  self->waitFd_      = src.fd[0];

  VkSubresourceLayout layouts[4]{};
  fillPlaneLayouts(src, layouts);

  VkImageDrmFormatModifierExplicitCreateInfoEXT explicitMod{
    .sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT,
    .drmFormatModifier           = src.modifier,
    .drmFormatModifierPlaneCount = static_cast<uint32_t>(src.planeCount),
    .pPlaneLayouts               = layouts,
  };
  VkExternalMemoryImageCreateInfo externalImage{
    .sType       = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
    .pNext       = &explicitMod,
    .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
  };
  VkImageCreateInfo imageInfo{
    .sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
    .pNext         = &externalImage,
    .imageType     = VK_IMAGE_TYPE_2D,
    .format        = format,
    .extent        = {src.width, src.height, 1},
    .mipLevels     = 1,
    .arrayLayers   = 1,
    .samples       = VK_SAMPLE_COUNT_1_BIT,
    .tiling        = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
    .usage         = kUsage,
    .sharingMode   = VK_SHARING_MODE_EXCLUSIVE,
    .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
  };
  if (vkCreateImage(device.getDevice(), &imageInfo, nullptr, &self->image_) !=
      VK_SUCCESS) {
    logFail("vkCreateImage (modifier) failed");
    return nullptr;
  }
  if (!bindImportedMemory(*self, src.fd[0])) return nullptr;
  return self;
}

std::unique_ptr<ImportedDmabuf> ImportedDmabuf::createLinear(
  RenderDevice &device, const DmabufImport &src, VkFormat format,
  bool opaqueAlpha)
{
  std::unique_ptr<ImportedDmabuf> self(new ImportedDmabuf());
  self->device_      = &device;
  self->vkFormat_    = format;
  self->width_       = src.width;
  self->height_      = src.height;
  self->opaqueAlpha_ = opaqueAlpha;
  self->waitFd_      = src.fd[0];

  VkExternalMemoryImageCreateInfo externalImage{
    .sType       = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
    .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
  };
  VkImageCreateInfo imageInfo{
    .sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
    .pNext         = &externalImage,
    .imageType     = VK_IMAGE_TYPE_2D,
    .format        = format,
    .extent        = {src.width, src.height, 1},
    .mipLevels     = 1,
    .arrayLayers   = 1,
    .samples       = VK_SAMPLE_COUNT_1_BIT,
    .tiling        = VK_IMAGE_TILING_LINEAR,
    .usage         = kUsage,
    .sharingMode   = VK_SHARING_MODE_EXCLUSIVE,
    .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
  };
  if (vkCreateImage(device.getDevice(), &imageInfo, nullptr, &self->image_) !=
      VK_SUCCESS) {
    logFail("vkCreateImage (linear) failed");
    return nullptr;
  }
  if (!bindImportedMemory(*self, src.fd[0])) return nullptr;
  return self;
}

std::unique_ptr<ImportedDmabuf> ImportedDmabuf::create(
  RenderDevice &device, const DmabufImport &src)
{
  if (!device.canImportDmabuf()) {
    logFail("this device was not brought up for dma-buf import");
    return nullptr;
  }
  if (src.width < 1 || src.height < 1 || src.planeCount < 1 ||
      src.planeCount > 4 || src.fd[0] < 0) {
    logFail("import descriptor is incomplete");
    return nullptr;
  }
  if (src.modifier == DRM_FORMAT_MOD_INVALID) {
    logFail("implicit modifier; refusing to guess the tiling");
    return nullptr;
  }
  if (!planesShareMemory(src)) {
    logFail("disjoint multi-plane dma-buf is not imported yet");
    return nullptr;
  }

  const MappedFormat mapped = mapDrmFormat(src.drmFormat);
  if (mapped.vk == VK_FORMAT_UNDEFINED) {
    logFail("unrecognised FourCC");
    return nullptr;
  }

  std::unique_ptr<ImportedDmabuf> imported;
  if (modifierImportable(device.physicalDevice(), mapped.vk, src.modifier)) {
    imported = createTiled(device, src, mapped.vk, mapped.opaqueAlpha);
  }
  if (!imported && src.modifier == DRM_FORMAT_MOD_LINEAR) {
    imported = createLinear(device, src, mapped.vk, mapped.opaqueAlpha);
  }
  if (!imported) {
    logFail("modifier is not importable as a blit source");
    return nullptr;
  }

  static std::atomic<bool> announced{false};
  if (!announced.exchange(true)) {
    std::cout << std::format(
      "ImportedDmabuf: first import {}x{} fourcc={:08x} modifier=0x{:016x} "
      "planes={}\n",
      src.width, src.height, src.drmFormat, src.modifier, src.planeCount);
  }
  return imported;
}

ImportedDmabuf::~ImportedDmabuf()
{
  if (device_ == nullptr) return;
  VkDevice vk = device_->getDevice();
  if (image_ != VK_NULL_HANDLE) vkDestroyImage(vk, image_, nullptr);
  if (memory_ != VK_NULL_HANDLE) {
    device_->gpuLedger().remove(memory_);
    vkFreeMemory(vk, memory_, nullptr);
  }
}

void ImportedDmabuf::waitReady(int timeoutMs) const
{
  if (waitFd_ < 0) return;

  int          fd  = waitFd_;
  bool         own = false;
  dma_buf_export_sync_file exp{
    .flags = DMA_BUF_SYNC_READ,
    .fd    = -1,
  };
  if (ioctl(waitFd_, DMA_BUF_IOCTL_EXPORT_SYNC_FILE, &exp) == 0 &&
      exp.fd >= 0) {
    fd  = exp.fd;
    own = true;
  }

  pollfd pfd{
    .fd      = fd,
    .events  = POLLIN,
    .revents = 0,
  };
  poll(&pfd, 1, timeoutMs < 0 ? -1 : timeoutMs);
  if (own) close(fd);
}

void ImportedDmabuf::recordAcquire(VkCommandBuffer cmd) const
{
  // Another VkDevice wrote this. EXTERNAL is the family that names
  // "a queue that is not this instance"; FOREIGN is a different *driver*.
  // Two devices on one GPU, two instances, is the first of those.
  VkImageMemoryBarrier acquire{
    .sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
    .srcAccessMask       = 0,
    .dstAccessMask       = VK_ACCESS_TRANSFER_READ_BIT,
    .oldLayout           = VK_IMAGE_LAYOUT_GENERAL,
    .newLayout           = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL,
    .dstQueueFamilyIndex = device_->graphicsQueueFamily(),
    .image               = image_,
    .subresourceRange    = kWholeImage,
  };
  vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                       VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0,
                       nullptr, 1, &acquire);
}

}  // namespace canvas
