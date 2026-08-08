#include "dmabuf.hpp"

#include <sys/stat.h>
#include <sys/sysmacros.h>  // major()/minor()
#include <unistd.h>

#include <cstring>

extern "C" {
#include <drm_fourcc.h>
}

namespace lava {
namespace {

/// The format everything below is fixed to.
///
/// Vulkan's B8G8R8A8_UNORM and DRM's XRGB8888 describe the same bytes on a
/// little-endian machine, which is what makes the export a reinterpretation
/// rather than a conversion. Keeping it to one format keeps the negotiation
/// out of the way while the mechanism is being proven.
///
/// X rather than A on the DRM side. The two name identical memory and differ
/// only in whether the fourth channel means anything. A window's content is
/// opaque, and saying so lets the compositor skip blending it against what is
/// behind — cheaper, and it removes a channel that could only ever be wrong.
/// Surfaces that genuinely need transparency will have to negotiate a format
/// rather than inherit this one.
constexpr VkFormat kVkFormat = VK_FORMAT_B8G8R8A8_UNORM;
constexpr uint32_t kDrmFormat = DRM_FORMAT_XRGB8888;

/// Extensions the export path cannot be built without.
const char *const kDeviceExtensions[] = {
    VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
    VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
    VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
};

bool device_matches_drm_fd(VkPhysicalDevice device, int drm_fd) {
  struct stat st{};
  if (fstat(drm_fd, &st) != 0) {
    return false;
  }
  const unsigned want_major = major(st.st_rdev);
  const unsigned want_minor = minor(st.st_rdev);

  VkPhysicalDeviceDrmPropertiesEXT drm{};
  drm.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT;
  VkPhysicalDeviceProperties2 props{};
  props.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
  props.pNext = &drm;
  vkGetPhysicalDeviceProperties2(device, &props);

  // Either node identifies the same GPU; wlroots may hand us a render node or
  // a primary one depending on the backend.
  if (drm.hasRender && static_cast<unsigned>(drm.renderMajor) == want_major &&
      static_cast<unsigned>(drm.renderMinor) == want_minor) {
    return true;
  }
  return drm.hasPrimary &&
         static_cast<unsigned>(drm.primaryMajor) == want_major &&
         static_cast<unsigned>(drm.primaryMinor) == want_minor;
}

}  // namespace

VulkanExporter *VulkanExporter::create(int drm_fd) {
  auto *self = new VulkanExporter();

  VkApplicationInfo app{};
  app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
  app.pApplicationName = "lava-compositor";
  app.apiVersion = VK_API_VERSION_1_2;

  VkInstanceCreateInfo instance_info{};
  instance_info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
  instance_info.pApplicationInfo = &app;
  if (vkCreateInstance(&instance_info, nullptr, &self->instance_) != VK_SUCCESS) {
    wlr_log(WLR_ERROR, "dmabuf: vkCreateInstance failed");
    delete self;
    return nullptr;
  }

  uint32_t count = 0;
  vkEnumeratePhysicalDevices(self->instance_, &count, nullptr);
  std::vector<VkPhysicalDevice> devices(count);
  vkEnumeratePhysicalDevices(self->instance_, &count, devices.data());

  for (VkPhysicalDevice candidate : devices) {
    if (device_matches_drm_fd(candidate, drm_fd)) {
      self->physical_device_ = candidate;
      break;
    }
  }
  if (self->physical_device_ == VK_NULL_HANDLE) {
    // Worth naming precisely: on a hybrid laptop this means the GPU the
    // compositor renders on has no Vulkan driver installed, and falling back
    // to the other one would produce a dmabuf nothing here can import.
    wlr_log(WLR_ERROR,
            "dmabuf: no Vulkan device for the GPU wlroots is using "
            "(%zu Vulkan device(s) present, none matching)",
            devices.size());
    delete self;
    return nullptr;
  }

  VkPhysicalDeviceProperties props{};
  vkGetPhysicalDeviceProperties(self->physical_device_, &props);
  wlr_log(WLR_INFO, "dmabuf: exporting from '%s'", props.deviceName);

  uint32_t family_count = 0;
  vkGetPhysicalDeviceQueueFamilyProperties(self->physical_device_,
                                           &family_count, nullptr);
  std::vector<VkQueueFamilyProperties> families(family_count);
  vkGetPhysicalDeviceQueueFamilyProperties(self->physical_device_,
                                           &family_count, families.data());
  bool found_family = false;
  for (uint32_t i = 0; i < family_count; ++i) {
    if (families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
      self->queue_family_ = i;
      found_family = true;
      break;
    }
  }
  if (!found_family) {
    wlr_log(WLR_ERROR, "dmabuf: no graphics queue family");
    delete self;
    return nullptr;
  }

  const float priority = 1.0f;
  VkDeviceQueueCreateInfo queue_info{};
  queue_info.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
  queue_info.queueFamilyIndex = self->queue_family_;
  queue_info.queueCount = 1;
  queue_info.pQueuePriorities = &priority;

  VkDeviceCreateInfo device_info{};
  device_info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
  device_info.queueCreateInfoCount = 1;
  device_info.pQueueCreateInfos = &queue_info;
  device_info.enabledExtensionCount =
      sizeof(kDeviceExtensions) / sizeof(kDeviceExtensions[0]);
  device_info.ppEnabledExtensionNames = kDeviceExtensions;
  if (vkCreateDevice(self->physical_device_, &device_info, nullptr,
                     &self->device_) != VK_SUCCESS) {
    wlr_log(WLR_ERROR, "dmabuf: vkCreateDevice failed");
    delete self;
    return nullptr;
  }
  vkGetDeviceQueue(self->device_, self->queue_family_, 0, &self->queue_);

  // Extension entry points are not in the loader's static table.
  self->get_memory_fd_ = reinterpret_cast<PFN_vkGetMemoryFdKHR>(
      vkGetDeviceProcAddr(self->device_, "vkGetMemoryFdKHR"));
  self->get_modifier_props_ =
      reinterpret_cast<PFN_vkGetImageDrmFormatModifierPropertiesEXT>(
          vkGetDeviceProcAddr(self->device_,
                              "vkGetImageDrmFormatModifierPropertiesEXT"));
  if (!self->get_memory_fd_ || !self->get_modifier_props_) {
    wlr_log(WLR_ERROR, "dmabuf: missing export entry points");
    delete self;
    return nullptr;
  }

  VkCommandPoolCreateInfo pool_info{};
  pool_info.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
  pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
  pool_info.queueFamilyIndex = self->queue_family_;
  if (vkCreateCommandPool(self->device_, &pool_info, nullptr,
                          &self->command_pool_) != VK_SUCCESS) {
    wlr_log(WLR_ERROR, "dmabuf: vkCreateCommandPool failed");
    delete self;
    return nullptr;
  }

  return self;
}

VulkanExporter::~VulkanExporter() {
  if (device_ != VK_NULL_HANDLE) {
    vkDeviceWaitIdle(device_);
    if (command_pool_ != VK_NULL_HANDLE) {
      vkDestroyCommandPool(device_, command_pool_, nullptr);
    }
    vkDestroyDevice(device_, nullptr);
  }
  if (instance_ != VK_NULL_HANDLE) {
    vkDestroyInstance(instance_, nullptr);
  }
}

std::vector<uint64_t> VulkanExporter::usable_modifiers(VkFormat format) const {
  VkDrmFormatModifierPropertiesListEXT list{};
  list.sType = VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT;
  VkFormatProperties2 props{};
  props.sType = VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2;
  props.pNext = &list;
  vkGetPhysicalDeviceFormatProperties2(physical_device_, format, &props);

  std::vector<VkDrmFormatModifierPropertiesEXT> entries(
      list.drmFormatModifierCount);
  list.pDrmFormatModifierProperties = entries.data();
  vkGetPhysicalDeviceFormatProperties2(physical_device_, format, &props);

  // Not yet intersected with what the compositor's renderer can import.
  //
  // The driver picks from whatever is offered here, and a modifier this device
  // can render into is not necessarily one wlroots reads identically. That is
  // the leading suspect for the colour shortfall noted in `clear_image`, and
  // the negotiation — asking the renderer for its importable modifier set and
  // offering only the intersection — is the next thing to try.
  std::vector<uint64_t> result;
  for (const auto &entry : entries) {
    // Single-plane only. Multi-plane modifiers are legal and would need a
    // descriptor and offset per plane; nothing here produces one yet, and
    // accepting one silently would export a buffer wlroots reads wrongly.
    if (entry.drmFormatModifierPlaneCount != 1) {
      continue;
    }
    if (!(entry.drmFormatModifierTilingFeatures &
          VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT)) {
      continue;
    }

    // Rendering into it is not enough; the driver also has to be willing to
    // export it. Asking now turns a later, much more confusing failure into a
    // modifier that simply is not offered.
    VkPhysicalDeviceExternalImageFormatInfo external{};
    external.sType =
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO;
    external.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;

    VkPhysicalDeviceImageDrmFormatModifierInfoEXT modifier_info{};
    modifier_info.sType =
        VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT;
    modifier_info.drmFormatModifier = entry.drmFormatModifier;
    modifier_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    modifier_info.pNext = &external;

    VkPhysicalDeviceImageFormatInfo2 format_info{};
    format_info.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2;
    format_info.format = format;
    format_info.type = VK_IMAGE_TYPE_2D;
    format_info.tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT;
    format_info.usage =
        VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    format_info.pNext = &modifier_info;

    VkExternalImageFormatProperties external_props{};
    external_props.sType = VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES;
    VkImageFormatProperties2 image_props{};
    image_props.sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2;
    image_props.pNext = &external_props;

    if (vkGetPhysicalDeviceImageFormatProperties2(
            physical_device_, &format_info, &image_props) != VK_SUCCESS) {
      continue;
    }
    if (!(external_props.externalMemoryProperties.externalMemoryFeatures &
          VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT)) {
      continue;
    }
    result.push_back(entry.drmFormatModifier);
  }

  return result;
}

bool VulkanExporter::make_image(uint32_t width, uint32_t height,
                                ExportedImage &out) {
  std::vector<uint64_t> modifiers = usable_modifiers(kVkFormat);
  if (modifiers.empty()) {
    wlr_log(WLR_ERROR, "dmabuf: no exportable modifier for the chosen format");
    return false;
  }

  out.width = width;
  out.height = height;
  out.drm_format = kDrmFormat;

  // The driver picks from the candidate list; which one it took is only known
  // afterwards, which is why the modifier is queried back below rather than
  // assumed.
  VkImageDrmFormatModifierListCreateInfoEXT modifier_list{};
  modifier_list.sType =
      VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT;
  modifier_list.drmFormatModifierCount = static_cast<uint32_t>(modifiers.size());
  modifier_list.pDrmFormatModifiers = modifiers.data();

  VkExternalMemoryImageCreateInfo external_image{};
  external_image.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO;
  external_image.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
  external_image.pNext = &modifier_list;

  VkImageCreateInfo image_info{};
  image_info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
  image_info.pNext = &external_image;
  image_info.imageType = VK_IMAGE_TYPE_2D;
  image_info.format = kVkFormat;
  image_info.extent = {width, height, 1};
  image_info.mipLevels = 1;
  image_info.arrayLayers = 1;
  image_info.samples = VK_SAMPLE_COUNT_1_BIT;
  image_info.tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT;
  image_info.usage =
      VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
  image_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
  image_info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
  if (vkCreateImage(device_, &image_info, nullptr, &out.image) != VK_SUCCESS) {
    wlr_log(WLR_ERROR, "dmabuf: vkCreateImage failed");
    return false;
  }

  VkMemoryRequirements reqs{};
  vkGetImageMemoryRequirements(device_, out.image, &reqs);

  VkPhysicalDeviceMemoryProperties mem_props{};
  vkGetPhysicalDeviceMemoryProperties(physical_device_, &mem_props);
  uint32_t type_index = UINT32_MAX;
  for (uint32_t i = 0; i < mem_props.memoryTypeCount; ++i) {
    if ((reqs.memoryTypeBits & (1u << i)) &&
        (mem_props.memoryTypes[i].propertyFlags &
         VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
      type_index = i;
      break;
    }
  }
  if (type_index == UINT32_MAX) {
    wlr_log(WLR_ERROR, "dmabuf: no device-local memory type");
    destroy_image(out);
    return false;
  }

  // Dedicated because the memory is about to leave this process: a suballocated
  // block would export the whole block, not this image.
  VkMemoryDedicatedAllocateInfo dedicated{};
  dedicated.sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO;
  dedicated.image = out.image;

  VkExportMemoryAllocateInfo export_info{};
  export_info.sType = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO;
  export_info.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
  export_info.pNext = &dedicated;

  VkMemoryAllocateInfo alloc{};
  alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
  alloc.pNext = &export_info;
  alloc.allocationSize = reqs.size;
  alloc.memoryTypeIndex = type_index;
  if (vkAllocateMemory(device_, &alloc, nullptr, &out.memory) != VK_SUCCESS) {
    wlr_log(WLR_ERROR, "dmabuf: vkAllocateMemory failed");
    destroy_image(out);
    return false;
  }
  if (vkBindImageMemory(device_, out.image, out.memory, 0) != VK_SUCCESS) {
    wlr_log(WLR_ERROR, "dmabuf: vkBindImageMemory failed");
    destroy_image(out);
    return false;
  }

  VkImageDrmFormatModifierPropertiesEXT chosen{};
  chosen.sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT;
  if (get_modifier_props_(device_, out.image, &chosen) != VK_SUCCESS) {
    wlr_log(WLR_ERROR, "dmabuf: could not read back the chosen modifier");
    destroy_image(out);
    return false;
  }
  out.modifier = chosen.drmFormatModifier;
  out.plane_count = 1;

  // Stride and offset are what make the exported bytes interpretable; without
  // them the importer has a size and no idea how rows are laid out.
  VkImageSubresource subresource{};
  subresource.aspectMask = VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT;
  VkSubresourceLayout layout{};
  vkGetImageSubresourceLayout(device_, out.image, &subresource, &layout);
  out.offset[0] = static_cast<uint32_t>(layout.offset);
  out.stride[0] = static_cast<uint32_t>(layout.rowPitch);

  VkMemoryGetFdInfoKHR fd_info{};
  fd_info.sType = VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR;
  fd_info.memory = out.memory;
  fd_info.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
  if (get_memory_fd_(device_, &fd_info, &out.fd[0]) != VK_SUCCESS) {
    wlr_log(WLR_ERROR, "dmabuf: vkGetMemoryFdKHR failed");
    destroy_image(out);
    return false;
  }

  wlr_log(WLR_INFO,
          "dmabuf: exported %ux%u fd=%d modifier=0x%016lx stride=%u", width,
          height, out.fd[0], static_cast<unsigned long>(out.modifier),
          out.stride[0]);
  return true;
}

void VulkanExporter::destroy_image(ExportedImage &image) {
  for (int &fd : image.fd) {
    if (fd >= 0) {
      close(fd);
      fd = -1;
    }
  }
  if (image.image != VK_NULL_HANDLE) {
    vkDestroyImage(device_, image.image, nullptr);
    image.image = VK_NULL_HANDLE;
  }
  if (image.memory != VK_NULL_HANDLE) {
    vkFreeMemory(device_, image.memory, nullptr);
    image.memory = VK_NULL_HANDLE;
  }
}

bool VulkanExporter::clear_image(const ExportedImage &image, float r, float g,
                                 float b) {
  VkCommandBufferAllocateInfo alloc{};
  alloc.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
  alloc.commandPool = command_pool_;
  alloc.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
  alloc.commandBufferCount = 1;
  VkCommandBuffer cmd = VK_NULL_HANDLE;
  if (vkAllocateCommandBuffers(device_, &alloc, &cmd) != VK_SUCCESS) {
    return false;
  }

  VkCommandBufferBeginInfo begin{};
  begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
  begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
  vkBeginCommandBuffer(cmd, &begin);

  const VkImageSubresourceRange range{VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};

  VkImageMemoryBarrier to_dst{};
  to_dst.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
  to_dst.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
  to_dst.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
  to_dst.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
  to_dst.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
  to_dst.image = image.image;
  to_dst.subresourceRange = range;
  to_dst.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
  vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                       VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0,
                       nullptr, 1, &to_dst);

  VkClearColorValue colour{};
  colour.float32[0] = r;
  colour.float32[1] = g;
  colour.float32[2] = b;
  colour.float32[3] = 1.0f;
  vkCmdClearColorImage(cmd, image.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                       &colour, 1, &range);

  // Handing the image to another driver means giving up queue ownership as
  // well as settling the layout. GENERAL is the layout an external consumer
  // may assume; FOREIGN_EXT says the next reader is not this Vulkan device.
  VkImageMemoryBarrier release{};
  release.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
  release.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
  release.newLayout = VK_IMAGE_LAYOUT_GENERAL;
  release.srcQueueFamilyIndex = queue_family_;
  release.dstQueueFamilyIndex = VK_QUEUE_FAMILY_FOREIGN_EXT;
  release.image = image.image;
  release.subresourceRange = range;
  release.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
  vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT,
                       VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 0,
                       nullptr, 1, &release);

