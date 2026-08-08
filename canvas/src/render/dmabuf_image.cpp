#include "render/dmabuf_image.hpp"

#include <sys/ioctl.h>
#include <unistd.h>

#include <algorithm>
#include <iostream>

extern "C" {
#include <drm_fourcc.h>
#include <linux/dma-buf.h>
}

#include "render/render_device.hpp"

namespace canvas {
namespace {

/// The one format the export is fixed to, for now.
///
/// Vulkan's B8G8R8A8_SRGB and DRM's ARGB8888 describe the same bytes on a
/// little-endian machine, which is what makes the handover a reinterpretation
/// rather than a conversion.
///
/// sRGB rather than UNORM, and it matters: the frame is blitted here from the
/// window's resolve target, which is `R8G8B8A8_SRGB`. `vkCmdBlitImage`
/// converts between formats, so an UNORM destination would linearise the
/// source and write it back without re-encoding — a whole-surface darkening
/// that looks like a blending bug and is not one.
///
/// A rather than X on the DRM side. The two name identical memory and differ
/// only in whether the fourth channel means anything — and it does: a window
/// with a rounded corner, a translucent panel, or a shadow around it has
/// pixels that are not fully opaque, and saying `X` tells the compositor to
/// read them as if they were.
///
/// The cost is that the compositor now blends the whole surface instead of
/// skipping it. The way back is `wlr_scene_buffer_set_opaque_region`, which
/// needs a client able to say which part of itself is opaque — a question the
/// draw list does not answer yet.
///
/// Alpha here is *premultiplied*, which is what Wayland expects and what the
/// engine already produces: its blend state is `SRC_ALPHA`/`ONE_MINUS_SRC_ALPHA`
/// for colour and `ONE`/`ONE_MINUS_SRC_ALPHA` for alpha, which onto a
/// transparent clear yields `rgb = C·A, a = A` and composes correctly from
/// there. See `RenderWindow::setTransparent`.
constexpr VkFormat kVkFormat  = VK_FORMAT_B8G8R8A8_SRGB;
constexpr uint32_t kDrmFormat = DRM_FORMAT_ARGB8888;

constexpr VkImageUsageFlags kUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT;
/// What the modifier's tiling has to support for the blit above to be legal.
constexpr VkFormatFeatureFlags kRequiredFeatures =
  VK_FORMAT_FEATURE_TRANSFER_DST_BIT | VK_FORMAT_FEATURE_BLIT_DST_BIT;

constexpr VkImageSubresourceRange kWholeImage {
  VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};

}  // namespace

uint32_t DmabufImage::exportFormat() { return kDrmFormat; }

std::vector<uint64_t> DmabufImage::usableModifiers(
  VkPhysicalDevice physical, VkFormat format,
  const std::vector<uint64_t> &importable)
{
  VkDrmFormatModifierPropertiesListEXT list {
    .sType = VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT,
  };
  VkFormatProperties2 props {
    .sType = VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2,
    .pNext = &list,
  };
  vkGetPhysicalDeviceFormatProperties2(physical, format, &props);

  std::vector<VkDrmFormatModifierPropertiesEXT> entries(
    list.drmFormatModifierCount);
  list.pDrmFormatModifierProperties = entries.data();
  vkGetPhysicalDeviceFormatProperties2(physical, format, &props);

  std::vector<uint64_t> result;
  for (const auto &entry : entries) {
    // Single plane only. Multi-plane modifiers are legal and would need a
    // descriptor and an offset per plane; nothing here produces one yet, and
    // accepting one silently would export a buffer the consumer reads wrongly.
    if (entry.drmFormatModifierPlaneCount != 1) continue;
    if ((entry.drmFormatModifierTilingFeatures & kRequiredFeatures) !=
        kRequiredFeatures) {
      continue;
    }

    // Writing into it is not enough; the driver also has to be willing to
    // export it. Asking now turns a later, much more confusing failure into a
    // modifier that simply is not offered.
    VkPhysicalDeviceExternalImageFormatInfo external {
      .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO,
      .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    VkPhysicalDeviceImageDrmFormatModifierInfoEXT modifierInfo {
      .sType =
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT,
      .pNext            = &external,
      .drmFormatModifier = entry.drmFormatModifier,
      .sharingMode      = VK_SHARING_MODE_EXCLUSIVE,
    };
    VkPhysicalDeviceImageFormatInfo2 formatInfo {
      .sType  = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
      .pNext  = &modifierInfo,
      .format = format,
      .type   = VK_IMAGE_TYPE_2D,
      .tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
      .usage  = kUsage,
    };
    VkExternalImageFormatProperties externalProps {
      .sType = VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES,
    };
    VkImageFormatProperties2 imageProps {
      .sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2,
      .pNext = &externalProps,
    };
    if (vkGetPhysicalDeviceImageFormatProperties2(physical, &formatInfo,
                                                  &imageProps) != VK_SUCCESS) {
      continue;
    }
    if (!(externalProps.externalMemoryProperties.externalMemoryFeatures &
          VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT)) {
      continue;
    }

    // Offer only what the other side said it could read. The two sets are not
    // guaranteed to overlap, and a buffer the consumer cannot import is a
    // failure at import time on hardware nobody tested on.
    if (std::ranges::find(importable, entry.drmFormatModifier) ==
        importable.end()) {
      continue;
    }
    result.push_back(entry.drmFormatModifier);
  }
  return result;
}

std::unique_ptr<DmabufImage> DmabufImage::create(
  RenderDevice &device, uint32_t width, uint32_t height,
  const std::vector<uint64_t> &importableModifiers)
{
  if (!device.canExportDmabuf()) {
    std::cerr << "DmabufImage: this device was not brought up for export — "
                 "call RenderDevice::exportToDrmDevice before init\n";
    return nullptr;
  }
  if (importableModifiers.empty()) {
    std::cerr << "DmabufImage: the consumer named no modifier it can import\n";
    return nullptr;
  }

  const std::vector<uint64_t> modifiers =
    usableModifiers(device.physicalDevice(), kVkFormat, importableModifiers);
  if (modifiers.empty()) {
    std::cerr << "DmabufImage: no modifier this GPU can export is also one "
                 "the consumer can import\n";
    return nullptr;
  }

  std::unique_ptr<DmabufImage> self(new DmabufImage());
  self->device_    = &device;
  self->width_     = width;
  self->height_    = height;
  self->drmFormat_ = kDrmFormat;

  VkDevice vk = device.getDevice();

  // The driver picks from the candidate list; which one it took is only known
  // afterwards, which is why the modifier is read back below rather than
  // assumed.
  VkImageDrmFormatModifierListCreateInfoEXT modifierList {
    .sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT,
    .drmFormatModifierCount = static_cast<uint32_t>(modifiers.size()),
    .pDrmFormatModifiers    = modifiers.data(),
  };
  VkExternalMemoryImageCreateInfo externalImage {
    .sType       = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
    .pNext       = &modifierList,
    .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
  };
  VkImageCreateInfo imageInfo {
    .sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
    .pNext         = &externalImage,
    .imageType     = VK_IMAGE_TYPE_2D,
    .format        = kVkFormat,
    .extent        = {width, height, 1},
    .mipLevels     = 1,
    .arrayLayers   = 1,
    .samples       = VK_SAMPLE_COUNT_1_BIT,
    .tiling        = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
    .usage         = kUsage,
    .sharingMode   = VK_SHARING_MODE_EXCLUSIVE,
    .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
  };
  if (vkCreateImage(vk, &imageInfo, nullptr, &self->image_) != VK_SUCCESS) {
    std::cerr << "DmabufImage: vkCreateImage failed\n";
    return nullptr;
  }

  VkMemoryRequirements reqs {};
  vkGetImageMemoryRequirements(vk, self->image_, &reqs);

  VkPhysicalDeviceMemoryProperties memProps {};
  vkGetPhysicalDeviceMemoryProperties(device.physicalDevice(), &memProps);
  uint32_t typeIndex = UINT32_MAX;
  for (uint32_t i = 0; i < memProps.memoryTypeCount; ++i) {
    if ((reqs.memoryTypeBits & (1u << i)) &&
        (memProps.memoryTypes[i].propertyFlags &
         VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
      typeIndex = i;
      break;
    }
  }
  if (typeIndex == UINT32_MAX) {
    std::cerr << "DmabufImage: no device-local memory type\n";
    return nullptr;
  }

  // Dedicated because the memory is about to leave this process: a
  // suballocated block would export the whole block, not this image. That is
  // also why VMA is not used here — it exists to suballocate.
  VkMemoryDedicatedAllocateInfo dedicated {
    .sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
    .image = self->image_,
  };
  VkExportMemoryAllocateInfo exportInfo {
    .sType       = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
    .pNext       = &dedicated,
    .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
  };
  VkMemoryAllocateInfo alloc {
    .sType           = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
    .pNext           = &exportInfo,
    .allocationSize  = reqs.size,
    .memoryTypeIndex = typeIndex,
  };
  if (vkAllocateMemory(vk, &alloc, nullptr, &self->memory_) != VK_SUCCESS) {
    std::cerr << "DmabufImage: vkAllocateMemory failed\n";
    return nullptr;
  }
  if (vkBindImageMemory(vk, self->image_, self->memory_, 0) != VK_SUCCESS) {
    std::cerr << "DmabufImage: vkBindImageMemory failed\n";
    return nullptr;
  }

  VkImageDrmFormatModifierPropertiesEXT chosen {
    .sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT,
  };
  if (device.getModifierProps()(vk, self->image_, &chosen) != VK_SUCCESS) {
    std::cerr << "DmabufImage: could not read back the chosen modifier\n";
    return nullptr;
  }
  self->modifier_ = chosen.drmFormatModifier;

  // Stride and offset are what make the exported bytes interpretable; without
  // them the importer has a size and no idea how rows are laid out.
  VkImageSubresource subresource {
    .aspectMask = VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT,
  };
  VkSubresourceLayout layout {};
  vkGetImageSubresourceLayout(vk, self->image_, &subresource, &layout);
  self->offset_[0] = static_cast<uint32_t>(layout.offset);
  self->stride_[0] = static_cast<uint32_t>(layout.rowPitch);

  VkMemoryGetFdInfoKHR fdInfo {
    .sType      = VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR,
    .memory     = self->memory_,
    .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
  };
  if (device.getMemoryFd()(vk, &fdInfo, &self->fd_[0]) != VK_SUCCESS) {
    std::cerr << "DmabufImage: vkGetMemoryFdKHR failed\n";
    return nullptr;
  }

  if (device.canExportSyncFd()) {
    VkExportSemaphoreCreateInfo exportSemaphore {
      .sType       = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO,
      .handleTypes = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
    };
    VkSemaphoreCreateInfo semaphoreInfo {
      .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
      .pNext = &exportSemaphore,
    };
    // A failure here costs the fence, not the surface: the caller falls back
    // to waiting on the CPU, which is what it does on a device that cannot
    // export one at all.
    if (vkCreateSemaphore(vk, &semaphoreInfo, nullptr, &self->semaphore_) !=
        VK_SUCCESS) {
      self->semaphore_ = VK_NULL_HANDLE;
    }
  }

  std::cout << std::format(
    "DmabufImage: exported {}x{} fd={} modifier=0x{:016x} stride={}\n", width,
    height, self->fd_[0], self->modifier_, self->stride_[0]);
  return self;
}

DmabufImage::~DmabufImage()
{
  if (device_ == nullptr) return;
  VkDevice vk = device_->getDevice();
  for (int &fd : fd_) {
    if (fd >= 0) {
      close(fd);
      fd = -1;
    }
  }
  if (semaphore_ != VK_NULL_HANDLE) {
    vkDestroySemaphore(vk, semaphore_, nullptr);
  }
  if (image_ != VK_NULL_HANDLE) vkDestroyImage(vk, image_, nullptr);
  // Freed after the image that was bound to it, and by hand rather than
  // through VMA: this allocation never belonged to the allocator.
  if (memory_ != VK_NULL_HANDLE) vkFreeMemory(vk, memory_, nullptr);
}

void DmabufImage::recordAcquire(VkCommandBuffer cmd) const
{
  VkImageMemoryBarrier toDst {
    .sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
    .srcAccessMask       = 0,
    .dstAccessMask       = VK_ACCESS_TRANSFER_WRITE_BIT,
    .oldLayout           = VK_IMAGE_LAYOUT_UNDEFINED,
    .newLayout           = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
    .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
    .image               = image_,
    .subresourceRange    = kWholeImage,
  };
  vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                       VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0,
                       nullptr, 1, &toDst);
}

void DmabufImage::recordRelease(VkCommandBuffer cmd,
                                uint32_t        srcQueueFamily) const
{
  VkImageMemoryBarrier release {
    .sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
    .srcAccessMask       = VK_ACCESS_TRANSFER_WRITE_BIT,
    .dstAccessMask       = 0,
    .oldLayout           = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
    .newLayout           = VK_IMAGE_LAYOUT_GENERAL,
    .srcQueueFamilyIndex = srcQueueFamily,
    .dstQueueFamilyIndex = VK_QUEUE_FAMILY_FOREIGN_EXT,
    .image               = image_,
    .subresourceRange    = kWholeImage,
  };
  vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
                       VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 0,
                       nullptr, 1, &release);
}

bool DmabufImage::publishFence()
{
  if (semaphore_ == VK_NULL_HANDLE) return false;

  VkSemaphoreGetFdInfoKHR get {
    .sType      = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
    .semaphore  = semaphore_,
    .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
  };
  int fenceFd = -1;
  if (device_->getSemaphoreFd()(device_->getDevice(), &get, &fenceFd) !=
      VK_SUCCESS) {
    return false;
  }
  // -1 is legal and means "already signalled": the work finished before the
  // export, so there is nothing for anyone to wait on.
  if (fenceFd < 0) return true;

  // Implicit synchronisation is what GL and EGL consumers use — they do not
  // ask for a fence, they read the one hanging off the buffer. Marked WRITE
  // because we are the writer: a reader must wait for us, and a later writer
  // must wait for the readers.
  dma_buf_import_sync_file import {
    .flags = DMA_BUF_SYNC_WRITE,
    .fd    = static_cast<__s32>(fenceFd),
  };
  const bool ok = ioctl(fd_[0], DMA_BUF_IOCTL_IMPORT_SYNC_FILE, &import) == 0;
  close(fenceFd);
  return ok;
}

}  // namespace canvas
