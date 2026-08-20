#pragma once

#include <unordered_map>
#include <unordered_set>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <vulkan/vulkan.h>
#include "vk_mem_alloc.h"

#include "util/types.hpp"
#include "render/image_atlas.hpp"
#include "render/imported_dmabuf.hpp"

class RenderDevice;

struct TextureHandle {
  VkImageView view;
  uint32_t id;
  /// Sub-rect to sample. Full [0,1] unless the texture was packed into an
  /// atlas page, in which case `view` is the page and this is its cell.
  vec2 uv0{0.f, 0.f};
  vec2 uv1{1.f, 1.f};
  bool isValid() const { return view != VK_NULL_HANDLE && id != 0; }
  bool operator!=(const TextureHandle& other) const {
    return view != other.view || id != other.id;
  }
};

class TextureManager {
private:
    struct TextureData {
        VkImage image = VK_NULL_HANDLE;
        VmaAllocation allocation = VK_NULL_HANDLE;
        VkImageView view = VK_NULL_HANDLE;
        std::string path;
        uint32_t refCount = 0;
        uint32_t width = 0;
        uint32_t height = 0;
        uint32_t id = 0;
        uint64_t bytes = 0;
        uint64_t lastUsed = 0;
        bool dormant = false;
        /// False for external views we do not own — a view created elsewhere
        /// and registered here only so draw lists can name it.
        bool ownsImage = true;
        /// Asked to go rather than to go dormant — see `discardTexture`. Kept
        /// as a flag because "it can go" and "nothing is looking at it any
        /// more" are different moments: a frost snapshot is dead the instant a
        /// newer one exists, but the window's last drawn frame still names it
        /// until that window draws again.
        bool discard = false;
        /// Set when the pixels live in an atlas page rather than an image of
        /// their own — then `image`/`allocation` are null and releasing means
        /// returning the cell, not destroying anything.
        bool atlased = false;
        uint32_t atlasPage = 0;
        uint32_t atlasSlot = 0;
        vec2 uv0{0.f, 0.f};
        vec2 uv1{1.f, 1.f};
    };

    /// An atlas cell whose entry is gone but whose pixels a frame already
    /// submitted may still sample.
    ///
    /// Unlike a standalone image this cannot go to `destroyImageDeferred`:
    /// nothing is destroyed, the cell is *reused*, and reuse overwrites those
    /// pixels in place. So the slot is held back and returned only once the
    /// device's retire clock passes `queuedAt` — the same contract, on the same
    /// clock, without the stall that blocking on every fence would cost.
    struct PendingSlot {
        uint32_t page = 0;
        uint32_t slot = 0;
        uint64_t queuedAt = 0;
    };

    std::unordered_map<std::string, std::unique_ptr<TextureData>> textures_;
    std::unordered_map<uint32_t, TextureData*> textureById_;
    RenderDevice* device_ = nullptr;
    uint32_t nextId_ = 1; // Start from 1, 0 means invalid
    ImageAtlas atlas_;
    mutable std::mutex mutex_;
    std::unordered_map<const void *, std::unordered_set<uint32_t>> windowTextures_;
    std::unordered_map<uint32_t, uint32_t> windowUsers_;
    std::vector<PendingSlot> pendingSlots_;
    uint64_t useCounter_ = 0;
    /// Standalone images this cache owns. Atlased entries are deliberately not
    /// counted: their pixels live in pages already reported as `atlasBytes`,
    /// and adding both counts the same memory twice.
    uint64_t imageBytes_ = 0;
    /// The subset of `imageBytes_` at refcount zero — what the budget governs.
    uint64_t dormantBytes_ = 0;
    uint64_t dormantBudgetBytes_ = 256ull * 1024ull * 1024ull;
    /// Atlased entries at refcount zero, still holding their cells.
    uint32_t dormantSlots_ = 0;
    uint64_t cacheHits_ = 0;
    uint64_t evictions_ = 0;
    void *surfaceResolverCtx_ = nullptr;
    int (*surfaceResolver_)(void *, uint32_t, uint32_t) = nullptr;

