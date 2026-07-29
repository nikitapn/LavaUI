#include <pch.hpp>

#include <array>
#include <vector>
#include <iostream>
#include <stdexcept>
#include <unordered_map>

#include <glm/gtc/matrix_transform.hpp>

#include "render/font.hpp"
#include "render/vulkan.hpp"
#include "render/shaders.hpp"
#include "render/text_renderer.hpp"

namespace {


// Keyed by glyph index (canvas::PositionedGlyph::glyphId), not Unicode
// codepoint — a glyph index is what Font::rasterize() wants, and what lets
// a ligature (several codepoints, one substituted glyph) cache and draw
// correctly instead of only ever being reachable by codepoint.
struct GlyphInfo {
  vec2 atlasUV[2];  // Top-left and bottom-right UV coordinates
  vec2 size;        // Glyph dimensions in pixels
  vec2 bearing;     // Glyph bearing (offset from baseline)
};

}

// Implementation class - hidden from header
struct TextRenderer::Impl {
  Vulkan& vulkan_;
  Shaders shaders_;

  // Font/Atlas data. Shaping (HarfBuzz) and rasterization (FreeType) both
  // live behind canvas::Font now — this class only caches rasterized
  // bitmaps into its own Vulkan atlas and never touches FreeType/HarfBuzz
  // directly.
  // One entry per registered (path, pixelSize). Glyph ids are *face-relative*,
  // so the atlas must be keyed by (fontId, glyphId) — keying by glyphId alone
  // silently draws the wrong glyph as soon as a second face or size exists.
  std::vector<canvas::Font>               fonts_;
  std::vector<std::pair<std::string, float>> fontKeys_;
  std::unordered_map<uint64_t, GlyphInfo> glyphMap_;

  static uint64_t glyphKey(uint32_t fontId, uint32_t glyphId) {
    return (static_cast<uint64_t>(fontId) << 32) | glyphId;
  }

  // Vulkan resources
  VkImage        atlasTexture_;
  VkDeviceMemory atlasTextureMemory_;
  VkImageView    atlasTextureView_;
  VkSampler      atlasSampler_;

  // Rendering pipeline

  // Instance data
  
  // Quad vertex buffer for instanced rendering

  // Atlas management
  int atlasWidth_;
  int atlasHeight_;
  int currentX_;
  int currentY_;
  int shelfHeight_;   // tallest glyph on the current shelf
  /// Bumped whenever the atlas image is replaced, so QuadRenderer knows to
  /// re-point its descriptor at the new view.
  uint32_t atlasGeneration_ = 0;
  /// Set when a glyph did not fit; the atlas grows before the next replay.
  bool needsGrow_ = false;

  Impl(Vulkan& vulkan)
      : vulkan_(vulkan),
        shaders_(vulkan),
        atlasTexture_(VK_NULL_HANDLE),
        atlasTextureMemory_(VK_NULL_HANDLE),
        atlasTextureView_(VK_NULL_HANDLE),
        atlasSampler_(VK_NULL_HANDLE),
        atlasWidth_(512),
        atlasHeight_(512),
        currentX_(0),
        currentY_(0),
        shelfHeight_(0)
  {
  }

  void init() {
    // Atlas only. Drawing belongs to QuadRenderer, which samples this atlas
    // through its own descriptor set — TextRenderer owns no pipeline.
    createAtlasTexture();
  }

  // Idempotent on purpose: called explicitly from Application::shutdown()
  // (before vulkan.cleanUp() destroys the VkDevice) *and* implicitly from
  // ~Impl() below (whenever this object itself is destroyed, which happens
  // later, after the device is already gone). Every handle is reset to
  // VK_NULL_HANDLE after destruction so the second call's guards all see
  // null and skip — otherwise that second call tries to destroy already-
  // destroyed handles against an already-destroyed device. Same pattern
  // LineRenderer::destroy() already uses.
  void cleanUp() {
    VkDevice device = vulkan_.getDevice();

    // Cleanup Shaders
    shaders_.cleanUp();

    // font_ (FreeType/HarfBuzz) has no Vulkan dependency, so its own
    // destructor (whenever Impl is destroyed) is sufficient — no explicit
    // teardown needed here the way the Vulkan resources below require.

    // Cleanup Vulkan resources
    if (atlasSampler_ != VK_NULL_HANDLE) {
      vkDestroySampler(device, atlasSampler_, nullptr);
      atlasSampler_ = VK_NULL_HANDLE;
    }
    if (atlasTextureView_ != VK_NULL_HANDLE) {
      vkDestroyImageView(device, atlasTextureView_, nullptr);
      atlasTextureView_ = VK_NULL_HANDLE;
    }
    if (atlasTexture_ != VK_NULL_HANDLE) {
      vkDestroyImage(device, atlasTexture_, nullptr);
      atlasTexture_ = VK_NULL_HANDLE;
    }
    if (atlasTextureMemory_ != VK_NULL_HANDLE) {
      vkFreeMemory(device, atlasTextureMemory_, nullptr);
      atlasTextureMemory_ = VK_NULL_HANDLE;
    }
  }

