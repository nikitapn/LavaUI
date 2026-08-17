#pragma once

// One answer to "what is in VRAM, and why".
//
// The ledger (`gpu_ledger.hpp`) knows every allocation and who asked for it.
// This adds the things an allocation list cannot say on its own: how full the
// atlases are, which cached pictures are resident and whether they are still
// referenced, what each window's extent is — and the driver's own number, so a
// reader can see how much of `nvidia-smi` this process accounts for.
//
// Plain structs with no Vulkan in them: this is what crosses the control plane
// to a debug app, and what `printGpuReport` writes to a log.

#include <cstdint>
#include <iosfwd>
#include <string>
#include <vector>

#include "render/gpu_ledger.hpp"

class RenderDevice;

namespace canvas {

/// One atlas page. Glyph atlases are one page that doubles; image atlases are
/// several fixed-size pages.
struct GpuAtlasPage {
  enum class Kind : uint32_t { Glyph = 0, Image = 1 };
  Kind     kind   = Kind::Glyph;
  uint32_t page   = 0;
  uint32_t width  = 0;
  uint32_t height = 0;
  uint64_t bytes  = 0;
  /// Glyph atlas: rows packed so far against `height`. Image atlas: cells used
  /// against cells per page. Both as a percentage, because "how full" is the
  /// question either way.
  uint32_t fillPercent = 0;
  /// Glyph atlas only.
  uint32_t generation = 0;
  uint32_t glyphs     = 0;
  uint32_t faces      = 0;
  /// Image atlas only.
  uint32_t slotsUsed  = 0;
  uint32_t slotsTotal = 0;
  uint32_t cellSize   = 0;
  /// Where `dumpAtlasPages` wrote this page, if it was asked to.
  std::string pngPath;
};

/// A window, and what its attachments cost.
struct GpuWindowReport {
  uint32_t id      = 0;
  uint32_t width   = 0;
  uint32_t height  = 0;
  uint32_t samples = 1;
  bool     windowed = false;
  /// Everything in the ledger tagged with this window.
  uint64_t bytes = 0;
  /// The name a caller knows it by. Canvas has no titles, so this is filled in
  /// by whoever assembles the report for display — a compositor joins its
  /// surface titles on `id`.
  std::string title;
};

struct GpuTextureReport {
  std::string key;
  uint64_t    bytes      = 0;
  uint32_t    width      = 0;
  uint32_t    height     = 0;
  uint32_t    refCount   = 0;
  uint32_t    windowPins = 0;
  bool        atlased    = false;
  bool        dormant    = false;
  bool        external   = false;
};

/// The texture cache's own accounting, as opposed to the ledger's.
struct GpuTextureCacheReport {
  uint64_t imageBytes         = 0;
  uint64_t dormantBytes       = 0;
  uint64_t dormantBudgetBytes = 0;
  uint64_t atlasBytes         = 0;
  uint64_t cacheHits          = 0;
  uint64_t evictions          = 0;
  uint32_t textures           = 0;
  uint32_t pinnedTextures     = 0;
  uint32_t atlasSlotsUsed     = 0;
  uint32_t atlasSlotsCapacity = 0;
  uint32_t dormantSlots       = 0;
  uint32_t pendingSlots       = 0;
};

struct GpuReport {
  std::string deviceName;
  /// The sample count every window's colour and depth attachment is multiplied
  /// by, and the highest the device would allow.
  uint32_t samples    = 1;
  uint32_t maxSamples = 1;

  /// What the driver attributes to this process, via VMA's budget query.
  uint64_t heapUsageBytes  = 0;
  uint64_t heapBudgetBytes = 0;
  uint64_t heapSizeBytes   = 0;
  /// What VMA has allocated, and the blocks it holds to serve those.
  uint64_t vmaAllocatedBytes = 0;
  uint64_t vmaBlockBytes     = 0;

  GpuLedgerTotals              totals;
  std::vector<GpuWindowReport>  windows;
  std::vector<GpuAllocation>    allocations;
  std::vector<GpuAtlasPage>     atlases;
  std::vector<GpuTextureReport> textures;
  GpuTextureCacheReport         cache;
};

/// Assembles a report. Cheap: a few locks and some copying, no GPU work.
///
/// Called on the thread that owns the window list — see
/// `RenderDevice::windowsSnapshot`.
GpuReport buildGpuReport(RenderDevice &device);

/// Writes every atlas page in `pages` to `dir` as a PNG and records where.
///
/// Not cheap and not free of side effects: each page is copied off the GPU,
/// which waits for the device and moves the image through TRANSFER_SRC and
/// back. Call it when someone asks, on the render thread, and not per frame.
/// Returns how many pages were written.
size_t dumpAtlasPages(RenderDevice &device, const std::string &dir,
                      std::vector<GpuAtlasPage> &pages);

/// Human-readable, for `LAVA_VRAM_STATS` and for a terminal.
void printGpuReport(const GpuReport &report, std::ostream &out,
                    bool verbose = false);

}  // namespace canvas