    /// Atlas eviction runs on slot pressure, never on the byte budget.
    ///
    /// A cell is at most `cellSize²·4` — 256 KiB at the default — and there are
    /// only `capacitySlots()` of them, so every cell in the atlas dormant at
    /// once is still an order of magnitude under a sane byte budget. Waiting
    /// for bytes would mean the atlas fills, `add()` starts refusing, and every
    /// further image silently becomes a standalone texture with a descriptor
    /// bind of its own — which is the batching collapse the atlas exists to
    /// prevent. Slots are the scarce resource here; bytes are not.
    static constexpr uint32_t kSlotHighWaterPct = 90;
    static constexpr uint32_t kSlotLowWaterPct = 75;

public:
    struct CacheStats {
        /// Standalone owned images; excludes atlas pages, see `atlasBytes`.
        uint64_t imageBytes = 0;
        uint64_t dormantBytes = 0;
        uint64_t dormantBudgetBytes = 0;
        uint64_t atlasBytes = 0;
        /// Dormant entries revived without a decode or an upload.
        uint64_t cacheHits = 0;
        uint64_t evictions = 0;
        uint32_t textures = 0;
        uint32_t pinnedTextures = 0;
        uint32_t atlasSlotsUsed = 0;
        uint32_t atlasSlotsCapacity = 0;
        uint32_t dormantSlots = 0;
        uint32_t pendingSlots = 0;
    };
    // Singleton access
    static TextureManager& getInstance() {
        static TextureManager instance;
        return instance;
    }

    void initialize(RenderDevice& device);
    void cleanUp();

    // Load texture from file
    TextureHandle loadTexture(const std::string& path);

    /// Uploads already-decoded RGBA8 pixels under `key`.
    ///
    /// Split from `loadTexture` so decoding — the slow, purely-CPU half — can
    /// run on a worker while only this half, which touches Vulkan, stays on
    /// the thread that owns the device.
    TextureHandle uploadTexture(const std::string& key, const uint8_t* rgba,
                                uint32_t width, uint32_t height);

    /// GPU-side crop of a dma-buf another driver wrote. Same cache contract
    /// as `uploadTexture`, without a host copy: the importer blits `x,y,w,h`
    /// into an `R8G8B8A8_UNORM` sampled image. Invalid handle on failure.
    TextureHandle importDmabufTexture(const std::string &key,
                                      const canvas::DmabufImport &src,
                                      int32_t x, int32_t y, uint32_t w,
                                      uint32_t h, uint32_t maxSide = 0);

    /// How a compositor-side draw list names another surface as a texture.
    ///
    /// Installed by the compositor (`CanvasRenderer`). `surfaceId` is a
    /// `SubscribeWindows` id; `maxSide` is the longest dest edge (0 = native).
    /// Returns a TextureManager id, or 0. Called from replay, so it must not
    /// start a frame of its own.
    using SurfaceResolver = int (*)(void *ctx, uint32_t surfaceId,
                                    uint32_t maxSide);
    void setSurfaceResolver(void *ctx, SurfaceResolver fn);
    int resolveSurfaceTexture(uint32_t surfaceId, uint32_t maxSide);

    /// True if `key` is already resident, so a caller can skip decoding.
    ///
    /// Only a hint — the entry can be evicted before the caller acts on it.
    /// Anything that wants to *use* the result wants `reviveTexture`, which
    /// takes the reference under the same lock as the lookup.
    bool hasTexture(const std::string& key) const;

    /// Takes a reference on `key` if it is resident, reviving it if dormant.
    ///
    /// The atomic form of "is it there? then load it". `loadTexture` cannot
    /// serve that: on a miss it falls through to treating the key as a file
    /// path, which for a content-hash key is a spurious decode attempt and for
    /// a real path is worse — a full-resolution load that ignores the size cap
    /// the caller decoded to. Returns an invalid handle if `key` is absent.
    TextureHandle reviveTexture(const std::string& key);

    // Register a view created elsewhere. No image is allocated and none is
    // freed on unload; this only gives an existing view an id.
    TextureHandle registerTexture(const std::string& name, VkImageView imageView, 
                                  uint32_t width = 0, uint32_t height = 0);
    
    // Unload texture (decreases ref count)
    void unloadTexture(const std::string& path);
    void unloadTexture(uint32_t textureId);