  ~Impl() {
    cleanUp();
  }

  /// Registers a face and returns its id, or -1 on failure. Ids are stable
  /// for the process; re-registering the same (path, size) returns the
  /// existing id so Swift can call this idempotently.
  int registerFont(const std::string& fontPath, float pixelSize) {
    for (size_t i = 0; i < fontKeys_.size(); ++i) {
      if (fontKeys_[i].first == fontPath && fontKeys_[i].second == pixelSize) {
        return static_cast<int>(i);
      }
    }
    canvas::Font font;
    if (!font.load(fontPath, pixelSize)) {
      return -1;
    }
    fonts_.push_back(std::move(font));
    fontKeys_.emplace_back(fontPath, pixelSize);
    return static_cast<int>(fonts_.size() - 1);
  }



  void createAtlasTexture() {
    VkDevice device = vulkan_.getDevice();

    // Create atlas texture
    vulkan_.createImage(
      atlasWidth_,
      atlasHeight_,
      1,
      VK_SAMPLE_COUNT_1_BIT,
      VK_FORMAT_R8_UNORM,
      VK_IMAGE_TILING_OPTIMAL,
      VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
      VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
      atlasTexture_,
      atlasTextureMemory_);

    // Transition to optimal layout
    vulkan_.transitionImageLayout(atlasTexture_,
                                  VK_FORMAT_R8_UNORM,
                                  VK_IMAGE_LAYOUT_UNDEFINED,
                                  VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);

    // Create image view
    atlasTextureView_ = vulkan_.createImageView(
      atlasTexture_, VK_FORMAT_R8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT, 1);

    // Create sampler
    atlasSampler_ = vulkan_.createTextureSampler();
  }







  /// Rasterizes and packs on first use. Returns nullptr when the glyph does
  /// not fit; the caller drops it for this frame and the atlas grows before
  /// the next replay (see growAtlasIfNeeded).
  const GlyphInfo* getOrCreateGlyph(uint32_t fontId, uint32_t glyphId) {
    const uint64_t key = glyphKey(fontId, glyphId);
    auto it = glyphMap_.find(key);
    if (it != glyphMap_.end()) {
      return &it->second;
    }
    if (fontId >= fonts_.size() || !fonts_[fontId].isLoaded()) {
      return nullptr;
    }

    canvas::GlyphBitmap bitmap = fonts_[fontId].rasterize(glyphId);

    // Shelf packing with a per-shelf height: a period no longer reserves a
    // full line-height row, which is most of the vertical waste.
    if (currentX_ + bitmap.width > atlasWidth_) {
      currentX_ = 0;
      currentY_ += shelfHeight_;
      shelfHeight_ = 0;
    }
    if (currentY_ + bitmap.height > atlasHeight_) {
      needsGrow_ = true;
      return nullptr;  // dropped for one frame, then re-rasterized
    }

    if (bitmap.width > 0 && bitmap.height > 0) {
      updateAtlasTexture(bitmap, currentX_, currentY_);
    }

    GlyphInfo glyph;
    glyph.atlasUV[0] = {static_cast<float>(currentX_) / atlasWidth_,
                        static_cast<float>(currentY_) / atlasHeight_};
    glyph.atlasUV[1] = {
      static_cast<float>(currentX_ + bitmap.width) / atlasWidth_,
      static_cast<float>(currentY_ + bitmap.height) / atlasHeight_};
    glyph.size    = {static_cast<float>(bitmap.width),
                     static_cast<float>(bitmap.height)};
    glyph.bearing = {bitmap.bearingX, bitmap.bearingY};

    currentX_ += bitmap.width + 1;  // 1px padding avoids bilinear bleed
    shelfHeight_ = std::max(shelfHeight_, bitmap.height + 1);

    return &(glyphMap_[key] = glyph);
  }

