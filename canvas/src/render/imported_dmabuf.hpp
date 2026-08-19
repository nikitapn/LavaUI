#pragma once

#include <cstdint>
#include <memory>

#include <vulkan/vulkan.h>

class RenderDevice;

namespace canvas {

/// What another driver published: a dma-buf plus the layout metadata that
/// makes the bytes interpretable. Fds are borrowed; the importer dups what
/// it needs. See `ImportedDmabuf`.
struct DmabufImport {
  uint32_t width     = 0;
  uint32_t height    = 0;
  uint32_t drmFormat = 0;
  uint64_t modifier  = 0;
  int      planeCount = 0;
  int      fd[4]{-1, -1, -1, -1};
  uint32_t offset[4]{};
  uint32_t stride[4]{};
};

/// The reverse of `DmabufImage`: an image this engine *reads* that another
/// driver wrote.
///
/// Same two Vulkan devices, same GPU, same kernel object. Canvas already
/// exports this way so wlroots can composite a client; importing is how a
/// compositor-side effect (frost) samples the scene wlroots just drew
/// without a CPU round trip. The bytes never leave the GPU.
///
/// The image is a blit source, not a sampled texture. Modifier-tiled
/// render targets are not always sampleable, and the caller usually wants
/// a crop of a full-output capture rather than the whole buffer. Blit
/// handles both the crop and the FourCC → `R8G8B8A8_UNORM` swizzle.
class ImportedDmabuf {
 public:
  /// Imports `src`. Null on any failure, having said why (the first few
  /// times). The caller's fds stay owned by the caller.
  static std::unique_ptr<ImportedDmabuf> create(RenderDevice        &device,
                                                const DmabufImport &src);

  ~ImportedDmabuf();

  ImportedDmabuf(const ImportedDmabuf &)            = delete;
  ImportedDmabuf &operator=(const ImportedDmabuf &) = delete;

  VkImage  image() const { return image_; }
  VkFormat vkFormat() const { return vkFormat_; }
  uint32_t width() const { return width_; }
  uint32_t height() const { return height_; }
  /// True for XRGB/XBGR: the fourth channel is padding, not coverage.
  bool opaqueAlpha() const { return opaqueAlpha_; }

  /// Waits for the producer to finish writing. Best-effort: uses the
  /// dma-buf's sync_file when the kernel has one, else poll() on the fd.
  /// A timeout still returns; the blit may then see a torn frame rather
  /// than stall the compositor indefinitely.
  void waitReady(int timeoutMs = 250) const;

  /// Queue-acquires from the foreign device and leaves the image in
  /// `TRANSFER_SRC_OPTIMAL`. `GENERAL` is the layout a compositor's
  /// renderer typically releases in.
  void recordAcquire(VkCommandBuffer cmd) const;

 private:
  ImportedDmabuf() = default;

  static std::unique_ptr<ImportedDmabuf> createTiled(
    RenderDevice &device, const DmabufImport &src, VkFormat format,
    bool opaqueAlpha);
  static std::unique_ptr<ImportedDmabuf> createLinear(
    RenderDevice &device, const DmabufImport &src, VkFormat format,
    bool opaqueAlpha);
  static bool bindImportedMemory(ImportedDmabuf &self, int fd);

  RenderDevice *device_ = nullptr;
  VkImage        image_  = VK_NULL_HANDLE;
  VkDeviceMemory memory_ = VK_NULL_HANDLE;
  VkFormat       vkFormat_ = VK_FORMAT_UNDEFINED;
  uint32_t       width_  = 0;
  uint32_t       height_ = 0;
  bool           opaqueAlpha_ = false;
  /// Borrowed plane-0 fd, for `waitReady`. Not closed here.
  int waitFd_ = -1;
};

}  // namespace canvas
