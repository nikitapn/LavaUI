#pragma once

#include <cstdint>
#include <memory>
#include <vector>

#include <vulkan/vulkan.h>
#include "vk_mem_alloc.h"

#include "util/types.hpp"

class RenderDevice;

/// Packs same-ish-sized images into a few large pages so a wall of them costs
/// one descriptor bind instead of one each.
///
/// The problem it solves is not memory, it is *batching*. `QuadRenderer` binds
/// one `sampler2D` per batch, so every distinct texture ends the batch and
/// starts a new draw — and a frame only has `kMaxDescriptorSetsPerFrame` sets
/// to hand out, past which it silently rebinds the last slot and draws the
/// wrong picture. A grid of album art is exactly the shape that hits both.
/// Atlased, a hundred covers are one bind and one draw.
///
/// **Slots, not shelf packing.** The glyph atlas packs tightly by shelf because
/// glyphs vary wildly in size and are never individually freed. Cover art is
/// the opposite: uniform, and it very much needs freeing — scrolling a library
/// past a VRAM budget is the whole point. A fixed cell grid makes a free list
/// trivial (`freeSlot` returns a cell to a stack) where tight packing would
/// need compaction. Wasted space inside a cell is the price, and for square
/// covers it is close to zero.
///
/// Images that do not fit a cell are refused, and the caller keeps them as
/// standalone textures — a hero image has no business in the cover atlas.
class ImageAtlas {
public:
  /// Where an entry landed. `page` selects the image view to bind; `uv0`/`uv1`
  /// are the sub-rect to sample.
  struct Region {
    uint32_t page = 0;
    vec2     uv0{0.f, 0.f};
    vec2     uv1{1.f, 1.f};
    /// Slot index within the page, needed to free it again.
    uint32_t slot = 0;
    bool     valid = false;
  };

  ImageAtlas() = default;
  ~ImageAtlas() = default;
  ImageAtlas(const ImageAtlas &) = delete;
  ImageAtlas &operator=(const ImageAtlas &) = delete;

  /// `cellSize` is the largest image that can be atlased; `pageSize` must be a
  /// multiple of it. Defaults hold 64 covers of up to 256px per 2048² page,
  /// which is 16 MB of VRAM for a screenful and then some.
  void initialize(RenderDevice &device, uint32_t cellSize = 256,
                  uint32_t pageSize = 2048, uint32_t maxPages = 8);
  void cleanUp();

  /// Copies `rgba` (tightly packed, w*h*4) into a free cell.
  ///
  /// Fails — returning an invalid region — when the image is larger than a
  /// cell or every page is full and no more may be created. Both are the
  /// caller's cue to fall back to a standalone texture.
  Region add(const uint8_t *rgba, uint32_t w, uint32_t h);

  /// Returns a cell to the free list. The pixels stay until overwritten;
  /// nothing samples them because nothing holds the region any more.
  void freeSlot(uint32_t page, uint32_t slot);

  VkImageView pageView(uint32_t page) const;
  uint32_t    pageCount() const { return static_cast<uint32_t>(pages_.size()); }
  uint32_t    cellSize() const { return cellSize_; }

  /// Cells in use / total, for the eviction policy that lives above this.
  uint32_t usedSlots() const { return usedSlots_; }
  uint32_t totalSlots() const {
    return static_cast<uint32_t>(pages_.size()) * slotsPerPage();
  }
  /// Cells the atlas could ever hold, counting pages not yet created.
  ///
  /// The eviction policy above wants this rather than `totalSlots()`: early on
  /// every page that exists is full, and the right answer there is to add a
  /// page, not to start throwing entries out.
  uint32_t capacitySlots() const { return maxPages_ * slotsPerPage(); }
  uint64_t allocatedBytes() const {
    return static_cast<uint64_t>(pages_.size()) * pageSize_ * pageSize_ * 4;
  }

private:
  struct Page {
    VkImage       image      = VK_NULL_HANDLE;
    VmaAllocation allocation = VK_NULL_HANDLE;
    VkImageView   view       = VK_NULL_HANDLE;
    /// Slots never yet handed out; `free` holds returned ones.
    uint32_t              nextFresh = 0;
    std::vector<uint32_t> free;
  };

  uint32_t slotsPerPage() const { return cellsPerRow_ * cellsPerRow_; }
  bool     addPage();

  RenderDevice  *device_     = nullptr;
  uint32_t cellSize_   = 256;
  uint32_t pageSize_   = 2048;
  uint32_t cellsPerRow_ = 8;
  uint32_t maxPages_   = 8;
  uint32_t usedSlots_  = 0;
  std::vector<std::unique_ptr<Page>> pages_;
};
