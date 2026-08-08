#include "dmabuf.hpp"

#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>  // major()/minor()
#include <unistd.h>

#include <algorithm>
#include <cstring>

extern "C" {
#include <drm_fourcc.h>
#include <linux/dma-buf.h>
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
const char *const kRequiredExtensions[] = {
    VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
    VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
    VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
};

/// Wanted, not needed: without it the handover falls back to a CPU wait.
constexpr const char *kSemaphoreFdExtension =
    VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME;

bool has_extension(VkPhysicalDevice device, const char *name) {
  uint32_t count = 0;
  vkEnumerateDeviceExtensionProperties(device, nullptr, &count, nullptr);
  std::vector<VkExtensionProperties> props(count);
  vkEnumerateDeviceExtensionProperties(device, nullptr, &count, props.data());
  for (const auto &p : props) {
    if (std::strcmp(p.extensionName, name) == 0) {
      return true;
    }
  }
  return false;
}

/// Whether a semaphore signalled on this device can be handed out as a
/// sync_file. Having the extension is not the same as supporting the handle
/// type, and asking is cheap.
bool can_export_sync_fd(VkPhysicalDevice device) {
  VkPhysicalDeviceExternalSemaphoreInfo info{};
  info.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO;
  info.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
  VkExternalSemaphoreProperties props{};
  props.sType = VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES;
  vkGetPhysicalDeviceExternalSemaphoreProperties(device, &info, &props);
  return (props.externalSemaphoreFeatures &
          VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT) != 0;
}

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

VulkanExporter *VulkanExporter::create(wlr_renderer *renderer) {
  const int drm_fd = wlr_renderer_get_drm_fd(renderer);
  if (drm_fd < 0) {
    wlr_log(WLR_ERROR, "dmabuf: renderer has no DRM device");
    return nullptr;
  }

  auto *self = new VulkanExporter();

  // Ask the renderer what it can import before deciding what to produce.
  //
  // Both sides can name a modifier the other cannot read. Exporting from the
  // full set of what this GPU supports and hoping is how a buffer ends up
  // technically mappable and subtly wrong, so the offer is narrowed to the
  // intersection and refused outright if that is empty.
  if (const wlr_drm_format_set *formats =
          wlr_renderer_get_texture_formats(renderer, WLR_BUFFER_CAP_DMABUF)) {
    if (const wlr_drm_format *format =
            wlr_drm_format_set_get(formats, kDrmFormat)) {
      self->importable_.assign(format->modifiers,
                               format->modifiers + format->len);
    }
  }
  if (self->importable_.empty()) {
    wlr_log(WLR_ERROR,
            "dmabuf: the compositor's renderer imports no modifier for "
            "format 0x%08x", kDrmFormat);
    delete self;
    return nullptr;
  }
  wlr_log(WLR_INFO, "dmabuf: renderer imports %zu modifier(s) for this format",
          self->importable_.size());

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
  std::vector<const char *> extensions(
      std::begin(kRequiredExtensions), std::end(kRequiredExtensions));
  self->explicit_sync_ = has_extension(self->physical_device_,
                                       kSemaphoreFdExtension) &&
                         can_export_sync_fd(self->physical_device_);
  if (self->explicit_sync_) {
    extensions.push_back(kSemaphoreFdExtension);
  }
  device_info.enabledExtensionCount = static_cast<uint32_t>(extensions.size());
  device_info.ppEnabledExtensionNames = extensions.data();
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
  if (self->explicit_sync_) {
    self->get_semaphore_fd_ = reinterpret_cast<PFN_vkGetSemaphoreFdKHR>(
        vkGetDeviceProcAddr(self->device_, "vkGetSemaphoreFdKHR"));
    self->explicit_sync_ = self->get_semaphore_fd_ != nullptr;
  }
  wlr_log(WLR_INFO, "dmabuf: handover is %s",
          self->explicit_sync_ ? "fenced (sync_file)"
                               : "a CPU wait (no sync_file export)");
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
    // Offer only what the other side said it could read.
    //
    // On this hardware the driver already chose an importable modifier
    // without being told to, so this changes nothing here — verified by
    // A/B. It is insurance rather than a fix: the two sets are not
    // guaranteed to overlap, and a buffer the consumer cannot read is a
    // failure at import time on hardware nobody tested on.
    if (std::find(importable_.begin(), importable_.end(),
                  entry.drmFormatModifier) == importable_.end()) {
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
    wlr_log(WLR_ERROR,
            "dmabuf: no modifier this GPU can export is also one the "
            "compositor's renderer can import");
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

bool VulkanExporter::attach_fence(int dmabuf_fd, int fence_fd) const {
  // Implicit synchronisation is what GL and EGL consumers use: they do not ask
  // for a fence, they read the one hanging off the buffer. Vulkan does not put
  // one there on its own, so the sync_file our submit produced is inserted by
  // hand. Marked WRITE because we are the writer — a reader must wait for us,
  // and a later writer must wait for the readers.
  dma_buf_import_sync_file import{};
  import.flags = DMA_BUF_SYNC_WRITE;
  import.fd = static_cast<__s32>(fence_fd);
  if (ioctl(dmabuf_fd, DMA_BUF_IOCTL_IMPORT_SYNC_FILE, &import) != 0) {
    return false;
  }
  return true;
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

  // Signalled by the submit and exported as a sync_file, which is what the
  // consumer ends up waiting on. Binary rather than timeline: sync_file has no
  // notion of a counter, and one handover needs one signal.
  VkSemaphore semaphore = VK_NULL_HANDLE;
  if (explicit_sync_) {
    VkExportSemaphoreCreateInfo export_info{};
    export_info.sType = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO;
    export_info.handleTypes = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
    VkSemaphoreCreateInfo semaphore_info{};
    semaphore_info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    semaphore_info.pNext = &export_info;
    if (vkCreateSemaphore(device_, &semaphore_info, nullptr, &semaphore) !=
        VK_SUCCESS) {
      semaphore = VK_NULL_HANDLE;
    }
  }

  VkSubmitInfo submit{};
  submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
  submit.commandBufferCount = 1;
  submit.pCommandBuffers = &cmd;
  if (semaphore != VK_NULL_HANDLE) {
    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores = &semaphore;
  }
  vkQueueSubmit(queue_, 1, &submit, VK_NULL_HANDLE);
  // Hand the GPU's own fence to whoever reads next, instead of blocking this
  // thread until the work is done. The CPU wait was correct for a still
  // image and would serialise every frame once anything animates.
  bool fenced = false;
  if (semaphore != VK_NULL_HANDLE) {
    VkSemaphoreGetFdInfoKHR get{};
    get.sType = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR;
    get.semaphore = semaphore;
    get.handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
    int fence_fd = -1;
    if (get_semaphore_fd_(device_, &get, &fence_fd) == VK_SUCCESS) {
      // -1 is legal and means "already signalled": the work finished before
      // the export, so there is nothing for anyone to wait on.
      if (fence_fd < 0) {
        fenced = true;
      } else {
        fenced = attach_fence(image.fd[0], fence_fd);
        if (!fenced) {
          wlr_log(WLR_ERROR, "dmabuf: could not attach the fence to the buffer");
        }
        close(fence_fd);
      }
    }
    vkDestroySemaphore(device_, semaphore, nullptr);
  }
  // Both, deliberately, and the wait is not redundant yet.
  //
  // Attaching the fence is correct and costs nothing: a consumer that honours
  // implicit synchronisation will wait for exactly this work rather than for
  // the whole queue. But it only helps if the consumer looks, and this one
  // does not — dropping the wait and relying on the fence alone reads the
  // surface before it is written roughly one run in five (see the note below
  // `attach_fence`). So the fence goes on for drivers that respect it, and
  // the wait stays for those that do not.
  //
  // The wait is what has to go before anything animates: it stalls this
  // thread on every frame. Removing it needs the consumer side told to wait —
  // wlroots exposes no acquire-fence for a compositor-owned buffer today.
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
