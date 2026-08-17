#pragma once

// Who is holding the VRAM.
//
// `nvidia-smi` says a number and nothing else, and a Vulkan renderer's VMA
// statistics say *how much* without saying what for. This is the missing half:
// every allocation the engine makes, tagged with the thing that asked for it,
// so a report can say "these four windows are 1 GB of MSAA attachments" rather
// than "1 GB".
//
// It is a debug facility that is always on, deliberately. Allocations happen at
// window creation, resize, atlas growth and texture upload — never per frame —
// so a mutex and a string per allocation cost nothing measurable, and a ledger
// that has to be switched on is one that is off when the interesting thing
// happens.
//
// Every VMA allocation in the engine is made in `RenderDevice::createImage` or
// `RenderDevice::createBuffer`, which is what makes the inventory complete
// rather than a sample. Memory allocated outside VMA — the exported and
// imported dma-bufs, which need external-memory handles VMA does not hand out
// — registers through `addExternal`, and is reported separately because only
// one of the two is really ours.

#include <cstdint>
#include <mutex>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace canvas {

/// What an allocation is *for*. The report groups by this, so it names roles
/// ("the depth attachment of a window") rather than Vulkan kinds ("an image").
enum class GpuCategory : uint32_t {
  /// Tagged by nobody. Shows up in the report as a nag rather than hiding.
  Unlabeled = 0,
  /// Per-window scene attachments. Three separate categories because telling
  /// them apart is the entire point on a machine where each window pays for a
  /// multisampled colour *and* a multisampled depth buffer.
  WindowColor,
  WindowDepth,
  WindowResolve,
  /// Host-visible buffer a window reads pixels back through.
  WindowStaging,
  /// `BlurPass` scratch, sized to the window it belongs to.
  BlurScratch,
  /// `TextRenderer`'s glyph atlas — one per window, doubling as it fills.
  GlyphAtlas,
  /// `ImageAtlas` pages.
  ImageAtlas,
  /// Standalone images in `TextureManager`'s cache.
  Texture,
  /// `QuadRenderer` vertex/index/instance arenas, per frame slot.
  VertexArena,
  /// `ComputePhysics` storage buffers.
  Physics,
  /// Upload/readback scratch that is freed again immediately.
  Staging,
  /// A frame handed to a compositor as a dma-buf. Ours, and not VMA's.
  ExportedFrame,
  /// A client buffer mapped in for sampling. Someone else's memory, counted
  /// separately so it is never added to what this process is holding.
  ImportedSurface,
  Count,
};

const char *gpuCategoryName(GpuCategory category);

/// True for the one category whose bytes belong to another process.
bool gpuCategoryIsForeign(GpuCategory category);

/// What a caller says about the allocation it is asking for.
///
/// `detail` is copied, so a caller may build it on the stack. `windowId` is an
/// `AppWindow::id`, or 0 for something the device owns outright.
struct GpuTag {
  GpuCategory      category = GpuCategory::Unlabeled;
  uint32_t         windowId = 0;
  std::string_view detail{};
};

/// One live allocation.
struct GpuAllocation {
  GpuCategory category = GpuCategory::Unlabeled;
  uint32_t    windowId = 0;
  std::string detail;
  uint64_t    bytes = 0;
  /// False for buffers, so the report can skip the image columns.
  bool     isImage = false;
  uint32_t width   = 0;
  uint32_t height  = 0;
  uint32_t samples = 1;
  uint32_t mips    = 1;
  /// `VkFormat` as a plain integer — the ledger does not include Vulkan
  /// headers into anything that only wants to *read* a report.
  uint32_t format = 0;
  /// `VkImageUsageFlags` or `VkBufferUsageFlags`, same reason.
  uint32_t usage = 0;
  /// Allocation order, so a report can show what appeared since the last look.
  uint64_t sequence = 0;
  /// Queued for destruction but not yet freed — still occupying memory,
  /// waiting for the submissions that might reference it to retire.
  bool retiring = false;
};

/// Live allocations, by category and in total. Foreign (imported) bytes are
/// kept out of `bytes` and reported on their own.
struct GpuLedgerTotals {
  uint64_t bytes         = 0;
  uint64_t foreignBytes  = 0;
  uint64_t retiringBytes = 0;
  uint32_t count         = 0;
  uint64_t byCategory[static_cast<size_t>(GpuCategory::Count)]{};
};

class GpuLedger {
 public:
  /// `key` is the `VmaAllocation` (or, for external memory, whatever handle
  /// the owner will call `remove` with). Only used for identity.
  void addImage(const void *key, uint64_t bytes, const GpuTag &tag,
                uint32_t width, uint32_t height, uint32_t samples,
                uint32_t mips, uint32_t format, uint32_t usage);
  void addBuffer(const void *key, uint64_t bytes, const GpuTag &tag,
                 uint32_t usage);
  /// Memory allocated outside VMA: `DmabufImage` exports and dma-buf imports.
  void addExternal(const void *key, uint64_t bytes, const GpuTag &tag,
                   uint32_t width, uint32_t height, uint32_t format);
  /// Marks an allocation as queued for destruction. It stays in the ledger,
  /// because it stays in memory: `destroyImageDeferred` waits for in-flight
  /// submissions, and a report that dropped it here would show less VRAM in
  /// use than the driver does.
  void markRetiring(const void *key);
  void remove(const void *key);

  /// Retags a live allocation. For the window attachments, whose owner is
  /// known only after `RenderWindow` learns its id.
  void retag(const void *key, const GpuTag &tag);

  std::vector<GpuAllocation> snapshot() const;
  GpuLedgerTotals            totals() const;

 private:
  mutable std::mutex                              mu_;
  std::unordered_map<const void *, GpuAllocation> live_;
  uint64_t                                        nextSequence_ = 1;
};

}  // namespace canvas
