#include <cstring>
#include <iostream>

#include "render/image_atlas.hpp"
#include "render/render_device.hpp"

void ImageAtlas::initialize(RenderDevice &device, uint32_t cellSize,
                            uint32_t pageSize, uint32_t maxPages)
{
  device_   = &device;
  cellSize_ = cellSize > 0 ? cellSize : 256;
  // Round the page down to a whole number of cells so no strip is unusable.
  cellsPerRow_ = pageSize / cellSize_;
  if (cellsPerRow_ == 0) cellsPerRow_ = 1;
  pageSize_ = cellsPerRow_ * cellSize_;
  maxPages_ = maxPages;
  std::cout << "ImageAtlas: " << pageSize_ << "x" << pageSize_ << " pages of "
            << cellsPerRow_ * cellsPerRow_ << " x " << cellSize_ << "px cells, max "
            << maxPages_ << " pages\n";
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

bool ImageAtlas::addPage()
{
  if (!device_ || pages_.size() >= maxPages_) return false;

  auto page = std::make_unique<Page>();
  device_->createImage(pageSize_, pageSize_, 1, VK_SAMPLE_COUNT_1_BIT,
                       VK_FORMAT_R8G8B8A8_SRGB, VK_IMAGE_TILING_OPTIMAL,
                       VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
                       VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                       page->image, page->allocation,
                       canvas::GpuTag{canvas::GpuCategory::ImageAtlas, 0,
                                      "page"});
  // Straight to shader-read: every later upload transitions in and back out
  // around its own copy, so the page is always in the layout a draw expects.
  device_->transitionImageLayout(page->image, VK_FORMAT_R8G8B8A8_SRGB,
                                 VK_IMAGE_LAYOUT_UNDEFINED,
                                 VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
  page->view = device_->createImageView(page->image, VK_FORMAT_R8G8B8A8_SRGB,
                                        VK_IMAGE_ASPECT_COLOR_BIT, 1);
  pages_.push_back(std::move(page));
  std::cout << "ImageAtlas: allocated page " << pages_.size() - 1 << "\n";
  return true;
}

ImageAtlas::Region ImageAtlas::add(const uint8_t *rgba, uint32_t w, uint32_t h)
{
  Region out;
  if (!device_ || rgba == nullptr) return out;
  // Anything bigger than a cell belongs in its own texture. Scaling it down
  // here would silently degrade a hero image to thumbnail resolution.
  if (w == 0 || h == 0 || w > cellSize_ || h > cellSize_) return out;

  // First page with room: a returned slot before a fresh one, so a library
  // being scrolled reuses cells instead of growing.
  Page    *target     = nullptr;
  uint32_t targetPage = 0;
  for (uint32_t i = 0; i < pages_.size(); ++i) {
    auto &p = pages_[i];
    if (!p->free.empty() || p->nextFresh < slotsPerPage()) {
      target     = p.get();
      targetPage = i;
      break;
    }
  }
  if (target == nullptr) {
    if (!addPage()) return out;
    target     = pages_.back().get();
    targetPage = static_cast<uint32_t>(pages_.size() - 1);
  }

  uint32_t slot;
  if (!target->free.empty()) {
    slot = target->free.back();
    target->free.pop_back();
  } else {
    slot = target->nextFresh++;
  }

  const uint32_t col = slot % cellsPerRow_;
  const uint32_t row = slot / cellsPerRow_;
  const int32_t  x   = static_cast<int32_t>(col * cellSize_);
  const int32_t  y   = static_cast<int32_t>(row * cellSize_);

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

  device_->updateSampledImageRegion(staging, target->image, x, y, w, h);
  device_->destroyBuffer(staging, stagingAlloc);

  // UVs cover only the pixels written, not the whole cell — an image
  // smaller than the cell must not sample its neighbour's leftovers.
  // Inset a half texel so bilinear at the quad edge stays inside the
  // written rect. Without it the filter peeks at the next cell (or
  // the unwritten rest of this one) and a circular icon grows a
  // coloured fringe.
  const float inv = 1.f / static_cast<float>(pageSize_);
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

uint32_t ImageAtlas::pageUsedSlots(uint32_t page) const
{
  if (page >= pages_.size()) return 0;
  const Page &p = *pages_[page];
  return p.nextFresh - static_cast<uint32_t>(p.free.size());
}
