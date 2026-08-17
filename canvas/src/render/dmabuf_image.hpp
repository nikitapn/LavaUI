#pragma once

#include <cstdint>
#include <memory>
#include <vector>

#include <vulkan/vulkan.h>

class RenderDevice;

namespace canvas {

/// An image this engine renders into and another driver reads.
///
/// The seam between a renderer and a compositor. Canvas draws with Vulkan; a
/// wlroots scene graph does not speak Vulkan, and neither can see the other's
/// images. Both speak dmabuf, which is the kernel's name for "a buffer two
/// drivers can share" — so the image is allocated with memory that can leave
/// the process, and what crosses over is a file descriptor plus the layout
/// metadata that makes the bytes interpretable. No pixels are copied and no
/// format is converted.
///
/// Two agreements make that work, and both are negotiated rather than assumed:
///
///  * the *device*. `RenderDevice::exportToDrmDevice` pins the GPU to the one
///    the consumer already uses. A dmabuf can cross devices in principle and
///    is miserable in practice.
///  * the *modifier* — how the bytes are tiled. The driver picks from a
///    candidate list, and the list offered here is the intersection of what
///    this GPU can render into and export with what the consumer says it can
///    import. An empty intersection is a refusal, not a guess.
///
/// The image is a blit destination, not a render target: a frame is drawn into
/// the window's own MSAA attachment and resolved as usual, and only the
/// resolve is blitted here. That keeps every render pass and pipeline
/// independent of the fact that anyone is exporting at all.
class DmabufImage {
 public:
  /// Allocates an exportable image and exports it.
  ///
  /// `importableModifiers` is what the consumer said it can read; passing an
  /// empty list is a request to fail rather than a request to guess. Returns
  /// null on any failure, having said why.
  static std::unique_ptr<DmabufImage> create(
    RenderDevice &device, uint32_t width, uint32_t height,
    const std::vector<uint64_t> &importableModifiers);

  ~DmabufImage();

  /// The FourCC every exported image uses today.
  ///
  /// Needed *before* there is an image: the consumer has to be asked which
  /// modifiers it can import for a format, and that question needs the format.
  static uint32_t exportFormat();

  DmabufImage(const DmabufImage &)            = delete;
  DmabufImage &operator=(const DmabufImage &) = delete;

  // ─── What the consumer needs to import it ────────────────────────────────
  //
  // The descriptors stay owned here. An importer reads them; it does not take
  // them, and closing one on the other side is a use-after-free here.

  uint32_t width() const { return width_; }
  uint32_t height() const { return height_; }
  /// FourCC, as in <drm_fourcc.h> — the language the kernel and wlroots share.
  uint32_t drmFormat() const { return drmFormat_; }
  uint64_t modifier() const { return modifier_; }
  int      planeCount() const { return 1; }
  int      fd(int plane) const { return fd_[plane]; }
  uint32_t offset(int plane) const { return offset_[plane]; }
  uint32_t stride(int plane) const { return stride_[plane]; }

  // ─── What the renderer needs to write into it ────────────────────────────

  VkImage image() const { return image_; }

  /// Semaphore the submit that writes this image must signal, or null when
  /// the device cannot export one. See `publishFence`.
  VkSemaphore handoverSemaphore() const { return semaphore_; }

  /// Puts the image in a state a blit can write to.
  ///
  /// Discards whatever was there: every frame overwrites the whole surface, so
  /// `UNDEFINED` as the old layout is both true and the cheapest thing to say.
  /// It is also what makes reacquiring after a release to a foreign queue a
  /// non-question.
  void recordAcquire(VkCommandBuffer cmd) const;

  /// Hands the image over: settles the layout and gives up queue ownership.
  ///
  /// `GENERAL` is the layout an external consumer may assume, and
  /// `VK_QUEUE_FAMILY_FOREIGN_EXT` says the next reader is not this Vulkan
  /// device. Without this the other driver reads an image whose tiling state
  /// this one still believes it owns.
  void recordRelease(VkCommandBuffer cmd, uint32_t srcQueueFamily) const;

  /// Exports the handover semaphore as a sync_file. Call after the submit that
  /// signals it. The caller owns the returned fd; -1 means there is no fence
  /// and the frame has to be waited for on the CPU instead.
  ///
  /// Two consumers are served by the one export, because there are two ways to
  /// be told when a buffer is finished and neither covers everything:
  ///
  ///   * *Implicit* — the fence is hung off the buffer here, where a GL or EGL
  ///     importer reads it without being asked. Vulkan does not put one there
  ///     on its own. NVIDIA has never honoured these.
  ///   * *Explicit* — the fd goes back to the caller, to be handed to a
  ///     consumer that takes an acquire fence (`wlr_scene_buffer`'s wait
  ///     timeline). This is the one that lets the frame end at the submit
  ///     rather than at the completion.
  ///
  /// Exporting resets the semaphore, so this happens once per frame and the
  /// same fd answers both.
  int publishFence();

  /// Whether `publishFence` can do anything at all.
  bool fenced() const { return semaphore_ != VK_NULL_HANDLE; }

 private:
  DmabufImage() = default;

  /// Modifiers this device can render into and export for `format`, single
  /// plane only, intersected with what the consumer can import.
  static std::vector<uint64_t> usableModifiers(
    VkPhysicalDevice physical, VkFormat format,
    const std::vector<uint64_t> &importable);

  RenderDevice  *device_ = nullptr;
  VkImage        image_  = VK_NULL_HANDLE;
  VkDeviceMemory memory_ = VK_NULL_HANDLE;
  /// Signalled by the submit and exported as a sync_file. Binary rather than
  /// timeline: sync_file has no notion of a counter, and one handover needs
  /// one signal. Reused across frames — exporting a sync_file resets the
  /// payload to unsignalled, which is exactly the per-frame lifecycle needed.
  VkSemaphore semaphore_ = VK_NULL_HANDLE;

  /// What `vkAllocateMemory` reserved, as reported to `GpuLedger`.
  uint64_t allocatedBytes_ = 0;
  uint32_t width_     = 0;
  uint32_t height_    = 0;
  uint32_t drmFormat_ = 0;
  uint64_t modifier_  = 0;
  int      fd_[4]{-1, -1, -1, -1};
  uint32_t offset_[4]{};
  uint32_t stride_[4]{};
};

}  // namespace canvas
