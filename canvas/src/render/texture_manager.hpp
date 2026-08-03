#pragma once

#include <unordered_map>
#include <memory>
#include <string>

#include <vulkan/vulkan.h>
#include "vk_mem_alloc.h"

#include "util/types.hpp"
#include "render/image_atlas.hpp"

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
        /// False for external views (e.g. shadow map) we do not own.
        bool ownsImage = true;
        /// Set when the pixels live in an atlas page rather than an image of
        /// their own — then `image`/`allocation` are null and releasing means
        /// returning the cell, not destroying anything.
        bool atlased = false;
        uint32_t atlasPage = 0;
        uint32_t atlasSlot = 0;
        vec2 uv0{0.f, 0.f};
        vec2 uv1{1.f, 1.f};
    };

    std::unordered_map<std::string, std::unique_ptr<TextureData>> textures_;
    std::unordered_map<uint32_t, TextureData*> textureById_;
    RenderDevice* device_ = nullptr;
    uint32_t nextId_ = 1; // Start from 1, 0 means invalid
    ImageAtlas atlas_;

public:
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

    /// True if `key` is already resident, so a caller can skip decoding.
    bool hasTexture(const std::string& key) const;
    
    // Register external texture (like shadow map)
    TextureHandle registerTexture(const std::string& name, VkImageView imageView, 
                                  uint32_t width = 0, uint32_t height = 0);
    
    // Unload texture (decreases ref count)
    void unloadTexture(const std::string& path);
    void unloadTexture(uint32_t textureId);
    
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

private:
    TextureManager() = default;
    ~TextureManager() = default;
    TextureManager(const TextureManager&) = delete;
    TextureManager& operator=(const TextureManager&) = delete;
};
