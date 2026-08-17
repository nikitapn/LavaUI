#pragma once

#include <cstdint>
#include <memory>
#include <vector>

#include <vulkan/vulkan.h>

#include "render/export_format.hpp"

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
/// The image is the frame's *resolve target* where that is possible: the MSAA
/// attachment resolves straight into it at the end of the render pass, so the
/// window needs no single-sample image of its own and no full-screen blit per
/// frame. Whether it is possible is a question about the buffer, not about the
/// engine — see `renderable()` — and where the answer is no the frame is
/// resolved into the window's own image and blitted here, which is what this
/// always did.
class DmabufImage {
 public:
  /// Allocates an exportable image and exports it.
  ///
  /// `consumerFormats` is what the consumer said it can read, best first;
  /// passing an empty list is a request to fail rather than a request to
  /// guess. Returns null on any failure, having said why.
  static std::unique_ptr<DmabufImage> create(
    RenderDevice &device, uint32_t width, uint32_t height,
    const std::vector<ExportFormatSupport> &consumerFormats);

  ~DmabufImage();

  /// The FourCCs worth asking a consumer about, best first.
  ///
  /// Needed *before* there is an image: the consumer has to be asked which
  /// modifiers it can import for a format, and that question needs the format.
  ///
  /// More than one because the ordering encodes a preference the consumer
  /// cannot see. The first names the same byte order as the engine's own
  /// colour format, which is what lets a frame be resolved directly into the
  /// shared image; the rest describe the same pixels differently and cost a
  /// converting blit per frame. A consumer that can import either gets the
  /// cheap one, and one that can only import the other still works.
  static const std::vector<uint32_t> &exportFormats();

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

  /// Whether a render pass can resolve straight into this image.
  ///
  /// True needs two things to have gone right, both settled at creation: the
  /// driver had to offer a modifier whose tiling can be a colour attachment
  /// *and* be exported, and the format the consumer accepted had to be the one
  /// the engine's render passes are built against. Either answer is workable —
  /// see the class comment — and which one this is decides whether the window
  /// owns a resolve image at all.
  bool renderable() const { return renderable_; }

  /// View of the whole image, for use as an attachment. Null unless
  /// `renderable()`.
  VkImageView view() const { return view_; }

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

  /// The same, for a frame that will be resolved into it rather than blitted.
  ///
  /// Also discards, and for the same reason. What it adds over letting the
  /// render pass do its own `UNDEFINED` transition is the ordering: the
  /// previous frame's release barrier is in another command buffer on this
  /// queue, and submissions on one queue are not ordered against each other by
  /// anything else.
  void recordAcquireForRendering(VkCommandBuffer cmd) const;

  /// Takes the image back to read it — the one acquire whose *contents*
  /// matter, so this is a real queue-family acquisition from the consumer
  /// rather than a discard. Pairs with `recordRelease` from `TRANSFER_SRC`.
  void recordAcquireForRead(VkCommandBuffer cmd) const;

  /// Hands the image over: settles the layout and gives up queue ownership.
  ///
  /// `GENERAL` is the layout an external consumer may assume, and
  /// `VK_QUEUE_FAMILY_FOREIGN_EXT` says the next reader is not this Vulkan
  /// device. Without this the other driver reads an image whose tiling state
  /// this one still believes it owns.
  ///
  /// `from` is where the frame left it: `TRANSFER_DST` after a blit,
  /// `TRANSFER_SRC` after a render pass resolved into it (that being the
  /// render pass's final layout) or after a readback.
  void recordRelease(VkCommandBuffer cmd, uint32_t srcQueueFamily,
                     VkImageLayout from = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
    const;

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

  /// Modifiers this device can write and export for `format` under `usage`,
  /// single plane only, intersected with what the consumer can import.
  /// `required` is what the modifier's tiling has to support for the intended
  /// writes to be legal.
  static std::vector<uint64_t> usableModifiers(
    VkPhysicalDevice physical, VkFormat format, VkImageUsageFlags usage,
    VkFormatFeatureFlags required, const std::vector<uint64_t> &importable);

  RenderDevice  *device_ = nullptr;
  VkImage        image_  = VK_NULL_HANDLE;
  VkImageView    view_   = VK_NULL_HANDLE;
  VkDeviceMemory memory_ = VK_NULL_HANDLE;
  /// See `renderable()`.
  bool           renderable_ = false;
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
