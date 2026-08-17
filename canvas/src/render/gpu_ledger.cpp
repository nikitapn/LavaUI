#include "render/gpu_ledger.hpp"

#include <algorithm>

namespace canvas {

const char *gpuCategoryName(GpuCategory category)
{
  switch (category) {
  case GpuCategory::Unlabeled:       return "unlabeled";
  case GpuCategory::WindowColor:     return "window colour";
  case GpuCategory::WindowDepth:     return "window depth";
  case GpuCategory::WindowResolve:   return "window resolve";
  case GpuCategory::WindowStaging:   return "window staging";
  case GpuCategory::BlurScratch:     return "blur scratch";
  case GpuCategory::GlyphAtlas:      return "glyph atlas";
  case GpuCategory::ImageAtlas:      return "image atlas";
  case GpuCategory::Texture:         return "texture";
  case GpuCategory::VertexArena:     return "vertex arena";
  case GpuCategory::Physics:         return "physics";
  case GpuCategory::Staging:         return "staging";
  case GpuCategory::ExportedFrame:   return "exported frame";
  case GpuCategory::ImportedSurface: return "imported surface";
  case GpuCategory::Count:           break;
  }
  return "?";
}

bool gpuCategoryIsForeign(GpuCategory category)
{
  return category == GpuCategory::ImportedSurface;
}

void GpuLedger::addImage(const void *key, uint64_t bytes, const GpuTag &tag,
                         uint32_t width, uint32_t height, uint32_t samples,
                         uint32_t mips, uint32_t format, uint32_t usage)
{
  if (key == nullptr) return;
  std::lock_guard lock(mu_);
  GpuAllocation entry;
  entry.category = tag.category;
  entry.windowId = tag.windowId;
  entry.detail.assign(tag.detail);
  entry.bytes    = bytes;
  entry.isImage  = true;
  entry.width    = width;
  entry.height   = height;
  entry.samples  = samples;
  entry.mips     = mips;
  entry.format   = format;
  entry.usage    = usage;
  entry.sequence = nextSequence_++;
  live_[key]     = std::move(entry);
}

void GpuLedger::addBuffer(const void *key, uint64_t bytes, const GpuTag &tag,
                          uint32_t usage)
{
  if (key == nullptr) return;
  std::lock_guard lock(mu_);
  GpuAllocation entry;
  entry.category = tag.category;
  entry.windowId = tag.windowId;
  entry.detail.assign(tag.detail);
  entry.bytes    = bytes;
  entry.usage    = usage;
  entry.sequence = nextSequence_++;
  live_[key]     = std::move(entry);
}

void GpuLedger::addExternal(const void *key, uint64_t bytes, const GpuTag &tag,
                            uint32_t width, uint32_t height, uint32_t format)
{
  addImage(key, bytes, tag, width, height, /*samples=*/1, /*mips=*/1, format,
           /*usage=*/0);
}

void GpuLedger::markRetiring(const void *key)
{
  if (key == nullptr) return;
  std::lock_guard lock(mu_);
  if (auto it = live_.find(key); it != live_.end()) it->second.retiring = true;
}

void GpuLedger::remove(const void *key)
{
  if (key == nullptr) return;
  std::lock_guard lock(mu_);
  live_.erase(key);
}

void GpuLedger::retag(const void *key, const GpuTag &tag)
{
  if (key == nullptr) return;
  std::lock_guard lock(mu_);
  auto it = live_.find(key);
  if (it == live_.end()) return;
  it->second.category = tag.category;
  it->second.windowId = tag.windowId;
  it->second.detail.assign(tag.detail);
}

std::vector<GpuAllocation> GpuLedger::snapshot() const
{
  std::lock_guard lock(mu_);
  std::vector<GpuAllocation> out;
  out.reserve(live_.size());
  for (const auto &[key, entry] : live_) out.push_back(entry);
  // Biggest first, then by age: the order a reader wants, and one a hash map
  // cannot give.
  std::ranges::sort(out, [](const GpuAllocation &a, const GpuAllocation &b) {
    if (a.bytes != b.bytes) return a.bytes > b.bytes;
    return a.sequence < b.sequence;
  });
  return out;
}

GpuLedgerTotals GpuLedger::totals() const
{
  std::lock_guard lock(mu_);
  GpuLedgerTotals totals;
  totals.count = static_cast<uint32_t>(live_.size());
  for (const auto &[key, entry] : live_) {
    const size_t slot = static_cast<size_t>(entry.category);
    if (slot < std::size(totals.byCategory)) totals.byCategory[slot] += entry.bytes;
    if (gpuCategoryIsForeign(entry.category)) {
      totals.foreignBytes += entry.bytes;
      continue;
    }
    totals.bytes += entry.bytes;
    if (entry.retiring) totals.retiringBytes += entry.bytes;
  }
  return totals;
}

}  // namespace canvas
