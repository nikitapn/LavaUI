#include <iostream>
#include <cstring>

#include "render/vulkan.hpp"
#include "render/texture_manager.hpp"

#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>

#define STBI_rgb_alpha 4

void TextureManager::initialize(Vulkan& vulkan) {
    vulkan_ = &vulkan;
    atlas_.initialize(vulkan);
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
    
    atlas_.cleanUp();
    textures_.clear();
    textureById_.clear();
    vulkan_ = nullptr;
}

bool TextureManager::hasTexture(const std::string& key) const {
    return textures_.find(key) != textures_.end();
}

TextureHandle TextureManager::uploadTexture(const std::string& key,
                                            const uint8_t* rgba,
                                            uint32_t width, uint32_t height) {
    if (!vulkan_ || rgba == nullptr || width == 0 || height == 0) {
        return {VK_NULL_HANDLE, 0};
    }

    auto existing = textures_.find(key);
    if (existing != textures_.end()) {
        existing->second->refCount++;
        uint32_t foundId = 0;
        for (const auto& [id, data] : textureById_) {
            if (data == existing->second.get()) { foundId = id; break; }
        }
        return {existing->second->view, foundId,
                existing->second->uv0, existing->second->uv1};
    }

    if (ImageAtlas::Region r = atlas_.add(rgba, width, height); r.valid) {
        auto atlasData = std::make_unique<TextureData>();
        atlasData->view = atlas_.pageView(r.page);
        atlasData->path = key;
        atlasData->refCount = 1;
        atlasData->width = width;
        atlasData->height = height;
        atlasData->ownsImage = false;
        atlasData->atlased = true;
        atlasData->atlasPage = r.page;
        atlasData->atlasSlot = r.slot;
        atlasData->uv0 = r.uv0;
        atlasData->uv1 = r.uv1;

        uint32_t atlasId = nextId_++;
        textureById_[atlasId] = atlasData.get();
        textures_[key] = std::move(atlasData);
        return {atlas_.pageView(r.page), atlasId, r.uv0, r.uv1};
    }

    const VkDeviceSize imageSize = static_cast<VkDeviceSize>(width) * height * 4;
    VkBuffer stagingBuffer;
    VmaAllocation stagingAlloc;
    vulkan_->createBuffer(imageSize, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
                            | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                          stagingBuffer, stagingAlloc);
    void* data = vulkan_->mapBuffer(stagingAlloc);
    memcpy(data, rgba, static_cast<size_t>(imageSize));
    vulkan_->unmapBuffer(stagingAlloc);

    VkImage textureImage;
    VmaAllocation textureAlloc;
    vulkan_->createImage(width, height, 1, VK_SAMPLE_COUNT_1_BIT,
                         VK_FORMAT_R8G8B8A8_SRGB, VK_IMAGE_TILING_OPTIMAL,
                         VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
                         VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                         textureImage, textureAlloc);
    vulkan_->transitionImageLayout(textureImage, VK_FORMAT_R8G8B8A8_SRGB,
                                   VK_IMAGE_LAYOUT_UNDEFINED,
                                   VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
    vulkan_->copyBufferToImage(stagingBuffer, textureImage, width, height);
    vulkan_->transitionImageLayout(textureImage, VK_FORMAT_R8G8B8A8_SRGB,
                                   VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                   VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    vulkan_->destroyBuffer(stagingBuffer, stagingAlloc);

    VkImageView view = vulkan_->createImageView(textureImage, VK_FORMAT_R8G8B8A8_SRGB,
                                                VK_IMAGE_ASPECT_COLOR_BIT, 1);
    auto textureData = std::make_unique<TextureData>();
    textureData->image = textureImage;
    textureData->allocation = textureAlloc;
    textureData->view = view;
    textureData->path = key;
    textureData->refCount = 1;
    textureData->width = width;
    textureData->height = height;
    textureData->ownsImage = true;

    uint32_t textureId = nextId_++;
    textureById_[textureId] = textureData.get();
    textures_[key] = std::move(textureData);
    return {view, textureId};
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
        return {it->second->view, foundId, it->second->uv0, it->second->uv1};
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
        atlasData->ownsImage = false;   // the page owns the memory
        atlasData->atlased = true;
        atlasData->atlasPage = r.page;
        atlasData->atlasSlot = r.slot;
        atlasData->uv0 = r.uv0;
        atlasData->uv1 = r.uv1;

        uint32_t atlasId = nextId_++;
        textureById_[atlasId] = atlasData.get();
        textures_[path] = std::move(atlasData);

        std::cout << "Atlased texture '" << path << "' (" << texWidth << "x"
                  << texHeight << ") page " << r.page << " slot " << r.slot
                  << " ID " << atlasId << "\n";
        return {atlas_.pageView(r.page), atlasId, r.uv0, r.uv1};
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

        if (it->second->atlased) {
            atlas_.freeSlot(it->second->atlasPage, it->second->atlasSlot);
        }
        // Deferred: a frame submitted moments ago may still sample this
        // texture. Destroying it here is a use-after-free that surfaces as a
        // crash somewhere unrelated.
        if (vulkan_ && it->second->ownsImage) {
            vulkan_->destroyImageDeferred(it->second->image,
                                          it->second->allocation,
                                          it->second->view);
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

void TextureManager::getTextureUV(uint32_t textureId, vec2 &uv0, vec2 &uv1) const {
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
