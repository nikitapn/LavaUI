#include "render/gpu_report.hpp"

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <ostream>
#include <unordered_map>

#include "render/png_encode.hpp"
#include "render/render_device.hpp"
#include "render/render_window.hpp"
#include "render/text_renderer.hpp"
#include "render/texture_manager.hpp"

namespace canvas {
namespace {

/// Bytes as the reader thinks of them. Two decimals below 10 units so a 4 MiB
/// atlas and a 4.25 MiB one are distinguishable, which matters when the
/// question is whether something doubled.
std::string humanBytes(uint64_t bytes)
{
  static const char *units[] = {"B", "KiB", "MiB", "GiB", "TiB"};
  double             value   = static_cast<double>(bytes);
  size_t             unit    = 0;
  while (value >= 1024.0 && unit + 1 < std::size(units)) {
    value /= 1024.0;
    ++unit;
  }
  char buffer[32];
  std::snprintf(buffer, sizeof buffer, unit == 0 ? "%.0f %s" : "%.1f %s", value,
                units[unit]);
  return buffer;
}

uint32_t percentOf(uint64_t part, uint64_t whole)
{
  if (whole == 0) return 0;
  return static_cast<uint32_t>(part * 100 / whole);
}

}  // namespace

GpuReport buildGpuReport(RenderDevice &device)
{
  GpuReport report;

  const auto totals    = device.gpuMemoryTotals();
  report.deviceName    = totals.deviceName;
  report.samples       = totals.samples;
  // `maxSamples` arrives as a bitmask of supported counts; the report wants the
  // highest bit, which is what `getMaxUsableSampleCount` would have picked.
  report.maxSamples    = totals.maxSamples == 0
                           ? 1
                           : (1u << (31 - __builtin_clz(totals.maxSamples)));
  report.heapUsageBytes    = totals.heapUsageBytes;
  report.heapBudgetBytes   = totals.heapBudgetBytes;
  report.heapSizeBytes     = totals.heapSizeBytes;
  report.vmaAllocatedBytes = totals.vmaAllocatedBytes;
  report.vmaBlockBytes     = totals.vmaBlockBytes;

  report.totals      = device.gpuLedger().totals();
  report.allocations = device.gpuLedger().snapshot();

  // Windows, with the ledger's per-window sums folded in. Built from the
  // allocation list rather than asked of each window, so a window's bytes and
  // the total can never disagree.
  std::unordered_map<uint32_t, uint64_t> bytesByWindow;
  for (const GpuAllocation &alloc : report.allocations) {
    if (alloc.windowId == 0 || gpuCategoryIsForeign(alloc.category)) continue;
    bytesByWindow[alloc.windowId] += alloc.bytes;
  }
  for (const RenderWindow *window : device.windowsSnapshot()) {
    if (window == nullptr) continue;
    GpuWindowReport entry;
    entry.id       = window->ownerId();
    entry.width    = window->getExtent().width;
    entry.height   = window->getExtent().height;
    entry.samples  = report.samples;
    entry.windowed = window->isWindowed();
    if (auto found = bytesByWindow.find(entry.id); found != bytesByWindow.end()) {
      entry.bytes = found->second;
    }
    report.windows.push_back(std::move(entry));
  }
  std::ranges::sort(report.windows,
                    [](const GpuWindowReport &a, const GpuWindowReport &b) {
                      return a.bytes > b.bytes;
                    });

  // The glyph atlas: one page, shared by every window.
  const TextRenderer::AtlasStats glyphs = device.textRenderer().atlasStats();
  if (glyphs.width != 0) {
    GpuAtlasPage page;
    page.kind        = GpuAtlasPage::Kind::Glyph;
    page.width       = glyphs.width;
    page.height      = glyphs.height;
    page.bytes       = glyphs.bytes;
    page.fillPercent = percentOf(glyphs.packedRows, glyphs.height);
    page.generation  = glyphs.generation;
    page.glyphs      = glyphs.glyphs;
    page.faces       = glyphs.faces;
    report.atlases.push_back(std::move(page));
  }

  // The image atlas: as many pages as the covers needed.
  const ImageAtlas &atlas = TextureManager::getInstance().atlas();
  const uint32_t slotsPerPage = atlas.slotsPerPageCount();
  for (uint32_t i = 0; i < atlas.pageCount(); ++i) {
    GpuAtlasPage page;
    page.kind        = GpuAtlasPage::Kind::Image;
    page.page        = i;
    page.width       = atlas.pageSize();
    page.height      = atlas.pageSize();
    page.bytes       = static_cast<uint64_t>(atlas.pageSize()) * atlas.pageSize() * 4;
    page.slotsUsed   = atlas.pageUsedSlots(i);
    page.slotsTotal  = slotsPerPage;
    page.cellSize    = atlas.cellSize();
    page.fillPercent = percentOf(page.slotsUsed, slotsPerPage);
    report.atlases.push_back(std::move(page));
  }

  const auto cache            = TextureManager::getInstance().cacheStats();
  report.cache.imageBytes         = cache.imageBytes;
  report.cache.dormantBytes       = cache.dormantBytes;
  report.cache.dormantBudgetBytes = cache.dormantBudgetBytes;
  report.cache.atlasBytes         = cache.atlasBytes;
  report.cache.cacheHits          = cache.cacheHits;
  report.cache.evictions          = cache.evictions;
  report.cache.textures           = cache.textures;
  report.cache.pinnedTextures     = cache.pinnedTextures;
  report.cache.atlasSlotsUsed     = cache.atlasSlotsUsed;
  report.cache.atlasSlotsCapacity = cache.atlasSlotsCapacity;
  report.cache.dormantSlots       = cache.dormantSlots;
  report.cache.pendingSlots       = cache.pendingSlots;

  for (const TextureManager::Entry &entry :
       TextureManager::getInstance().entries()) {
    GpuTextureReport texture;
    texture.key        = entry.key;
    texture.bytes      = entry.bytes;
    texture.width      = entry.width;
    texture.height     = entry.height;
    texture.refCount   = entry.refCount;
    texture.windowPins = entry.windowPins;
    texture.atlased    = entry.atlased;
    texture.dormant    = entry.dormant;
    texture.external   = entry.external;
    report.textures.push_back(std::move(texture));
  }

  return report;
}

size_t dumpAtlasPages(RenderDevice &device, const std::string &dir,
                      std::vector<GpuAtlasPage> &pages)
{
  std::error_code ec;
  std::filesystem::create_directories(dir, ec);
  if (ec) {
    std::cerr << "dumpAtlasPages: " << dir << ": " << ec.message() << '\n';
    return 0;
  }

  const ImageAtlas &atlas = TextureManager::getInstance().atlas();
  const TextRenderer::AtlasStats glyphs = device.textRenderer().atlasStats();

  size_t written = 0;
  for (GpuAtlasPage &page : pages) {
    VkImage       image  = VK_NULL_HANDLE;
    VkFormat      format = VK_FORMAT_R8_UNORM;
    VkImageLayout layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    std::string   name;
    if (page.kind == GpuAtlasPage::Kind::Glyph) {
      image  = glyphs.image;
      format = VK_FORMAT_R8_UNORM;
      // Named by generation: a session that grew the atlas twice leaves three
      // files, and which is which is the interesting part.
      name = "glyph-atlas-gen" + std::to_string(page.generation) + ".png";
    } else {
      image  = atlas.pageImage(page.page);
      format = VK_FORMAT_R8G8B8A8_UNORM;
      name   = "image-atlas-page" + std::to_string(page.page) + ".png";
    }
    if (image == VK_NULL_HANDLE) continue;

    std::vector<uint8_t> rgba;
    if (!device.readImagePixels(image, page.width, page.height, format, layout,
                                rgba)) {
      continue;
    }
    std::vector<uint8_t> png;
    int                  outW = 0;
    int                  outH = 0;
    if (!encodeRgbaPng(rgba.data(), static_cast<int>(page.width),
                       static_cast<int>(page.height),
                       static_cast<int>(page.width) * 4, /*maxSide=*/0, png,
                       outW, outH)) {
      continue;
    }
    const std::string path = dir + "/" + name;
    std::ofstream     file(path, std::ios::binary | std::ios::trunc);
    if (!file) {
      std::cerr << "dumpAtlasPages: cannot write " << path << '\n';
      continue;
    }
    file.write(reinterpret_cast<const char *>(png.data()),
               static_cast<std::streamsize>(png.size()));
    if (!file) continue;
    page.pngPath = path;
    ++written;
  }
  return written;
}

void printGpuReport(const GpuReport &report, std::ostream &out, bool verbose)
{
  out << "─── GPU memory ─────────────────────────────────────────────\n"
      << report.deviceName << ", " << report.samples << "x MSAA (device allows "
      << report.maxSamples << "x)\n"
      << "  driver attributes  " << humanBytes(report.heapUsageBytes) << " of "
      << humanBytes(report.heapBudgetBytes) << " budget, "
      << humanBytes(report.heapSizeBytes) << " installed\n"
      << "  VMA allocated      " << humanBytes(report.vmaAllocatedBytes)
      << " in " << humanBytes(report.vmaBlockBytes) << " of blocks\n"
      << "  ledger accounts    " << humanBytes(report.totals.bytes) << " over "
      << report.totals.count << " allocation(s)";
  if (report.totals.retiringBytes != 0) {
    out << ", " << humanBytes(report.totals.retiringBytes) << " awaiting retire";
  }
  out << "\n";
  if (report.totals.foreignBytes != 0) {
    out << "  imported (not ours) " << humanBytes(report.totals.foreignBytes)
        << "\n";
  }

  out << "by category:\n";
  for (uint32_t i = 0; i < static_cast<uint32_t>(GpuCategory::Count); ++i) {
    const uint64_t bytes = report.totals.byCategory[i];
    if (bytes == 0) continue;
    out << "  " << std::left << std::setw(18)
        << gpuCategoryName(static_cast<GpuCategory>(i)) << std::right
        << std::setw(10) << humanBytes(bytes) << "  "
        << percentOf(bytes, report.totals.bytes) << "%\n";
  }

  out << "windows:\n";
  for (const GpuWindowReport &window : report.windows) {
    out << "  " << std::setw(4) << window.id << "  " << std::setw(5)
        << window.width << "x" << std::setw(5) << window.height << "  "
        << (window.windowed ? "presenting" : "offscreen ") << "  "
        << std::setw(10) << humanBytes(window.bytes);
    if (!window.title.empty()) out << "  " << window.title;
    out << "\n";
  }

  out << "atlases:\n";
  for (const GpuAtlasPage &page : report.atlases) {
    if (page.kind == GpuAtlasPage::Kind::Glyph) {
      out << "  glyph  " << page.width << "x" << page.height << "  R8  "
          << std::setw(10) << humanBytes(page.bytes) << "  " << page.fillPercent
          << "% packed, " << page.glyphs << " glyph(s), " << page.faces
          << " face(s), generation " << page.generation << "\n";
    } else {
      out << "  image  page " << page.page << "  " << page.width << "x"
          << page.height << "  RGBA8  " << std::setw(10)
          << humanBytes(page.bytes) << "  " << page.slotsUsed << "/"
          << page.slotsTotal << " cells of " << page.cellSize << "px\n";
    }
    if (!page.pngPath.empty()) out << "         → " << page.pngPath << "\n";
  }

  out << "texture cache: " << report.cache.textures << " entr(ies), "
      << humanBytes(report.cache.imageBytes) << " standalone + "
      << humanBytes(report.cache.atlasBytes) << " atlas, "
      << humanBytes(report.cache.dormantBytes) << " dormant of "
      << humanBytes(report.cache.dormantBudgetBytes) << " budget, "
      << report.cache.cacheHits << " hit(s), " << report.cache.evictions
      << " eviction(s)\n";

  if (!verbose) return;

  out << "allocations:\n";
  for (const GpuAllocation &alloc : report.allocations) {
    out << "  " << std::setw(10) << humanBytes(alloc.bytes) << "  "
        << std::left << std::setw(18) << gpuCategoryName(alloc.category)
        << std::right;
    if (alloc.windowId != 0) out << " w" << alloc.windowId;
    if (alloc.isImage) {
      out << "  " << alloc.width << "x" << alloc.height;
      if (alloc.samples > 1) out << " x" << alloc.samples;
      if (alloc.mips > 1) out << " " << alloc.mips << " mips";
    }
    if (alloc.retiring) out << "  [retiring]";
    if (!alloc.detail.empty()) out << "  " << alloc.detail;
    out << "\n";
  }

  out << "textures:\n";
  for (const GpuTextureReport &texture : report.textures) {
    out << "  " << std::setw(10) << humanBytes(texture.bytes) << "  "
        << texture.width << "x" << texture.height << "  refs "
        << texture.refCount << " pins " << texture.windowPins;
    if (texture.atlased) out << "  atlased";
    if (texture.dormant) out << "  dormant";
    if (texture.external) out << "  external";
    out << "  " << texture.key << "\n";
  }
}

}  // namespace canvas
