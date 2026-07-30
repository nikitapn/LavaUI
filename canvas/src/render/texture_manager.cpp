#include <iostream>
#include <cstring>

#include "render/vulkan.hpp"
#include "render/texture_manager.hpp"

#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>

#define STBI_rgb_alpha 4

void TextureManager::initialize(Vulkan& vulkan) {
    vulkan_ = &vulkan;
    std::cout << "TextureManager initialized\n";
}

void TextureManager::cleanUp() {
    std::cout << "TextureManager cleaning up " << textures_.size() << " textures\n";
    
    // Clean up all textures
    for (auto& [path, textureData] : textures_) {
        if (textureData && vulkan_ && textureData->ownsImage) {
            if (textureData->view != VK_NULL_HANDLE) {
                vkDestroyImageView(vulkan_->getDevice(), textureData->view, nullptr);
                textureData->view = VK_NULL_HANDLE;
            }
            vulkan_->destroyImage(textureData->image, textureData->allocation);
        }
    }
    
    textures_.clear();
    textureById_.clear();
    vulkan_ = nullptr;
}

TextureHandle TextureManager::loadTexture(const std::string& path) {
    if (!vulkan_) {
        std::cerr << "TextureManager not initialized!\n";
        return {VK_NULL_HANDLE, 0};
    }

    // Check if texture already loaded
    auto it = textures_.find(path);
    if (it != textures_.end()) {
        it->second->refCount++;
        std::cout << "Texture '" << path << "' already loaded, ref count: " << it->second->refCount << "\n";
        
        // Find the texture ID for this texture
        uint32_t foundId = 0;
        for (const auto& [id, textureData] : textureById_) {
            if (textureData == it->second.get()) {
                foundId = id;
                break;
            }
        }
        return {it->second->view, foundId};
    }

    // Load image from file
    int texWidth, texHeight, texChannels;
    stbi_uc* pixels = stbi_load(path.c_str(), &texWidth, &texHeight, &texChannels, STBI_rgb_alpha);
    
    if (!pixels) {
        std::cerr << "Failed to load texture: " << path << "\n";
        return {VK_NULL_HANDLE, 0};
    }

    VkDeviceSize imageSize = texWidth * texHeight * 4;

    // Create staging buffer
    VkBuffer stagingBuffer;
    VmaAllocation stagingAlloc;
    vulkan_->createBuffer(
        imageSize,
        VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        stagingBuffer,
        stagingAlloc);

    void *data = vulkan_->mapBuffer(stagingAlloc);
    memcpy(data, pixels, static_cast<size_t>(imageSize));
    vulkan_->unmapBuffer(stagingAlloc);

    stbi_image_free(pixels);

    // Create texture image
    VkImage textureImage;
    VmaAllocation textureAlloc;
    vulkan_->createImage(texWidth, texHeight, 1, VK_SAMPLE_COUNT_1_BIT,
                        VK_FORMAT_R8G8B8A8_SRGB, VK_IMAGE_TILING_OPTIMAL,
                        VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
                        VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                        textureImage, textureAlloc);

    // Transition image layout and copy from staging buffer
    vulkan_->transitionImageLayout(textureImage, VK_FORMAT_R8G8B8A8_SRGB,
                                  VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
    vulkan_->copyBufferToImage(stagingBuffer, textureImage, texWidth, texHeight);
    vulkan_->transitionImageLayout(textureImage, VK_FORMAT_R8G8B8A8_SRGB,
                                  VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);

    vulkan_->destroyBuffer(stagingBuffer, stagingAlloc);

    // Create image view
    VkImageView textureImageView = vulkan_->createImageView(textureImage, VK_FORMAT_R8G8B8A8_SRGB, 
                                                           VK_IMAGE_ASPECT_COLOR_BIT, 1);

    // Create texture data entry
    auto textureData = std::make_unique<TextureData>();
    textureData->image = textureImage;
    textureData->allocation = textureAlloc;
    textureData->view = textureImageView;
    textureData->path = path;
    textureData->refCount = 1;
    textureData->width = texWidth;
    textureData->height = texHeight;
    textureData->ownsImage = true;

    uint32_t textureId = nextId_++;
    textureById_[textureId] = textureData.get();
    textures_[path] = std::move(textureData);

    std::cout << "Loaded texture '" << path << "' (" << texWidth << "x" << texHeight 
              << ") with ID " << textureId << "\n";

    return {textureImageView, textureId};
}

TextureHandle TextureManager::registerTexture(const std::string& name, 
                                                             VkImageView imageView,
                                                             uint32_t width, uint32_t height) {
    if (!vulkan_) {
        std::cerr << "TextureManager not initialized!\n";
        return {VK_NULL_HANDLE, 0};
    }

    // Check if already registered
    auto it = textures_.find(name);
    if (it != textures_.end()) {
        it->second->refCount++;
        // Find the texture ID for this texture
        uint32_t foundId = 0;
        for (const auto& [id, textureData] : textureById_) {
            if (textureData == it->second.get()) {
                foundId = id;
                break;
            }
        }
        return {it->second->view, foundId};
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
    textureById_[textureId] = textureData.get();
    textures_[name] = std::move(textureData);

    std::cout << "Registered external texture '" << name << "' with ID " << textureId << "\n";

    return {imageView, textureId};
}

void TextureManager::unloadTexture(const std::string& path) {
    auto it = textures_.find(path);
    if (it == textures_.end()) {
        return;
    }

    it->second->refCount--;
    if (it->second->refCount == 0) {
        std::cout << "Unloading texture '" << path << "'\n";
        
        // Remove from ID map
        for (auto idIt = textureById_.begin(); idIt != textureById_.end(); ++idIt) {
            if (idIt->second == it->second.get()) {
                textureById_.erase(idIt);
                break;
            }
        }

        // Clean up Vulkan resources (only if we own them)
        if (vulkan_ && it->second->ownsImage) {
            if (it->second->view != VK_NULL_HANDLE) {
                vkDestroyImageView(vulkan_->getDevice(), it->second->view, nullptr);
                it->second->view = VK_NULL_HANDLE;
            }
            vulkan_->destroyImage(it->second->image, it->second->allocation);
        }

        textures_.erase(it);
    }
}

void TextureManager::unloadTexture(uint32_t textureId) {
    auto it = textureById_.find(textureId);
    if (it != textureById_.end()) {
        unloadTexture(it->second->path);
    }
}

VkImageView TextureManager::getTextureView(uint32_t textureId) const {
    auto it = textureById_.find(textureId);
    if (it != textureById_.end()) {
        return it->second->view;
    }
    return VK_NULL_HANDLE;
}

std::pair<uint32_t, uint32_t> TextureManager::getTextureDimensions(uint32_t textureId) const {
    auto it = textureById_.find(textureId);
    if (it != textureById_.end()) {
        return {it->second->width, it->second->height};
    }
    return {0, 0};
}
