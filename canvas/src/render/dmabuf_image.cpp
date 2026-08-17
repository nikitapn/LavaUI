#include "render/dmabuf_image.hpp"

#include <sys/ioctl.h>
#include <unistd.h>

#include <algorithm>
#include <cstdlib>
#include <iostream>

extern "C" {
#include <drm_fourcc.h>
#include <linux/dma-buf.h>
}

#include "render/render_device.hpp"

namespace canvas {
namespace {

/// The formats the export can take, best first.
///
/// Each pair names the same bytes twice: Vulkan's `B8G8R8A8_SRGB` and DRM's
/// `ARGB8888` describe one little-endian layout, as do `R8G8B8A8_SRGB` and
/// `ABGR8888`. That is what makes the handover a reinterpretation rather than
/// a conversion.
///
/// The order is the whole point of there being two. `R8G8B8A8_SRGB` is the
/// format the engine's render passes are built against, so a frame can be
/// resolved *into* an image of that format — no resolve image per window and
/// no blit per frame. The other is the same picture in the other byte order,
/// reachable only through a converting blit, and is here because a consumer
/// that can import only `ARGB8888` is a consumer this used to work on.
///
/// sRGB rather than UNORM, and it matters on the blit path: `vkCmdBlitImage`
/// converts between formats, so an UNORM destination would linearise the
/// `R8G8B8A8_SRGB` source and write it back without re-encoding — a
/// whole-surface darkening that looks like a blending bug and is not one.
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
struct FormatPair {
  uint32_t drm;
  VkFormat vk;
};
constexpr FormatPair kFormats[] = {
  {DRM_FORMAT_ABGR8888, VK_FORMAT_R8G8B8A8_SRGB},
  {DRM_FORMAT_ARGB8888, VK_FORMAT_B8G8R8A8_SRGB},
};

/// Blit destination only: what an image that is written by a copy needs.
constexpr VkImageUsageFlags kBlitUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT;
constexpr VkFormatFeatureFlags kBlitFeatures =
  VK_FORMAT_FEATURE_TRANSFER_DST_BIT | VK_FORMAT_FEATURE_BLIT_DST_BIT;

/// Resolve target: written by the render pass, and still read afterwards —
/// a backdrop blur blits the frame so far out of it, and a screenshot copies
/// it to a buffer.
constexpr VkImageUsageFlags kRenderUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                                           VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
constexpr VkFormatFeatureFlags kRenderFeatures =
  VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | VK_FORMAT_FEATURE_TRANSFER_SRC_BIT |
  VK_FORMAT_FEATURE_BLIT_SRC_BIT;

constexpr VkImageSubresourceRange kWholeImage {
  VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};

}  // namespace

const std::vector<uint32_t> &DmabufImage::exportFormats()
{
  static const std::vector<uint32_t> formats = [] {
    std::vector<uint32_t> out;
    for (const FormatPair &pair : kFormats) out.push_back(pair.drm);
    return out;
  }();
  return formats;
}

std::vector<uint64_t> DmabufImage::usableModifiers(
  VkPhysicalDevice physical, VkFormat format, VkImageUsageFlags usage,
  VkFormatFeatureFlags required, const std::vector<uint64_t> &importable)
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
    if ((entry.drmFormatModifierTilingFeatures & required) != required) {
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
      .usage  = usage,
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
  const std::vector<ExportFormatSupport> &consumerFormats)
{
  if (!device.canExportDmabuf()) {
    std::cerr << "DmabufImage: this device was not brought up for export — "
                 "call RenderDevice::exportToDrmDevice before init\n";
    return nullptr;
  }
  if (consumerFormats.empty()) {
    std::cerr << "DmabufImage: the consumer named no format it can import\n";
    return nullptr;
  }

  // Pick a format and a modifier: a renderable pair if any candidate offers
  // one, otherwise the first that can at least be blitted into. Renderable
  // wins across formats rather than within one, because saving a per-frame
  // full-screen blit is worth more than any preference between two byte
  // orders that cost the same to produce.
  VkFormat              vkFormat  = VK_FORMAT_UNDEFINED;
  uint32_t              drmFormat = 0;
  std::vector<uint64_t> modifiers;
  bool                  renderable = false;
  VkFormat              blitFormat  = VK_FORMAT_UNDEFINED;
  uint32_t              blitDrm     = 0;
  std::vector<uint64_t> blitModifiers;

  for (const FormatPair &pair : kFormats) {
    const auto said = std::ranges::find_if(
      consumerFormats,
      [&](const ExportFormatSupport &s) { return s.drmFormat == pair.drm; });
    if (said == consumerFormats.end() || said->modifiers.empty()) continue;

    // Only the engine's own colour format can be resolved into: a framebuffer
    // attachment has to match the format its render pass was created with, and
    // an image view may not swizzle one byte order into the other.
    //
    // `LAVA_EXPORT_BLIT=1` takes the old path on a machine where the new one
    // misbehaves, and is how the two are compared: everything downstream of
    // this choice is decided by `renderable()`, so setting it reproduces
    // exactly what this did before.
    static const bool forceBlit = [] {
      const char *v = std::getenv("LAVA_EXPORT_BLIT");
      return v != nullptr && *v != '0';
    }();
    if (!forceBlit && pair.vk == device.colorFormat()) {
      auto renderModifiers =
        usableModifiers(device.physicalDevice(), pair.vk, kRenderUsage,
                        kRenderFeatures, said->modifiers);
      if (!renderModifiers.empty()) {
        vkFormat   = pair.vk;
        drmFormat  = pair.drm;
        modifiers  = std::move(renderModifiers);
        renderable = true;
        break;
      }
    }
    if (blitFormat != VK_FORMAT_UNDEFINED) continue;
    auto plain = usableModifiers(device.physicalDevice(), pair.vk, kBlitUsage,
                                 kBlitFeatures, said->modifiers);
    if (!plain.empty()) {
      blitFormat    = pair.vk;
      blitDrm       = pair.drm;
      blitModifiers = std::move(plain);
    }
  }
  if (!renderable) {
    vkFormat  = blitFormat;
    drmFormat = blitDrm;
    modifiers = std::move(blitModifiers);
  }
  if (modifiers.empty()) {
    std::cerr << "DmabufImage: no modifier this GPU can export is also one "
                 "the consumer can import\n";
    return nullptr;
  }
  const VkImageUsageFlags usage = renderable ? kRenderUsage : kBlitUsage;

  std::unique_ptr<DmabufImage> self(new DmabufImage());
  self->device_     = &device;
  self->width_      = width;
  self->height_     = height;
  self->drmFormat_  = drmFormat;
  self->renderable_ = renderable;

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
    .format        = vkFormat,
    .extent        = {width, height, 1},
    .mipLevels     = 1,
    .arrayLayers   = 1,
    .samples       = VK_SAMPLE_COUNT_1_BIT,
    .tiling        = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
    .usage         = usage,
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
  // Outside VMA, so the ledger would miss it otherwise — and these are one
  // full-size frame each, on a compositor one per surface. Keyed by the memory
  // handle, which is what the destructor frees.
  self->allocatedBytes_ = reqs.size;
  device.gpuLedger().addExternal(
    self->memory_, reqs.size,
    canvas::GpuTag{canvas::GpuCategory::ExportedFrame, 0,
                   renderable ? "dma-buf the frame resolves into"
                              : "dma-buf handed to the compositor"},
    width, height, static_cast<uint32_t>(vkFormat));

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

  if (renderable) {
    // The attachment handle. Identity swizzle and the image's own format,
    // both of which a framebuffer attachment is required to have — which is
    // also why a `B8G8R8A8` image could not be viewed as `R8G8B8A8` and be
    // rendered into as if the byte order agreed.
    VkImageViewCreateInfo viewInfo {
      .sType            = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
      .image            = self->image_,
      .viewType         = VK_IMAGE_VIEW_TYPE_2D,
      .format           = vkFormat,
      .subresourceRange = kWholeImage,
    };
    if (vkCreateImageView(vk, &viewInfo, nullptr, &self->view_) != VK_SUCCESS) {
      std::cerr << "DmabufImage: vkCreateImageView failed\n";
      return nullptr;
    }
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
    "DmabufImage: exported {}x{} fd={} format=0x{:08x} modifier=0x{:016x} "
    "stride={} {}\n",
    width, height, self->fd_[0], self->drmFormat_, self->modifier_,
    self->stride_[0],
    renderable ? "(rendered into directly)" : "(blit destination)");
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
  if (view_ != VK_NULL_HANDLE) vkDestroyImageView(vk, view_, nullptr);
  if (image_ != VK_NULL_HANDLE) vkDestroyImage(vk, image_, nullptr);
  device_->gpuLedger().remove(memory_);
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

void DmabufImage::recordAcquireForRendering(VkCommandBuffer cmd) const
{
  VkImageMemoryBarrier toColor {
    .sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
    .srcAccessMask       = 0,
    .dstAccessMask       = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    .oldLayout           = VK_IMAGE_LAYOUT_UNDEFINED,
    .newLayout           = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
    .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
    .image               = image_,
    .subresourceRange    = kWholeImage,
  };
  // From BOTTOM_OF_PIPE rather than TOP: what has to have finished is the
  // *whole* of the last frame that touched this image, release barrier
  // included.
  vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                       VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0,
                       nullptr, 0, nullptr, 1, &toColor);
}

void DmabufImage::recordAcquireForRead(VkCommandBuffer cmd) const
{
  VkImageMemoryBarrier toSrc {
    .sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
    .srcAccessMask       = 0,
    .dstAccessMask       = VK_ACCESS_TRANSFER_READ_BIT,
    // GENERAL is where `recordRelease` left it, and naming it rather than
    // UNDEFINED is what keeps the pixels: this is the one acquire that wants
    // them.
    .oldLayout           = VK_IMAGE_LAYOUT_GENERAL,
    .newLayout           = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_FOREIGN_EXT,
    .dstQueueFamilyIndex = device_->graphicsQueueFamily(),
    .image               = image_,
    .subresourceRange    = kWholeImage,
  };
  vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                       VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0,
                       nullptr, 1, &toSrc);
}