  vkEndCommandBuffer(cmd);

  VkSubmitInfo submit{};
  submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
  submit.commandBufferCount = 1;
  submit.pCommandBuffers = &cmd;
  vkQueueSubmit(queue_, 1, &submit, VK_NULL_HANDLE);
  // No shared fence yet, so the handover is made safe the blunt way: nothing
  // reads this buffer until the GPU has finished writing it. A moving image
  // will need explicit sync (VK_KHR_external_semaphore_fd) instead.
  //
  // KNOWN GAP — colour fidelity is not exact. Clearing to pure white and to
  // mid-grey both read back exactly; clearing to (0.95, 0.45, 0.10) reads
  // (229, 109, 25) where (242, 115, 26) is expected. Measured with a single
  // compositor instance and against a scene rect that reads exact in the same
  // frame, so it is specific to the imported buffer rather than to the output.
  // Forcing DRM_FORMAT_MOD_LINEAR does not change it, which rules out AMD's
  // DCC compression. Unexplained; see the note in `usable_modifiers`.
  vkQueueWaitIdle(queue_);
  vkFreeCommandBuffers(device_, command_pool_, 1, &cmd);
  return true;
}

// ─── wlr_buffer wrapper ────────────────────────────────────────────────────

namespace {

DmabufBuffer *from_buffer(wlr_buffer *buffer) {
  return reinterpret_cast<DmabufBuffer *>(buffer);
}

void buffer_destroy(wlr_buffer *buffer) { delete from_buffer(buffer); }

bool buffer_get_dmabuf(wlr_buffer *buffer, wlr_dmabuf_attributes *attribs) {
  const ExportedImage *image = from_buffer(buffer)->image;
  *attribs = {};
  attribs->width = static_cast<int32_t>(image->width);
  attribs->height = static_cast<int32_t>(image->height);
  attribs->format = image->drm_format;
  attribs->modifier = image->modifier;
  attribs->n_planes = image->plane_count;
  for (int i = 0; i < image->plane_count; ++i) {
    attribs->offset[i] = image->offset[i];
    attribs->stride[i] = image->stride[i];
    // Borrowed, not given: wlroots imports these and does not close them.
    attribs->fd[i] = image->fd[i];
  }
  return true;
}

const wlr_buffer_impl kBufferImpl = {
    .destroy = buffer_destroy,
    .get_dmabuf = buffer_get_dmabuf,
    .get_shm = nullptr,
    .begin_data_ptr_access = nullptr,
    .end_data_ptr_access = nullptr,
};

}  // namespace

DmabufBuffer *DmabufBuffer::create(ExportedImage *image) {
  auto *self = new DmabufBuffer();
  self->image = image;
  wlr_buffer_init(&self->base, &kBufferImpl, static_cast<int>(image->width),
                  static_cast<int>(image->height));
  return self;
}

}  // namespace lava
