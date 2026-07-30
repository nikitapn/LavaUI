#pragma once

#include <unordered_map>
#include <memory>
#include <string>

#include <vulkan/vulkan.h>
#include "vk_mem_alloc.h"

#include "util/types.hpp"

class Vulkan;

struct TextureHandle {
  VkImageView view;
  uint32_t id;
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
    };

    std::unordered_map<std::string, std::unique_ptr<TextureData>> textures_;
    std::unordered_map<uint32_t, TextureData*> textureById_;
    Vulkan* vulkan_ = nullptr;
    uint32_t nextId_ = 1; // Start from 1, 0 means invalid

public:
    // Singleton access
    static TextureManager& getInstance() {
        static TextureManager instance;
        return instance;
    }

    void initialize(Vulkan& vulkan);
    void cleanUp();

    // Load texture from file
    TextureHandle loadTexture(const std::string& path);
    
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

private:
    TextureManager() = default;
    ~TextureManager() = default;
    TextureManager(const TextureManager&) = delete;
    TextureManager& operator=(const TextureManager&) = delete;
};