void DmabufImage::recordRelease(VkCommandBuffer cmd, uint32_t srcQueueFamily,
                                VkImageLayout from) const
{
  const bool wasWrittenByTransfer =
    from == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
  VkImageMemoryBarrier release {
    .sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
    .srcAccessMask       = wasWrittenByTransfer
                             ? VK_ACCESS_TRANSFER_WRITE_BIT
                             : VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    .dstAccessMask       = 0,
    .oldLayout           = from,
    .newLayout           = VK_IMAGE_LAYOUT_GENERAL,
    .srcQueueFamilyIndex = srcQueueFamily,
    .dstQueueFamilyIndex = VK_QUEUE_FAMILY_FOREIGN_EXT,
    .image               = image_,
    .subresourceRange    = kWholeImage,
  };
  vkCmdPipelineBarrier(cmd,
                       wasWrittenByTransfer
                         ? VK_PIPELINE_STAGE_TRANSFER_BIT
                         : VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
                             VK_PIPELINE_STAGE_TRANSFER_BIT,
                       VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 0,
                       nullptr, 1, &release);
}

int DmabufImage::publishFence()
{
  if (semaphore_ == VK_NULL_HANDLE) return -1;

  VkSemaphoreGetFdInfoKHR get {
    .sType      = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
    .semaphore  = semaphore_,
    .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
  };
  int fenceFd = -1;
  if (device_->getSemaphoreFd()(device_->getDevice(), &get, &fenceFd) !=
      VK_SUCCESS) {
    return -1;
  }
  // -1 is legal and means "already signalled": the work finished before the
  // export, so there is nothing for anyone to wait on. The caller falls back
  // to its CPU wait, which costs nothing on a frame that is already done.
  if (fenceFd < 0) return -1;

  // Implicit synchronisation is what GL and EGL consumers use — they do not
  // ask for a fence, they read the one hanging off the buffer. Marked WRITE
  // because we are the writer: a reader must wait for us, and a later writer
  // must wait for the readers.
  dma_buf_import_sync_file import {
    .flags = DMA_BUF_SYNC_WRITE,
    .fd    = static_cast<__s32>(fenceFd),
  };
  // Best effort, and not the caller's problem: the ioctl only serves consumers
  // that read the buffer's own fence, and the fd is going back to the caller
  // either way for the one that asks for it explicitly. Importing does not
  // consume the descriptor.
  ioctl(fd_[0], DMA_BUF_IOCTL_IMPORT_SYNC_FILE, &import);
  return fenceFd;
}

}  // namespace canvas