  /// Doubles the atlas when a glyph did not fit. Existing glyphs are copied
  /// at their current pixel positions, so packing state stays valid and only
  /// the normalised UVs need rescaling — no re-rasterisation, no bitmap
  /// retention. Call between frames: it replaces the image view that
  /// QuadRenderer's descriptor points at.
  bool growAtlasIfNeeded() {
    if (!needsGrow_) return false;
    needsGrow_ = false;

    const int newW = atlasWidth_ * 2;
    const int newH = atlasHeight_ * 2;
    const int maxDim = static_cast<int>(
      vulkan_.getDeviceProperties().limits.maxImageDimension2D);
    if (newW > maxDim || newH > maxDim) {
      std::cerr << "TextRenderer: atlas at device maximum (" << atlasWidth_
                << "); further glyphs will be dropped\n";
      return false;
    }

    VkDevice device = vulkan_.getDevice();
    VkImage        newImage{};
    VkDeviceMemory newMemory{};
    vulkan_.createImage(newW, newH, 1, VK_SAMPLE_COUNT_1_BIT, VK_FORMAT_R8_UNORM,
                        VK_IMAGE_TILING_OPTIMAL,
                        VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
                        VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, newImage, newMemory);

    vulkan_.transitionImageLayout(newImage, VK_FORMAT_R8_UNORM,
                                  VK_IMAGE_LAYOUT_UNDEFINED,
                                  VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
    vulkan_.transitionImageLayout(atlasTexture_, VK_FORMAT_R8_UNORM,
                                  VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                                  VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);

    VkCommandBuffer cmd = vulkan_.beginSingleTimeCommands();
    VkImageCopy region{
      .srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
      .srcOffset      = {0, 0, 0},
      .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
      .dstOffset      = {0, 0, 0},
      .extent         = {static_cast<uint32_t>(atlasWidth_),
                         static_cast<uint32_t>(atlasHeight_), 1},
    };
    vkCmdCopyImage(cmd, atlasTexture_, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                   newImage, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    vulkan_.endSingleTimeCommands(cmd);

    vulkan_.transitionImageLayout(newImage, VK_FORMAT_R8_UNORM,
                                  VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                  VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);

    vkDestroyImageView(device, atlasTextureView_, nullptr);
    vkDestroyImage(device, atlasTexture_, nullptr);
    vkFreeMemory(device, atlasTextureMemory_, nullptr);

    atlasTexture_       = newImage;
    atlasTextureMemory_ = newMemory;
    atlasTextureView_   = vulkan_.createImageView(
      atlasTexture_, VK_FORMAT_R8_UNORM, VK_IMAGE_ASPECT_COLOR_BIT, 1);

    // Pixel positions are unchanged; only the normalisation denominator grew.
    const float sx = static_cast<float>(atlasWidth_) / newW;
    const float sy = static_cast<float>(atlasHeight_) / newH;
    for (auto& [key, g] : glyphMap_) {
      (void)key;
      g.atlasUV[0] = {g.atlasUV[0].x * sx, g.atlasUV[0].y * sy};
      g.atlasUV[1] = {g.atlasUV[1].x * sx, g.atlasUV[1].y * sy};
    }

    atlasWidth_  = newW;
    atlasHeight_ = newH;
    ++atlasGeneration_;
    std::cerr << "TextRenderer: atlas grown to " << newW << "x" << newH << '\n';
    return true;
  }

  void updateAtlasTexture(const canvas::GlyphBitmap& bitmap, int x, int y) {
    // Create staging buffer
    VkDeviceSize bufferSize = static_cast<VkDeviceSize>(bitmap.width) * bitmap.height;
    if (bufferSize == 0) return;

    VkBuffer       stagingBuffer;
    VkDeviceMemory stagingBufferMemory;

    vulkan_.createBuffer(bufferSize,
                         VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                         VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                           VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                         stagingBuffer,
                         stagingBufferMemory);

    // Copy bitmap data to staging buffer
    void*    data;
    VkDevice device = vulkan_.getDevice();
    vkMapMemory(device, stagingBufferMemory, 0, bufferSize, 0, &data);
    memcpy(data, bitmap.pixels.data(), bufferSize);
    vkUnmapMemory(device, stagingBufferMemory);

    // Copy from staging buffer to texture
    VkCommandBuffer commandBuffer = vulkan_.beginSingleTimeCommands();

    // Transition image layout for transfer
    VkImageMemoryBarrier barrier {
      .sType               = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
      .srcAccessMask       = 0,
      .dstAccessMask       = VK_ACCESS_TRANSFER_WRITE_BIT,
      .oldLayout           = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
      .newLayout           = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .image               = atlasTexture_,
      .subresourceRange =
        {
          .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
          .baseMipLevel   = 0,
          .levelCount     = 1,
          .baseArrayLayer = 0,
          .layerCount     = 1,
        },
    };

    vkCmdPipelineBarrier(commandBuffer,
                         VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0,
                         0,
                         nullptr,
                         0,
                         nullptr,
                         1,
                         &barrier);

    // Copy buffer to image
    VkBufferImageCopy region {
      .bufferOffset      = 0,
      .bufferRowLength   = 0,
      .bufferImageHeight = 0,
      .imageSubresource =
        {
          .aspectMask     = VK_IMAGE_ASPECT_COLOR_BIT,
          .mipLevel       = 0,
          .baseArrayLayer = 0,
          .layerCount     = 1,
        },
      .imageOffset = {x, y, 0},
      .imageExtent = {static_cast<uint32_t>(bitmap.width),
                      static_cast<uint32_t>(bitmap.height),
                      1},
    };

    vkCmdCopyBufferToImage(commandBuffer,
                           stagingBuffer,
                           atlasTexture_,
                           VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                           1,
                           &region);

    // Transition back to shader read
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    barrier.oldLayout     = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout     = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    vkCmdPipelineBarrier(commandBuffer,
                         VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                         0,
                         0,
                         nullptr,
                         0,
                         nullptr,
                         1,
                         &barrier);

    vulkan_.endSingleTimeCommands(commandBuffer);

    // Cleanup staging buffer
    vkDestroyBuffer(device, stagingBuffer, nullptr);
    vkFreeMemory(device, stagingBufferMemory, nullptr);
  }
};

// TextRenderer public interface implementation
TextRenderer::TextRenderer(Vulkan& vulkan)
    : impl_(std::make_unique<TextRenderer::Impl>(vulkan)) {}

TextRenderer::~TextRenderer() = default;

TextRenderer::TextRenderer(TextRenderer&& other) noexcept = default;
TextRenderer& TextRenderer::operator=(TextRenderer&& other) noexcept = default;

void TextRenderer::init() { impl_->init(); }

bool TextRenderer::glyphQuad(uint32_t fontId, uint32_t glyphId, GlyphQuad &out) {
  // Rasterizes + packs on first use. Must be called during draw-list replay,
  // never inside a command-buffer callback: the atlas upload path submits and
  // waits on its own single-time command buffer.
  const GlyphInfo *g = impl_->getOrCreateGlyph(fontId, glyphId);
  if (!g) return false;  // didn't fit; atlas grows before the next frame
  out.uv0     = g->atlasUV[0];
  out.uv1     = g->atlasUV[1];
  out.size    = g->size;
  out.bearing = g->bearing;
  return true;
}

int  TextRenderer::registerFont(const std::string &path, float pixelSize) {
  return impl_->registerFont(path, pixelSize);
}
bool TextRenderer::atlasNeedsGrow() const { return impl_->needsGrow_; }
bool TextRenderer::growAtlasIfNeeded() { return impl_->growAtlasIfNeeded(); }
uint32_t TextRenderer::atlasGeneration() const { return impl_->atlasGeneration_; }

VkImageView TextRenderer::atlasView() const { return impl_->atlasTextureView_; }
VkSampler   TextRenderer::atlasSampler() const { return impl_->atlasSampler_; }

canvas::VoidResult TextRenderer::loadFont(const std::string& fontPath, int fontSize) {
  // Back-compat shim: registers as font 0 (the default face).
  return impl_->registerFont(fontPath, static_cast<float>(fontSize)) >= 0
           ? canvas::ok()
           : canvas::VoidResult(std::unexpected(
               canvas::Error{"failed to load font: " + fontPath}));
}

void TextRenderer::cleanUp() { impl_->cleanUp(); }


