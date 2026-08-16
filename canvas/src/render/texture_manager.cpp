#include <iostream>
#include <cstring>
#include <algorithm>
#include <cstdlib>
#include <vector>

#include "render/render_device.hpp"
#include "render/texture_manager.hpp"

#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>

// Single translation unit for both stb implementations. Callers
// (`Engine::decodeImage`, `encodeRgbaPng`) include the header for
// declarations and link against the definitions emitted here.
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include <stb_image_resize2.h>

#define STBI_rgb_alpha 4

namespace {

uint32_t mipLevelCount(uint32_t width, uint32_t height)
{
  uint32_t levels = 1;
  uint32_t dim = std::max(width, height);
  while (dim > 1) {
    dim >>= 1;
    ++levels;
  }
  return levels;
}

/// Uploads RGBA8 as a standalone sampled image, with a mip chain when the
/// GPU can linearly blit the format. Atlas cells stay 1-level — a coarse
/// mip would mix neighbouring covers.
bool createStandaloneTexture(RenderDevice &device, const uint8_t *rgba,
                             uint32_t width, uint32_t height, VkImage &image,
                             VmaAllocation &allocation, VkImageView &view)
{
  const bool mipsOk =
    device.formatSupportsLinearBlit(VK_FORMAT_R8G8B8A8_SRGB);
  const uint32_t mips = mipsOk ? mipLevelCount(width, height) : 1u;
  const VkDeviceSize imageSize =
    static_cast<VkDeviceSize>(width) * height * 4;

  VkBuffer stagingBuffer;
  VmaAllocation stagingAlloc;
  device.createBuffer(imageSize, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
                        VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                      stagingBuffer, stagingAlloc);
  void *data = device.mapBuffer(stagingAlloc);
  std::memcpy(data, rgba, static_cast<size_t>(imageSize));
  device.unmapBuffer(stagingAlloc);

  VkImageUsageFlags usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT |
                            VK_IMAGE_USAGE_SAMPLED_BIT;
  if (mips > 1) usage |= VK_IMAGE_USAGE_TRANSFER_SRC_BIT;

  device.createImage(width, height, mips, VK_SAMPLE_COUNT_1_BIT,
                     VK_FORMAT_R8G8B8A8_SRGB, VK_IMAGE_TILING_OPTIMAL, usage,
                     VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, image, allocation);
  device.transitionImageLayout(image, VK_FORMAT_R8G8B8A8_SRGB,
                               VK_IMAGE_LAYOUT_UNDEFINED,
                               VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, mips);
  device.copyBufferToImage(stagingBuffer, image, width, height);
  if (mips > 1) {
    device.generateMipmaps(image, static_cast<int32_t>(width),
                           static_cast<int32_t>(height), mips);
  } else {
    device.transitionImageLayout(image, VK_FORMAT_R8G8B8A8_SRGB,
                                 VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                 VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
  }
  device.destroyBuffer(stagingBuffer, stagingAlloc);

  view = device.createImageView(image, VK_FORMAT_R8G8B8A8_SRGB,
                                VK_IMAGE_ASPECT_COLOR_BIT, mips);
  return view != VK_NULL_HANDLE;
}

}  // namespace

void TextureManager::initialize(RenderDevice& device) {
    std::lock_guard lock(mutex_);
    device_ = &device;
    if (const char *raw = std::getenv("LAVA_IMAGE_CACHE_MB")) {
        char *end = nullptr;
        const unsigned long long mb = std::strtoull(raw, &end, 10);
        if (end != raw && *end == '\0') dormantBudgetBytes_ = mb * 1024ull * 1024ull;
    }
    atlas_.initialize(device);
    std::cout << "TextureManager initialized\n";
}

void TextureManager::cleanUp() {
    std::lock_guard lock(mutex_);
    std::cout << "TextureManager cleaning up " << textures_.size() << " textures\n";
    
    // Clean up all textures
    for (auto& [path, textureData] : textures_) {
        if (textureData && device_ && textureData->ownsImage) {
            if (textureData->view != VK_NULL_HANDLE) {
                vkDestroyImageView(device_->getDevice(), textureData->view, nullptr);
                textureData->view = VK_NULL_HANDLE;
            }
            device_->destroyImage(textureData->image, textureData->allocation);
        }
    }
    
    atlas_.cleanUp();
    textures_.clear();
    textureById_.clear();
    windowTextures_.clear();
    windowUsers_.clear();
    pendingSlots_.clear();
    dormantBytes_ = 0;
    imageBytes_ = 0;
    dormantSlots_ = 0;
    device_ = nullptr;
}

bool TextureManager::hasTexture(const std::string& key) const {
    std::lock_guard lock(mutex_);
    return textures_.find(key) != textures_.end();
}

TextureHandle TextureManager::uploadTexture(const std::string& key,
                                            const uint8_t* rgba,
                                            uint32_t width, uint32_t height) {
    std::lock_guard lock(mutex_);
    if (!device_ || rgba == nullptr || width == 0 || height == 0) {
        return {VK_NULL_HANDLE, 0};
    }

    auto existing = textures_.find(key);
    if (existing != textures_.end()) {
        reviveLocked(*existing->second);
        existing->second->refCount++;
        existing->second->lastUsed = ++useCounter_;
        return {existing->second->view, existing->second->id,
                existing->second->uv0, existing->second->uv1};
    }

    if (ImageAtlas::Region r = atlas_.add(rgba, width, height); r.valid) {
        auto atlasData = std::make_unique<TextureData>();
        atlasData->view = atlas_.pageView(r.page);
        atlasData->path = key;
        atlasData->refCount = 1;
        atlasData->width = width;
        atlasData->height = height;
        atlasData->bytes = static_cast<uint64_t>(width) * height * 4;
        atlasData->ownsImage = false;
        atlasData->atlased = true;
        atlasData->atlasPage = r.page;
        atlasData->atlasSlot = r.slot;
        atlasData->uv0 = r.uv0;
        atlasData->uv1 = r.uv1;

        uint32_t atlasId = nextId_++;
        atlasData->id = atlasId;
        textureById_[atlasId] = atlasData.get();
        textures_[key] = std::move(atlasData);
        return {atlas_.pageView(r.page), atlasId, r.uv0, r.uv1};
    }

    VkImage textureImage = VK_NULL_HANDLE;
    VmaAllocation textureAlloc = VK_NULL_HANDLE;
    VkImageView view = VK_NULL_HANDLE;
    if (!createStandaloneTexture(*device_, rgba, width, height, textureImage,
                                 textureAlloc, view)) {
      return {VK_NULL_HANDLE, 0};
    }
    auto textureData = std::make_unique<TextureData>();
    textureData->image = textureImage;
    textureData->allocation = textureAlloc;
    textureData->view = view;
    textureData->path = key;
    textureData->refCount = 1;
    textureData->width = width;
    textureData->height = height;
    textureData->bytes = static_cast<uint64_t>(width) * height * 4;
    imageBytes_ += textureData->bytes;
    textureData->ownsImage = true;

    uint32_t textureId = nextId_++;
    textureData->id = textureId;
    textureById_[textureId] = textureData.get();
    textures_[key] = std::move(textureData);
    return {view, textureId};
}

TextureHandle TextureManager::loadTexture(const std::string& path) {
    std::lock_guard lock(mutex_);
    if (!device_) {
        std::cerr << "TextureManager not initialized!\n";
        return {VK_NULL_HANDLE, 0};
    }

    // Check if texture already loaded
    auto it = textures_.find(path);
    if (it != textures_.end()) {
        reviveLocked(*it->second);
        it->second->refCount++;
        it->second->lastUsed = ++useCounter_;
        std::cout << "Texture '" << path << "' already loaded, ref count: " << it->second->refCount << "\n";
        return {it->second->view, it->second->id, it->second->uv0, it->second->uv1};
    }

    // Load image from file
    int texWidth, texHeight, texChannels;
    stbi_uc* pixels = stbi_load(path.c_str(), &texWidth, &texHeight, &texChannels, STBI_rgb_alpha);
    
    if (!pixels) {
        std::cerr << "Failed to load texture: " << path << "\n";
        return {VK_NULL_HANDLE, 0};
    }

    // Small enough to pack? A wall of covers then costs one descriptor bind
    // and one draw rather than one each, which is the difference between a
    // scrolling grid working and silently drawing the wrong art past the
    // per-frame descriptor limit.
    if (ImageAtlas::Region r = atlas_.add(pixels, texWidth, texHeight); r.valid) {
        stbi_image_free(pixels);

        auto atlasData = std::make_unique<TextureData>();
        atlasData->view = atlas_.pageView(r.page);
        atlasData->path = path;
        atlasData->refCount = 1;
        atlasData->width = texWidth;
        atlasData->height = texHeight;
        atlasData->bytes = static_cast<uint64_t>(texWidth) * texHeight * 4;
        atlasData->ownsImage = false;   // the page owns the memory
        atlasData->atlased = true;
        atlasData->atlasPage = r.page;
        atlasData->atlasSlot = r.slot;
        atlasData->uv0 = r.uv0;
        atlasData->uv1 = r.uv1;

        uint32_t atlasId = nextId_++;
        atlasData->id = atlasId;
        textureById_[atlasId] = atlasData.get();
        textures_[path] = std::move(atlasData);

        std::cout << "Atlased texture '" << path << "' (" << texWidth << "x"
                  << texHeight << ") page " << r.page << " slot " << r.slot
                  << " ID " << atlasId << "\n";
        return {atlas_.pageView(r.page), atlasId, r.uv0, r.uv1};
    }

    VkImage textureImage = VK_NULL_HANDLE;
    VmaAllocation textureAlloc = VK_NULL_HANDLE;
    VkImageView textureImageView = VK_NULL_HANDLE;
    const bool uploaded = createStandaloneTexture(
        *device_, pixels, static_cast<uint32_t>(texWidth),
        static_cast<uint32_t>(texHeight), textureImage, textureAlloc,
        textureImageView);
    stbi_image_free(pixels);
    if (!uploaded) {
      return {VK_NULL_HANDLE, 0};
    }

    // Create texture data entry
    auto textureData = std::make_unique<TextureData>();
    textureData->image = textureImage;
    textureData->allocation = textureAlloc;
    textureData->view = textureImageView;
    textureData->path = path;
    textureData->refCount = 1;
    textureData->width = texWidth;
    textureData->height = texHeight;
    textureData->bytes = static_cast<uint64_t>(texWidth) * texHeight * 4;
    imageBytes_ += textureData->bytes;
    textureData->ownsImage = true;

    uint32_t textureId = nextId_++;
    textureData->id = textureId;
    textureById_[textureId] = textureData.get();
    textures_[path] = std::move(textureData);

    std::cout << "Loaded texture '" << path << "' (" << texWidth << "x" << texHeight 
              << ") with ID " << textureId << "\n";

    return {textureImageView, textureId};
}

TextureHandle TextureManager::registerTexture(const std::string& name, 
                                                             VkImageView imageView,
                                                             uint32_t width, uint32_t height) {
    std::lock_guard lock(mutex_);
    if (!device_) {
        std::cerr << "TextureManager not initialized!\n";
        return {VK_NULL_HANDLE, 0};
    }

    // Check if already registered
    auto it = textures_.find(name);
    if (it != textures_.end()) {
        reviveLocked(*it->second);
        it->second->refCount++;
        it->second->lastUsed = ++useCounter_;
        return {it->second->view, it->second->id};
    }

    // Create texture data entry for external texture
    auto textureData = std::make_unique<TextureData>();
    textureData->view = imageView;
    textureData->path = name;
    textureData->refCount = 1;
    textureData->width = width;
    textureData->height = height;
    // Note: image and memory are not owned by TextureManager for external textures
    textureData->ownsImage = false;

    uint32_t textureId = nextId_++;
    textureData->id = textureId;
    textureById_[textureId] = textureData.get();
    textures_[name] = std::move(textureData);

    std::cout << "Registered external texture '" << name << "' with ID " << textureId << "\n";

    return {imageView, textureId};
}

TextureHandle TextureManager::reviveTexture(const std::string& key) {
    std::lock_guard lock(mutex_);
    auto it = textures_.find(key);
    if (it == textures_.end()) return {VK_NULL_HANDLE, 0};
    reviveLocked(*it->second);
    it->second->refCount++;
    it->second->lastUsed = ++useCounter_;
    return {it->second->view, it->second->id, it->second->uv0, it->second->uv1};
}

void TextureManager::unloadTexture(const std::string& path) {
    std::lock_guard lock(mutex_);
    auto it = textures_.find(path);
    if (it != textures_.end()) unloadLocked(it);
}

void TextureManager::unloadTexture(uint32_t textureId) {
    // One lock for lookup *and* release. Resolving the id to a path, dropping
    // the lock and re-entering by path would let an eviction and a fresh
    // registration under the same key slip in between, landing the decrement
    // on a different texture than the caller named.
    std::lock_guard lock(mutex_);
    auto byId = textureById_.find(textureId);
    if (byId == textureById_.end()) return;
    auto it = textures_.find(byId->second->path);
    if (it != textures_.end() && it->second.get() == byId->second) unloadLocked(it);
}

void TextureManager::unloadLocked(TextureIter it) {
    TextureData &data = *it->second;
    if (data.refCount == 0) return;
    if (--data.refCount != 0) return;

    // An external view has an owner outside this cache, so there is nothing
    // here to keep warm — drop the entry and leave the view to its owner.
    // Anything we do own goes dormant instead, so reopening a window or
    // scrolling back reuses the same id and the pixels already on the GPU.
    if (!data.ownsImage && !data.atlased) {
        eraseTextureLocked(it);
        return;
    }
    markDormantLocked(data);
    // `it` may be erased by either of these — it is dormant and, if nothing
    // pins it, a candidate for its own eviction. Nothing touches it after.
    if (data.atlased) evictAtlasSlotsLocked();
    else evictDormantLocked();
}

void TextureManager::markDormantLocked(TextureData &data) {
    if (data.dormant) return;
    data.dormant = true;
    data.lastUsed = ++useCounter_;
    if (data.atlased) ++dormantSlots_;
    else if (data.ownsImage) dormantBytes_ += data.bytes;
}

void TextureManager::reviveLocked(TextureData &data) {
    if (!data.dormant) return;
    data.dormant = false;
    if (data.atlased) {
        if (dormantSlots_) --dormantSlots_;
    } else if (data.ownsImage) {
        dormantBytes_ -= std::min(dormantBytes_, data.bytes);
    }
    ++cacheHits_;
}

void TextureManager::updateWindowTextureReferences(
    const void *window, const std::unordered_set<uint32_t> &textureIds) {
    std::lock_guard lock(mutex_);
    auto &old = windowTextures_[window];
    for (uint32_t id : old) {
        if (textureIds.contains(id)) continue;
        auto users = windowUsers_.find(id);
        if (users != windowUsers_.end() && --users->second == 0) windowUsers_.erase(users);
    }
    for (uint32_t id : textureIds) {
        if (!old.contains(id)) ++windowUsers_[id];
        if (auto found = textureById_.find(id); found != textureById_.end())
            found->second->lastUsed = ++useCounter_;
    }
    old = textureIds;
    evictDormantLocked();
    evictAtlasSlotsLocked();
}

void TextureManager::removeWindowTextureReferences(const void *window) {
    std::lock_guard lock(mutex_);
    auto found = windowTextures_.find(window);
    if (found == windowTextures_.end()) return;
    for (uint32_t id : found->second) {
        auto users = windowUsers_.find(id);
        if (users != windowUsers_.end() && --users->second == 0) windowUsers_.erase(users);
    }
    windowTextures_.erase(found);
    evictDormantLocked();
    evictAtlasSlotsLocked();
}

void TextureManager::eraseTextureLocked(TextureIter it) {
    TextureData &data = *it->second;
    textureById_.erase(data.id);
    if (data.dormant) {
        if (data.atlased) {
            if (dormantSlots_) --dormantSlots_;
        } else if (data.ownsImage) {
            dormantBytes_ -= std::min(dormantBytes_, data.bytes);
        }
    }
    if (data.atlased) {
        // Queued, not freed. Handing the cell back now would let the next
        // `add()` overwrite pixels a submitted frame is still sampling, and
        // deferred *destruction* cannot help because nothing is destroyed —
        // the cell is reused in place. `collectGarbage` returns it once the
        // retire clock passes this mark. Blocking on every fence here would
        // also work and was what this used to do, but it is illegal from the
        // callers that reach this: eviction runs mid-frame under a shared
        // frame lock, where reading another window's fences races its own
        // `vkResetFences`.
        pendingSlots_.push_back({data.atlasPage, data.atlasSlot,
                                 device_ ? device_->pendingSubmissionMark() : 0});
    } else if (data.ownsImage) {
        imageBytes_ -= std::min(imageBytes_, data.bytes);
        if (device_)
            device_->destroyImageDeferred(data.image, data.allocation, data.view);
    }
    textures_.erase(it);
}

std::vector<TextureManager::TextureData *>
TextureManager::dormantVictimsLocked(bool atlased) const {
    std::vector<TextureData *> victims;
    for (const auto &[key, data] : textures_) {
        if (data->dormant && data->atlased == atlased
            && !windowUsers_.contains(data->id)) {
            victims.push_back(data.get());
        }
    }
    std::sort(victims.begin(), victims.end(),
              [](const TextureData *a, const TextureData *b) {
                  return a->lastUsed < b->lastUsed;
              });
    return victims;
}

void TextureManager::eraseByPointerLocked(TextureData *data) {
    auto it = textures_.find(data->path);
    if (it == textures_.end() || it->second.get() != data) return;
    eraseTextureLocked(it);
    ++evictions_;
}

void TextureManager::evictDormantLocked() {
    if (dormantBytes_ <= dormantBudgetBytes_) return;
    for (TextureData *data : dormantVictimsLocked(/*atlased=*/false)) {
        if (dormantBytes_ <= dormantBudgetBytes_) break;
        eraseByPointerLocked(data);
    }
}

void TextureManager::evictAtlasSlotsLocked() {
    const uint32_t capacity = atlas_.capacitySlots();
    if (capacity == 0) return;
    // Cells already queued for return still read as used, but the space is on
    // its way back; charging for them would evict live entries to make room
    // that is about to appear anyway.
    const uint32_t queued = static_cast<uint32_t>(pendingSlots_.size());
    const uint32_t inUse = atlas_.usedSlots();
    uint32_t used = inUse > queued ? inUse - queued : 0;
    if (used * 100u < capacity * kSlotHighWaterPct) return;

    // Down to the low-water mark rather than just under the high one, so a
    // steadily scrolling grid pays for one sweep occasionally instead of an
    // eviction per image at the boundary.
    const uint32_t target = capacity * kSlotLowWaterPct / 100u;
    for (TextureData *data : dormantVictimsLocked(/*atlased=*/true)) {
        if (used <= target) break;
        eraseByPointerLocked(data);
        --used;
    }
}

void TextureManager::collectGarbage(uint64_t retiredSubmission) {
    std::lock_guard lock(mutex_);
    size_t keep = 0;
    for (const PendingSlot &pending : pendingSlots_) {
        // Only submissions *before* the mark can name the cell; once the
        // oldest one still running has reached it, none of them can.
        if (pending.queuedAt > retiredSubmission) {
            pendingSlots_[keep++] = pending;
            continue;
        }
        atlas_.freeSlot(pending.page, pending.slot);
    }
    pendingSlots_.resize(keep);
}

TextureManager::CacheStats TextureManager::cacheStats() const {
    std::lock_guard lock(mutex_);
    CacheStats stats;
    stats.imageBytes = imageBytes_;
    stats.dormantBytes = dormantBytes_;
    stats.dormantBudgetBytes = dormantBudgetBytes_;
    stats.atlasBytes = atlas_.allocatedBytes();
    stats.cacheHits = cacheHits_;
    stats.evictions = evictions_;
    stats.textures = static_cast<uint32_t>(textures_.size());
    stats.atlasSlotsUsed = atlas_.usedSlots();
    stats.atlasSlotsCapacity = atlas_.capacitySlots();
    stats.dormantSlots = dormantSlots_;
    stats.pendingSlots = static_cast<uint32_t>(pendingSlots_.size());
    // Only ids that still resolve: a draw list naming a texture that is gone
    // leaves a pin behind, and counting those would report more pinned
    // textures than there are textures.
    for (const auto &[id, count] : windowUsers_) {
        if (textureById_.contains(id)) ++stats.pinnedTextures;
    }
    return stats;
}

void TextureManager::getTextureUV(uint32_t textureId, vec2 &uv0, vec2 &uv1) const {
    std::lock_guard lock(mutex_);
    auto it = textureById_.find(textureId);
    if (it == textureById_.end()) {
        uv0 = {0.f, 0.f};
        uv1 = {1.f, 1.f};
        return;
    }
    uv0 = it->second->uv0;
    uv1 = it->second->uv1;
}

VkImageView TextureManager::getTextureView(uint32_t textureId) const {
    std::lock_guard lock(mutex_);
    auto it = textureById_.find(textureId);
    if (it != textureById_.end()) {
        return it->second->view;
    }
    return VK_NULL_HANDLE;
}

std::pair<uint32_t, uint32_t> TextureManager::getTextureDimensions(uint32_t textureId) const {
    std::lock_guard lock(mutex_);
    auto it = textureById_.find(textureId);
    if (it != textureById_.end()) {
        return {it->second->width, it->second->height};
    }
    return {0, 0};
}