    /// Drops `key` outright once its last reference goes, instead of parking it
    /// in the dormant set.
    ///
    /// For an entry nothing can ever ask for again. The dormant set is a bet
    /// that a key will come back — reopening a window, scrolling a list of
    /// covers back up — and it is a good bet for a path or a content hash. It is
    /// no bet at all for a key with a *generation counter* in it: the
    /// compositor's frost snapshots are `frost:<surface>:<n>` and its Alt+Tab
    /// posters `poster:<gen>:<surface>:<side>`, where the counter only goes
    /// up, so every release parks a texture that is provably dead. Ten frosts
    /// is 79 MiB the byte budget will not reclaim until it notices 256 — and
    /// the posters simply fill the 256, at a few megabytes per window per
    /// Alt+Tab, for a cache that can never hit.
    ///
    /// Still deferred, not immediate: a submitted frame may be sampling it, so
    /// this goes through `destroyImageDeferred` like every other release.
    void discardTexture(const std::string& key);

    /// Pins every texture named by a window's latest complete draw list.
    /// Client registrations are ownership; these are retained-frame safety
    /// references, so an idle sibling window cannot lose pixels when another
    /// window advances the client-side cache.
    void updateWindowTextureReferences(
        const void *window, const std::unordered_set<uint32_t> &textureIds);
    void removeWindowTextureReferences(const void *window);
    
    // Get texture view by ID
    VkImageView getTextureView(uint32_t textureId) const;
    
    // Get texture dimensions
    std::pair<uint32_t, uint32_t> getTextureDimensions(uint32_t textureId) const;

    /// Sub-rect for a texture id — full [0,1] for a standalone image, the cell
    /// for an atlased one. Callers must pass this to the renderer instead of
    /// assuming the whole view.
    void getTextureUV(uint32_t textureId, vec2 &uv0, vec2 &uv1) const;

    /// Atlas used for images small enough to pack. Exposed so the app can
    /// report occupancy; adding entries goes through `loadTexture`.
    ImageAtlas &atlas() { return atlas_; }
    const ImageAtlas &atlas() const { return atlas_; }
    CacheStats cacheStats() const;

    /// One cache entry, for a report that has to say *which* pictures are
    /// resident rather than only how many megabytes they add up to.
    ///
    /// The key is the answer to "why is this still here": a path names a file
    /// something asked for, a content hash names bytes a client uploaded, and a
    /// `surface:` key names another window being sampled as a texture.
    struct Entry {
        std::string key;
        uint64_t bytes = 0;
        uint32_t width = 0;
        uint32_t height = 0;
        uint32_t mipLevels = 1;
        uint32_t refCount = 0;
        /// Retained-frame pins from `updateWindowTextureReferences`, i.e. the
        /// windows whose last draw list still names it.
        uint32_t windowPins = 0;
        bool atlased = false;
        /// At refcount zero: kept only in case it is asked for again, and what
        /// the dormant budget governs.
        bool dormant = false;
        /// A registered external view — no memory of ours at all.
        bool external = false;
        /// `useCounter_` when it was last taken, so a reader can see LRU order.
        uint64_t lastUsed = 0;
    };

    /// Every resident entry, largest first. Debug tooling; takes the cache lock.
    std::vector<Entry> entries() const;

    /// Returns atlas cells whose last possible reader has retired.
    ///
    /// `retiredSubmission` is the mark from `RenderDevice::collectGarbage`, and
    /// this must be called *after* that returns, not from within it: eviction
    /// reaches `destroyImageDeferred` while holding `mutex_`, so taking
    /// `mutex_` underneath the device's `sharedStateMutex_` would close an
    /// ABBA cycle.
    void collectGarbage(uint64_t retiredSubmission);

private:
    using TextureIter =
        std::unordered_map<std::string, std::unique_ptr<TextureData>>::iterator;

    void unloadLocked(TextureIter it);
    void markDormantLocked(TextureData &data);
    void reviveLocked(TextureData &data);
    /// Dormant, unpinned entries of one kind, least-recently-used first.
    std::vector<TextureData *> dormantVictimsLocked(bool atlased) const;
    void evictDormantLocked();
    /// Erases every discarded entry nothing is looking at any more.
    void sweepDiscardedLocked();
    void evictAtlasSlotsLocked();
    void eraseByPointerLocked(TextureData *data);
    void eraseTextureLocked(TextureIter it);
    TextureManager() = default;
    ~TextureManager() = default;
    TextureManager(const TextureManager&) = delete;
    TextureManager& operator=(const TextureManager&) = delete;
};
