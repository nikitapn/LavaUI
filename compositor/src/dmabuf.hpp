#pragma once

#include <cstdint>
#include <vector>

#include <vulkan/vulkan.h>

#include "wlr.hpp"

/// Vulkan rendering that the compositor can composite without a copy.
///
/// This is the seam between the two halves of the desktop. LavaUI clients have
/// no GPU: they publish a draw list and something else draws it. That
/// something else is canvas, which is Vulkan, while the compositor's scene
/// graph is wlroots. Neither can see the other's images — but both speak
/// dmabuf, which is the kernel's name for "a buffer two drivers can share".
///
/// So: allocate a Vulkan image whose memory can be exported as a dmabuf, hand
/// wlroots the file descriptor plus the layout metadata that makes the bytes
/// interpretable, and wrap the result in a `wlr_buffer` the scene graph
/// accepts like any other. No pixels are copied and no format is converted.
///
/// The whole thing rests on both sides being the *same GPU*. A dmabuf can
/// cross devices in principle and is miserable in practice, so the physical
/// device here is chosen by matching wlroots' DRM node rather than by picking
/// whichever Vulkan device enumerates first — see `VulkanExporter::create`.
namespace lava {

/// A Vulkan image that has been exported as a dmabuf.
///
/// Owns the image, its memory, and the exported file descriptors. The
/// descriptors are handed to wlroots by `DmabufBuffer` but stay owned here:
/// wlroots imports them, it does not take them.
struct ExportedImage {
  VkImage image = VK_NULL_HANDLE;
  VkDeviceMemory memory = VK_NULL_HANDLE;
  uint32_t width = 0;
  uint32_t height = 0;
  /// FourCC, as in <drm_fourcc.h> — the language wlroots and the kernel share.
  uint32_t drm_format = 0;
  uint64_t modifier = 0;
  int plane_count = 0;
  int fd[4]{-1, -1, -1, -1};
  uint32_t offset[4]{};
  uint32_t stride[4]{};
};

class VulkanExporter {
 public:
  ~VulkanExporter();

  VulkanExporter(const VulkanExporter &) = delete;
  VulkanExporter &operator=(const VulkanExporter &) = delete;

  /// Brings up Vulkan on the same GPU wlroots is using, and learns what that
  /// renderer is able to import.
  ///
  /// Takes the renderer rather than a file descriptor because two things have
  /// to agree and both come from it: the DRM node picks the physical device
  /// (via VK_EXT_physical_device_drm), and the renderer's texture formats say
  /// which modifiers it can actually read. Returns null if no Vulkan device
  /// corresponds to that node — on a hybrid laptop that usually means the
  /// driver for that GPU is not installed, which is worth saying out loud
  /// rather than silently rendering on the other one.
  static VulkanExporter *create(wlr_renderer *renderer);

  /// Allocates an image that can be exported, and exports it.
  bool make_image(uint32_t width, uint32_t height, ExportedImage &out);
  void destroy_image(ExportedImage &image);

  /// Fills the image with one colour and leaves it ready to be read by
  /// another driver. Stands in for canvas replaying a draw list; what matters
  /// for now is that the pixels arrive at all.
  bool clear_image(const ExportedImage &image, float r, float g, float b);

 private:
  VulkanExporter() = default;

  VkInstance instance_ = VK_NULL_HANDLE;
  VkPhysicalDevice physical_device_ = VK_NULL_HANDLE;
  VkDevice device_ = VK_NULL_HANDLE;
  VkQueue queue_ = VK_NULL_HANDLE;
  uint32_t queue_family_ = 0;
  VkCommandPool command_pool_ = VK_NULL_HANDLE;

  PFN_vkGetMemoryFdKHR get_memory_fd_ = nullptr;
  PFN_vkGetImageDrmFormatModifierPropertiesEXT get_modifier_props_ = nullptr;

  /// Modifiers this device can render into and export, single-plane only,
  /// intersected with what the compositor's renderer can import.
  std::vector<uint64_t> usable_modifiers(VkFormat format) const;

  /// What the renderer on the other side of the handover accepts. Empty means
  /// it advertised none for our format, which is a reason to refuse rather
  /// than to guess.
  std::vector<uint64_t> importable_;
};

/// An `ExportedImage` presented to wlroots as a buffer.
///
/// `wlr_buffer` is an interface, not a class: wlroots calls back for the
/// dmabuf attributes when a renderer needs to import it. Deriving lets the
/// callbacks recover this object from the `wlr_buffer *` they are handed,
/// since the base is the first member.
struct DmabufBuffer {
  wlr_buffer base{};
  ExportedImage *image = nullptr;

  /// The returned buffer is owned by the caller; drop it with
  /// `wlr_buffer_drop`. It does not take ownership of `image`.
  static DmabufBuffer *create(ExportedImage *image);
};

}  // namespace lava
