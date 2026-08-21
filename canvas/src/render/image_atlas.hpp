#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

#include <vulkan/vulkan.h>
#include "vk_mem_alloc.h"

#include "util/types.hpp"

class RenderDevice;

/// Packs same-ish-sized images into a few large pages, so a wall of them is a
/// handful of allocations rather than one each.
///
/// **This is no longer about batching.** It was: `QuadRenderer` used to bind
/// one `sampler2D` per batch, so every distinct texture ended the batch, and a
/// grid of album art both fragmented the frame and ran the descriptor table
/// out. That is gone — the table is bindless (`kDesiredBindlessTextures`, 4096
/// where the device allows it), the index rides on the vertex and the
/// instance, and `Batch` has no texture field at all. Atlasing changes neither
/// the batch count nor the draw count today.
///
/// What is left is smaller and worth stating honestly, because it decides
/// whether an image belongs here at all:
///   - one `VkImage` per page instead of one per entry;
///   - one descriptor write per frame instead of one per *visible* entry.
///
/// Neither is free memory. A page is charged in full the moment it exists, so
/// the atlas only saves anything while entries fill the cells they occupy —
/// pack N images of side S into cells of side C and the page holds
/// `(S/C)²` of useful pixels. Well below that and a standalone texture per
/// image is genuinely cheaper, which is why `Grid.iconPixels` in the launcher
/// decodes onto the cell size rather than near it.
///
/// Pages carry **no mip chain** (`addPage` asks for one level), where
/// `createStandaloneTexture` builds a full one. Minifying an atlased image is
/// therefore bilinear-only, and an entry decoded much larger than it draws
/// will shimmer when it moves. Mips would need per-cell padding to stop
/// coarse levels bleeding across the grid; decoding closer to the drawn size
/// is the cheaper answer and the one taken.
///
/// **Slots, not shelf packing.** The glyph atlas packs tightly by shelf because
/// glyphs vary wildly in size and are never individually freed. Cover art is
/// the opposite: uniform, and it very much needs freeing — scrolling a library
/// past a VRAM budget is the whole point. A fixed cell grid makes a free list
/// trivial (`freeSlot` returns a cell to a stack) where tight packing would
/// need compaction.
///
/// **Several cell sizes, allocated on demand.** One cell size cannot be right
/// for every display: the app grid's icons land near 106px at 1080p and 221px
/// at 4K, and a single 256px cell throws away 44% of its page at the first and
/// none at the second. So there is a class per size in `kCellSizes`, and a
/// page for a class is created only when something lands in it — a machine
/// with one display therefore allocates one class and behaves exactly like the
/// single-size atlas this replaced, while a mixed-DPI one gets both without
/// needing a policy for it.
///
/// Every class holds `kCellsPerRow²` cells, so a page is `cellSize` × 8 square
/// and the small classes are cheap to open: 4 MiB at 128px against 16 MiB at
/// 256px. That the slot count per page is the *same* for every class is what
/// keeps the eviction policy above this one number rather than one per class.
/// `maxPages` is a budget across all classes together, so the worst case is
/// unchanged from when there was only one.
///
/// `add` prefers the tightest class that fits, then a new page of it, and only
/// then an existing page of a larger class — wasting part of a big cell beats
/// refusing an image that then costs a texture of its own.
///
/// Images larger than `largestCell()` are refused, and the caller keeps them
/// as standalone textures — a hero image has no business in the cover atlas.
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

  /// `maxPages` is the page budget across every size class, so the ceiling is
  /// still `maxPages` pages of the largest cell — 128 MiB at the defaults,
  /// exactly what the single-class atlas cost.
  void initialize(RenderDevice &device, uint32_t maxPages = 8);
  void cleanUp();

  /// Copies `rgba` (tightly packed, w*h*4) into a free cell.
  ///
  /// Fails — returning an invalid region — when the image is larger than
  /// `largestCell()`, or every page of every class it could use is full and
  /// the budget is spent. Both are the caller's cue to fall back to a
  /// standalone texture.
  Region add(const uint8_t *rgba, uint32_t w, uint32_t h);

  /// Returns a cell to the free list. The pixels stay until overwritten;
  /// nothing samples them because nothing holds the region any more.
  void freeSlot(uint32_t page, uint32_t slot);

  VkImageView pageView(uint32_t page) const;
  uint32_t    pageCount() const { return static_cast<uint32_t>(pages_.size()); }

  /// Asked per page, because pages no longer agree: each belongs to a class.
  uint32_t pageCellSize(uint32_t page) const;
  uint32_t pageSize(uint32_t page) const;

  /// The same for every class by construction, which is the point of fixing
  /// `kCellsPerRow` rather than the page extent.
  static constexpr uint32_t slotsPerPage() {
    return kCellsPerRow * kCellsPerRow;
  }
  /// Largest image the atlas will accept at all.
  static constexpr uint32_t largestCell() { return kCellSizes.back(); }

  /// The page's image, so a debug tool can read the pixels back and show what
  /// the packing actually looks like. Null for a page that does not exist.
  VkImage pageImage(uint32_t page) const;

  /// Cells handed out on one page, counting those returned to its free list as
  /// free. Says which page a wall of covers actually landed on.
  uint32_t pageUsedSlots(uint32_t page) const;
  uint32_t slotsPerPageCount() const { return slotsPerPage(); }

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
  uint64_t allocatedBytes() const;

private:
  /// Cells along one edge of a page, for every class. Fixed rather than
  /// derived from a page extent so that one slot means the same thing in
  /// every class — see the note about the eviction policy above.
  static constexpr uint32_t kCellsPerRow = 8;

  /// The classes, ascending. 256 is what the largest display's icons want;
  /// 128 is what a 1080p one wants; 192 sits between because 1440p lands
  /// there and because it is the size the app grid used when there was only
  /// one class. 64 catches tray and dock icons, which are smaller again.
  static constexpr std::array<uint32_t, 4> kCellSizes{64, 128, 192, 256};

  struct Page {
    VkImage       image      = VK_NULL_HANDLE;
    VmaAllocation allocation = VK_NULL_HANDLE;
    VkImageView   view       = VK_NULL_HANDLE;
    /// Which class this page belongs to; its extent is this × `kCellsPerRow`.
    uint32_t cellSize = 0;
    /// Slots never yet handed out; `free` holds returned ones.
    uint32_t              nextFresh = 0;
    std::vector<uint32_t> free;

    uint32_t extent() const { return cellSize * kCellsPerRow; }
    bool     hasRoom() const {
      return !free.empty() || nextFresh < slotsPerPage();
    }
  };

  /// Index into `kCellSizes` of the tightest class that fits `side`, or -1
  /// when nothing does.
  static int classFor(uint32_t side);
  /// Existing page of exactly `cellSize` with a slot going spare, or npos.
  size_t pageWithRoom(uint32_t cellSize) const;
  bool   addPage(uint32_t cellSize);

  RenderDevice *device_    = nullptr;
  uint32_t      maxPages_  = 8;
  uint32_t      usedSlots_ = 0;
  std::vector<std::unique_ptr<Page>> pages_;
};
