#include <algorithm>
#include <cstring>
#include <iostream>

#include "render/image_atlas.hpp"
#include "render/render_device.hpp"

namespace {
/// Stable storage for the ledger's `std::string_view` detail, one per class.
std::string_view pageDetail(uint32_t cellSize)
{
  switch (cellSize) {
  case 64:  return "page, 64px cells";
  case 128: return "page, 128px cells";
  case 192: return "page, 192px cells";
  case 256: return "page, 256px cells";
  default:  return "page";
  }
}
}  // namespace

void ImageAtlas::initialize(RenderDevice &device, uint32_t maxPages)
{
  device_   = &device;
  maxPages_ = maxPages > 0 ? maxPages : 1;
  std::cout << "ImageAtlas: " << slotsPerPage() << " cells per page, classes";
  for (uint32_t cell : kCellSizes) {
    std::cout << ' ' << cell << "px(" << cell * kCellsPerRow << "²)";
  }
  std::cout << ", max " << maxPages_ << " pages across all of them\n";
}

void ImageAtlas::cleanUp()
{
  if (device_) {
    for (auto &page : pages_) {
      // Immediate, not deferred: cleanUp runs after a device wait, and the
      // deferred queue would be drained at the same moment anyway.
      if (page->view != VK_NULL_HANDLE) {
        vkDestroyImageView(device_->getDevice(), page->view, nullptr);
        page->view = VK_NULL_HANDLE;
      }
      device_->destroyImage(page->image, page->allocation);
    }
  }
  pages_.clear();
  usedSlots_ = 0;
  device_ = nullptr;
}

int ImageAtlas::classFor(uint32_t side)
{
  for (size_t i = 0; i < kCellSizes.size(); ++i) {
    if (side <= kCellSizes[i]) return static_cast<int>(i);
  }
  return -1;
}

size_t ImageAtlas::pageWithRoom(uint32_t cellSize) const
{
  for (size_t i = 0; i < pages_.size(); ++i) {
    if (pages_[i]->cellSize == cellSize && pages_[i]->hasRoom()) return i;
  }
  return static_cast<size_t>(-1);
}

bool ImageAtlas::addPage(uint32_t cellSize)
{
  if (!device_ || pages_.size() >= maxPages_) return false;

  auto page = std::make_unique<Page>();
  page->cellSize = cellSize;
  const uint32_t extent = page->extent();
  device_->createImage(extent, extent, 1, VK_SAMPLE_COUNT_1_BIT,
                       VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TILING_OPTIMAL,
                       VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
                       VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                       page->image, page->allocation,
                       canvas::GpuTag{canvas::GpuCategory::ImageAtlas, 0,
                                      pageDetail(cellSize)});
  // Straight to shader-read: every later upload transitions in and back out
  // around its own copy, so the page is always in the layout a draw expects.
  device_->transitionImageLayout(page->image, VK_FORMAT_R8G8B8A8_UNORM,
                                 VK_IMAGE_LAYOUT_UNDEFINED,
                                 VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
  page->view = device_->createImageView(page->image, VK_FORMAT_R8G8B8A8_UNORM,
                                        VK_IMAGE_ASPECT_COLOR_BIT, 1);
  pages_.push_back(std::move(page));
  std::cout << "ImageAtlas: allocated page " << pages_.size() - 1 << " ("
            << extent << "x" << extent << ", " << cellSize << "px cells)\n";
  return true;
}

ImageAtlas::Region ImageAtlas::add(const uint8_t *rgba, uint32_t w, uint32_t h)
{
  Region out;
  if (!device_ || rgba == nullptr) return out;
  // Anything bigger than the largest class belongs in its own texture.
  // Scaling it down here would silently degrade a hero image to thumbnail
  // resolution.
  if (w == 0 || h == 0) return out;
  const int best = classFor(std::max(w, h));
  if (best < 0) return out;

  // Tightest class first, then a new page of it, and only then a looser class
  // that already has a page — a cell half wasted still beats an image falling
  // out of the atlas onto a texture of its own.
  size_t index = pageWithRoom(kCellSizes[static_cast<size_t>(best)]);
  if (index == static_cast<size_t>(-1)) {
    if (addPage(kCellSizes[static_cast<size_t>(best)])) {
      index = pages_.size() - 1;
    } else {
      for (size_t c = static_cast<size_t>(best) + 1;
           c < kCellSizes.size() && index == static_cast<size_t>(-1); ++c) {
        index = pageWithRoom(kCellSizes[c]);
      }
    }
  }
  if (index == static_cast<size_t>(-1)) return out;

  Page          &target     = *pages_[index];
  const uint32_t targetPage = static_cast<uint32_t>(index);

  uint32_t slot;
  if (!target.free.empty()) {
    slot = target.free.back();
    target.free.pop_back();
  } else {
    slot = target.nextFresh++;
  }

  const uint32_t col = slot % kCellsPerRow;
  const uint32_t row = slot / kCellsPerRow;
  const int32_t  x   = static_cast<int32_t>(col * target.cellSize);
  const int32_t  y   = static_cast<int32_t>(row * target.cellSize);

  const VkDeviceSize bytes = static_cast<VkDeviceSize>(w) * h * 4;
  VkBuffer      staging;
  VmaAllocation stagingAlloc;
  device_->createBuffer(bytes, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
                          | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                        staging, stagingAlloc,
                        canvas::GpuTag{canvas::GpuCategory::Staging, 0,
                                       "atlas cell upload"});
  void *mapped = device_->mapBuffer(stagingAlloc);
  std::memcpy(mapped, rgba, static_cast<size_t>(bytes));
  device_->unmapBuffer(stagingAlloc);

  device_->updateSampledImageRegion(staging, target.image, x, y, w, h);
  device_->destroyBuffer(staging, stagingAlloc);

  // UVs cover only the pixels written, not the whole cell — an image
  // smaller than the cell must not sample its neighbour's leftovers.
  // Inset a half texel so bilinear at the quad edge stays inside the
  // written rect. Without it the filter peeks at the next cell (or
  // the unwritten rest of this one) and a circular icon grows a
  // coloured fringe.
  const float inv = 1.f / static_cast<float>(target.extent());
  const float half = 0.5f * inv;
  out.page  = targetPage;
  out.slot  = slot;
  out.uv0   = {static_cast<float>(x) * inv + half,
               static_cast<float>(y) * inv + half};
  out.uv1   = {static_cast<float>(x + static_cast<int32_t>(w)) * inv - half,
               static_cast<float>(y + static_cast<int32_t>(h)) * inv - half};
  out.valid = true;
  ++usedSlots_;
  return out;
}

void ImageAtlas::freeSlot(uint32_t page, uint32_t slot)
{
  if (page >= pages_.size()) return;
  pages_[page]->free.push_back(slot);
  if (usedSlots_ > 0) --usedSlots_;
}

VkImageView ImageAtlas::pageView(uint32_t page) const
{
  if (page >= pages_.size()) return VK_NULL_HANDLE;
  return pages_[page]->view;
}

VkImage ImageAtlas::pageImage(uint32_t page) const
{
  if (page >= pages_.size()) return VK_NULL_HANDLE;
  return pages_[page]->image;
}

uint32_t ImageAtlas::pageCellSize(uint32_t page) const
{
  if (page >= pages_.size()) return 0;
  return pages_[page]->cellSize;
}

uint32_t ImageAtlas::pageSize(uint32_t page) const
{
  if (page >= pages_.size()) return 0;
  return pages_[page]->extent();
}

uint32_t ImageAtlas::pageUsedSlots(uint32_t page) const
{
  if (page >= pages_.size()) return 0;
  const Page &p = *pages_[page];
  return p.nextFresh - static_cast<uint32_t>(p.free.size());
}

uint64_t ImageAtlas::allocatedBytes() const
{
  uint64_t total = 0;
  for (const auto &page : pages_) {
    const uint64_t extent = page->extent();
    total += extent * extent * 4;
  }
  return total;
}
