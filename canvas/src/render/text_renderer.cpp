#include <pch.hpp>

#include <array>
#include <vector>
#include <iostream>
#include <stdexcept>
#include <unordered_map>

#include <ft2build.h>
#include FT_FREETYPE_H

#include <glm/gtc/matrix_transform.hpp>

#include "util/util.hpp"
#include "render/vulkan.hpp"
#include "render/shaders.hpp"
#include "render/text_renderer.hpp"

namespace {

struct TextInstance {
  vec2 position;       // World position (8 bytes, offset 0)
  vec2 uvTopLeft;      // Atlas UV coordinates (8 bytes, offset 8)  
  vec2 uvBottomRight;  // Atlas UV bottom-right (8 bytes, offset 16)
  vec2 size;           // Glyph size (8 bytes, offset 24)
  vec4 color;          // Text color with alpha (16 bytes, offset 32) - padded to vec4 for alignment
};

struct GlyphInfo {
  vec2  atlasUV[2];  // Top-left and bottom-right UV coordinates
  vec2  size;        // Glyph dimensions in pixels
  vec2  bearing;     // Glyph bearing (offset from baseline)
  float advance;     // Horizontal advance
};

}

// Implementation class - hidden from header
struct TextRenderer::Impl {
  Vulkan& vulkan_;
  Shaders shaders_;

  // Font/Atlas data
  FT_Library                              library_;
  FT_Face                                 face_;
  std::unordered_map<uint32_t, GlyphInfo> glyphMap_;

  // Vulkan resources
  VkImage        atlasTexture_;
  VkDeviceMemory atlasTextureMemory_;
  VkImageView    atlasTextureView_;
  VkSampler      atlasSampler_;

  // Rendering pipeline
  VkDescriptorSetLayout descriptorSetLayout_;
  VkPipelineLayout      pipelineLayout_;
  VkPipeline            renderPipeline_;
  VkDescriptorPool      descriptorPool_;
  VkDescriptorSet       descriptorSet_;

  // Instance data
  VkBuffer                  instanceBuffer_;
  VkDeviceMemory            instanceBufferMemory_;
  std::vector<TextInstance> instanceData_;
  
  // Quad vertex buffer for instanced rendering
  VkBuffer       quadVertexBuffer_;
  VkDeviceMemory quadVertexBufferMemory_;

  // Atlas management
  int atlasWidth_;
  int atlasHeight_;
  int currentX_;
  int currentY_;
  int lineHeight_;

  Impl(Vulkan& vulkan)
      : vulkan_(vulkan),
        shaders_(vulkan),
        library_(nullptr),
        face_(nullptr),
        atlasTexture_(VK_NULL_HANDLE),
        atlasTextureMemory_(VK_NULL_HANDLE),
        atlasTextureView_(VK_NULL_HANDLE),
        atlasSampler_(VK_NULL_HANDLE),
        descriptorSetLayout_(VK_NULL_HANDLE),
        pipelineLayout_(VK_NULL_HANDLE),
        renderPipeline_(VK_NULL_HANDLE),
        descriptorPool_(VK_NULL_HANDLE),
        descriptorSet_(VK_NULL_HANDLE),
        instanceBuffer_(VK_NULL_HANDLE),
        instanceBufferMemory_(VK_NULL_HANDLE),
        quadVertexBuffer_(VK_NULL_HANDLE),
        quadVertexBufferMemory_(VK_NULL_HANDLE),
        atlasWidth_(512),
        atlasHeight_(512),
        currentX_(0),
        currentY_(0),
        lineHeight_(0)
  {
  }

  void init() {
    // Create Vulkan resources
    createAtlasTexture();
    createQuadVertexBuffer();
    createRenderingPipeline();
  }

  void cleanUp() {
    VkDevice device = vulkan_.getDevice();

    // Cleanup Shaders
    shaders_.cleanUp();

    // Cleanup FreeType
    if (face_) {
      FT_Done_Face(face_);
    }
    if (library_) {
      FT_Done_FreeType(library_);
    }

    // Cleanup Vulkan resources
    if (instanceBuffer_ != VK_NULL_HANDLE) {
      vkDestroyBuffer(device, instanceBuffer_, nullptr);
    }
    if (instanceBufferMemory_ != VK_NULL_HANDLE) {
      vkFreeMemory(device, instanceBufferMemory_, nullptr);
    }
    if (quadVertexBuffer_ != VK_NULL_HANDLE) {
      vkDestroyBuffer(device, quadVertexBuffer_, nullptr);
    }
    if (quadVertexBufferMemory_ != VK_NULL_HANDLE) {
      vkFreeMemory(device, quadVertexBufferMemory_, nullptr);
    }
    if (renderPipeline_ != VK_NULL_HANDLE) {
      vkDestroyPipeline(device, renderPipeline_, nullptr);
    }
    if (pipelineLayout_ != VK_NULL_HANDLE) {
      vkDestroyPipelineLayout(device, pipelineLayout_, nullptr);
    }
    if (descriptorPool_ != VK_NULL_HANDLE) {
      vkDestroyDescriptorPool(device, descriptorPool_, nullptr);
    }
    if (descriptorSetLayout_ != VK_NULL_HANDLE) {
      vkDestroyDescriptorSetLayout(device, descriptorSetLayout_, nullptr);
    }
    if (atlasSampler_ != VK_NULL_HANDLE) {
      vkDestroySampler(device, atlasSampler_, nullptr);
    }
    if (atlasTextureView_ != VK_NULL_HANDLE) {
      vkDestroyImageView(device, atlasTextureView_, nullptr);
    }
    if (atlasTexture_ != VK_NULL_HANDLE) {
      vkDestroyImage(device, atlasTexture_, nullptr);
    }
    if (atlasTextureMemory_ != VK_NULL_HANDLE) {
      vkFreeMemory(device, atlasTextureMemory_, nullptr);
    }
  }

  ~Impl() {
    cleanUp();
  }

  canvas::VoidResult initializeFreeType(const std::string& fontPath, int fontSize) {
    if (library_) {
      // Reload: tear down previous face/library.
      if (face_) {
        FT_Done_Face(face_);
        face_ = nullptr;
      }
      FT_Done_FreeType(library_);
      library_ = nullptr;
    }

    FT_Error error = FT_Init_FreeType(&library_);
    if (error) {
      return canvas::fail("Failed to initialize FreeType");
    }

    error = FT_New_Face(library_, fontPath.c_str(), 0, &face_);
    if (error) {
      FT_Done_FreeType(library_);
      library_ = nullptr;
      return canvas::fail("Failed to load font: " + fontPath);
    }

    FT_Set_Pixel_Sizes(face_, 0, fontSize);

    lineHeight_ = static_cast<int>(
      (face_->size->metrics.ascender - face_->size->metrics.descender) / 64);
    return canvas::ok();
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

  void createQuadVertexBuffer() {
    // Define quad vertices in normalized coordinates (0,0 to 1,1)
    // This will be scaled by instance data
    struct QuadVertex {
      vec2 position;
    };
    
    std::vector<QuadVertex> quadVertices = {
      {{0.0f, 0.0f}}, // Top-left
      {{1.0f, 0.0f}}, // Top-right
      {{0.0f, 1.0f}}, // Bottom-left
      {{0.0f, 1.0f}}, // Bottom-left
      {{1.0f, 0.0f}}, // Top-right
      {{1.0f, 1.0f}}  // Bottom-right
    };
    
    VkDeviceSize bufferSize = sizeof(QuadVertex) * quadVertices.size();
    
    // Create staging buffer
    VkBuffer stagingBuffer;
    VkDeviceMemory stagingBufferMemory;
    vulkan_.createBuffer(bufferSize,
                         VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                         VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                         stagingBuffer,
                         stagingBufferMemory);

    // Copy vertex data to staging buffer
    void* data;
    VkDevice device = vulkan_.getDevice();
    vkMapMemory(device, stagingBufferMemory, 0, bufferSize, 0, &data);
    memcpy(data, quadVertices.data(), bufferSize);
    vkUnmapMemory(device, stagingBufferMemory);

    // Create vertex buffer
    vulkan_.createBuffer(bufferSize,
                         VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                         VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                         quadVertexBuffer_,
                         quadVertexBufferMemory_);

    // Copy from staging buffer to vertex buffer
    VkCommandBuffer commandBuffer = vulkan_.beginSingleTimeCommands();
    
    VkBufferCopy copyRegion{};
    copyRegion.size = bufferSize;
    vkCmdCopyBuffer(commandBuffer, stagingBuffer, quadVertexBuffer_, 1, &copyRegion);
    
    vulkan_.endSingleTimeCommands(commandBuffer);

    // Cleanup staging buffer
    vkDestroyBuffer(device, stagingBuffer, nullptr);
    vkFreeMemory(device, stagingBufferMemory, nullptr);
  }

  void createRenderingPipeline() {
    VkDevice device = vulkan_.getDevice();

    // Create descriptor set layout
    VkDescriptorSetLayoutBinding samplerBinding {
      .binding         = 0,
      .descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
      .descriptorCount = 1,
      .stageFlags      = VK_SHADER_STAGE_FRAGMENT_BIT,
    };

    VkDescriptorSetLayoutCreateInfo layoutInfo {
      .sType        = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
      .bindingCount = 1,
      .pBindings    = &samplerBinding,
    };

    VR(vkCreateDescriptorSetLayout(
         device, &layoutInfo, nullptr, &descriptorSetLayout_),
       "Failed to create text descriptor set layout");

    // Create descriptor pool
    VkDescriptorPoolSize poolSize {
      .type            = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
      .descriptorCount = 1,
    };

    VkDescriptorPoolCreateInfo poolInfo {
      .sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
      .maxSets       = 1,
      .poolSizeCount = 1,
      .pPoolSizes    = &poolSize,
    };

    VR(vkCreateDescriptorPool(device, &poolInfo, nullptr, &descriptorPool_),
       "Failed to create text descriptor pool");

    // Allocate descriptor set
    VkDescriptorSetAllocateInfo allocInfo {
      .sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
      .descriptorPool     = descriptorPool_,
      .descriptorSetCount = 1,
      .pSetLayouts        = &descriptorSetLayout_,
    };

    VR(vkAllocateDescriptorSets(device, &allocInfo, &descriptorSet_),
       "Failed to allocate text descriptor set");

    // Update descriptor set
    VkDescriptorImageInfo imageInfo {
      .sampler     = atlasSampler_,
      .imageView   = atlasTextureView_,
      .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };

    VkWriteDescriptorSet descriptorWrite {
      .sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
      .dstSet          = descriptorSet_,
      .dstBinding      = 0,
      .dstArrayElement = 0,
      .descriptorCount = 1,
      .descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
      .pImageInfo      = &imageInfo,
    };

    vkUpdateDescriptorSets(device, 1, &descriptorWrite, 0, nullptr);

    // Create push constant range for projection matrix and viewport size
    VkPushConstantRange pushConstantRange{
      .stageFlags = VK_SHADER_STAGE_VERTEX_BIT,
      .offset     = 0,
      .size       = sizeof(glm::mat4) + sizeof(glm::vec2)  // projection matrix + viewport size
    };

    // Create pipeline layout
    VkPipelineLayoutCreateInfo pipelineLayoutInfo{
      .sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
      .setLayoutCount         = 1,
      .pSetLayouts            = &descriptorSetLayout_,
      .pushConstantRangeCount = 1,
      .pPushConstantRanges    = &pushConstantRange,
    };

    VR(vkCreatePipelineLayout(device, &pipelineLayoutInfo, nullptr, &pipelineLayout_),
       "Failed to create text pipeline layout");

    // Create instance buffer (initially small, will grow as needed)
    const VkDeviceSize bufferSize =
      sizeof(TextInstance) * 1000;  // Start with space for 1000 glyphs

    vulkan_.createBuffer(
      bufferSize,
      VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT,
      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
        VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
      instanceBuffer_,
      instanceBufferMemory_);

    // Now create the actual graphics pipeline
    createTextGraphicsPipeline();
  }

  void createTextGraphicsPipeline() {
    VkDevice device = vulkan_.getDevice();

    // Load shaders
    VkShaderModule vertShaderModule = shaders_.loadShader("shaders/text.vert.bin");
    VkShaderModule fragShaderModule = shaders_.loadShader("shaders/text.frag.bin");

    VkPipelineShaderStageCreateInfo vertShaderStageInfo{
      .sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
      .stage  = VK_SHADER_STAGE_VERTEX_BIT,
      .module = vertShaderModule,
      .pName  = "main",
    };

    VkPipelineShaderStageCreateInfo fragShaderStageInfo{
      .sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
      .stage  = VK_SHADER_STAGE_FRAGMENT_BIT,
      .module = fragShaderModule,
      .pName  = "main",
    };

    VkPipelineShaderStageCreateInfo shaderStages[] = {vertShaderStageInfo, fragShaderStageInfo};

    // Vertex input for quad vertices
    VkVertexInputBindingDescription quadBinding{
      .binding   = 0,
      .stride    = sizeof(vec2),
      .inputRate = VK_VERTEX_INPUT_RATE_VERTEX,
    };

    VkVertexInputAttributeDescription quadAttribute{
      .location = 0,
      .binding  = 0,
      .format   = VK_FORMAT_R32G32_SFLOAT,
      .offset   = 0,
    };

    // Instance input for text instance data
    VkVertexInputBindingDescription instanceBinding{
      .binding   = 1,
      .stride    = sizeof(TextInstance),
      .inputRate = VK_VERTEX_INPUT_RATE_INSTANCE,
    };

    std::array<VkVertexInputAttributeDescription, 5> instanceAttributes = {
      VkVertexInputAttributeDescription{
        .location = 1,
        .binding  = 1,
        .format   = VK_FORMAT_R32G32_SFLOAT,
        .offset   = offsetof(TextInstance, position),
      },
      VkVertexInputAttributeDescription{
        .location = 2,
        .binding  = 1,
        .format   = VK_FORMAT_R32G32_SFLOAT,
        .offset   = offsetof(TextInstance, uvTopLeft),
      },
      VkVertexInputAttributeDescription{
        .location = 3,
        .binding  = 1,
        .format   = VK_FORMAT_R32G32_SFLOAT,
        .offset   = offsetof(TextInstance, uvBottomRight),
      },
      VkVertexInputAttributeDescription{
        .location = 4,
        .binding  = 1,
        .format   = VK_FORMAT_R32G32_SFLOAT,
        .offset   = offsetof(TextInstance, size),
      },
      VkVertexInputAttributeDescription{
        .location = 5,
        .binding  = 1,
        .format   = VK_FORMAT_R32G32B32A32_SFLOAT,  // Changed to vec4 format
        .offset   = offsetof(TextInstance, color),
      }
    };

    std::array<VkVertexInputBindingDescription, 2> bindings = {quadBinding, instanceBinding};
    std::array<VkVertexInputAttributeDescription, 6> attributes = {quadAttribute, 
      instanceAttributes[0], instanceAttributes[1], instanceAttributes[2], 
      instanceAttributes[3], instanceAttributes[4]};

    VkPipelineVertexInputStateCreateInfo vertexInputInfo{
      .sType                           = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
      .vertexBindingDescriptionCount   = static_cast<uint32_t>(bindings.size()),
      .pVertexBindingDescriptions      = bindings.data(),
      .vertexAttributeDescriptionCount = static_cast<uint32_t>(attributes.size()),
      .pVertexAttributeDescriptions    = attributes.data(),
    };

    VkPipelineInputAssemblyStateCreateInfo inputAssembly{
      .sType                  = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
      .topology               = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
      .primitiveRestartEnable = VK_FALSE,
    };

    // We'll set viewport and scissor dynamically
    VkPipelineViewportStateCreateInfo viewportState{
      .sType         = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
      .viewportCount = 1,
      .scissorCount  = 1,
    };

    VkPipelineRasterizationStateCreateInfo rasterizer{
      .sType                   = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
      .depthClampEnable        = VK_FALSE,
      .rasterizerDiscardEnable = VK_FALSE,
      .polygonMode             = VK_POLYGON_MODE_FILL,
      .cullMode                = VK_CULL_MODE_BACK_BIT,
      .frontFace               = VK_FRONT_FACE_CLOCKWISE,
      .depthBiasEnable         = VK_FALSE,
      .lineWidth               = 1.0f,
    };

    VkPipelineMultisampleStateCreateInfo multisampling{
      .sType                = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
      .rasterizationSamples = vulkan_.getMSAASamples(),
      .sampleShadingEnable  = VK_FALSE,
    };

    VkPipelineColorBlendAttachmentState colorBlendAttachment{
      .blendEnable         = VK_TRUE,
      .srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA,
      .dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
      .colorBlendOp        = VK_BLEND_OP_ADD,
      .srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE,
      .dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO,
      .alphaBlendOp        = VK_BLEND_OP_ADD,
      .colorWriteMask      = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | 
                             VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
    };

    VkPipelineColorBlendStateCreateInfo colorBlending{
      .sType           = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
      .logicOpEnable   = VK_FALSE,
      .attachmentCount = 1,
      .pAttachments    = &colorBlendAttachment,
    };

    std::array<VkDynamicState, 2> dynamicStates = {
      VK_DYNAMIC_STATE_VIEWPORT,
      VK_DYNAMIC_STATE_SCISSOR
    };

    VkPipelineDynamicStateCreateInfo dynamicState{
      .sType             = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
      .dynamicStateCount = static_cast<uint32_t>(dynamicStates.size()),
      .pDynamicStates    = dynamicStates.data(),
    };

    VkGraphicsPipelineCreateInfo pipelineInfo{
      .sType               = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
      .stageCount          = 2,
      .pStages             = shaderStages,
      .pVertexInputState   = &vertexInputInfo,
      .pInputAssemblyState = &inputAssembly,
      .pViewportState      = &viewportState,
      .pRasterizationState = &rasterizer,
      .pMultisampleState   = &multisampling,
      .pColorBlendState    = &colorBlending,
      .pDynamicState       = &dynamicState,
      .layout              = pipelineLayout_,
      .renderPass          = vulkan_.getRenderPass(),
      .subpass             = 0,
    };

    VR(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipelineInfo, nullptr, &renderPipeline_),
       "Failed to create text graphics pipeline");
  }

  GlyphInfo& getOrCreateGlyph(uint32_t codepoint) {
    auto it = glyphMap_.find(codepoint);
    if (it != glyphMap_.end()) {
      return it->second;
    }

    if (!face_) {
      throw std::runtime_error("No font loaded for glyph rendering");
    }

    // Load glyph
    FT_UInt  glyphIndex = FT_Get_Char_Index(face_, codepoint);
    FT_Error error      = FT_Load_Glyph(face_, glyphIndex, FT_LOAD_DEFAULT);
    if (error) {
      throw std::runtime_error("Failed to load glyph");
    }

    error = FT_Render_Glyph(face_->glyph, FT_RENDER_MODE_NORMAL);
    if (error) {
      throw std::runtime_error("Failed to render glyph");
    }

    FT_GlyphSlot slot   = face_->glyph;
    FT_Bitmap&   bitmap = slot->bitmap;

    // Check if glyph fits in current line
    if (currentX_ + bitmap.width > atlasWidth_) {
      currentX_ = 0;
      currentY_ += lineHeight_;

      if (currentY_ + lineHeight_ > atlasHeight_) {
        throw std::runtime_error(
          "Atlas texture is full - need to implement dynamic resizing");
      }
    }

    // Upload glyph to atlas
    if (bitmap.width > 0 && bitmap.rows > 0) {
      updateAtlasTexture(bitmap, currentX_, currentY_);
    }

    // Create glyph info
    GlyphInfo glyph;
    glyph.atlasUV[0] = {static_cast<float>(currentX_) / atlasWidth_,
                        static_cast<float>(currentY_) / atlasHeight_};
    glyph.atlasUV[1] = {
      static_cast<float>(currentX_ + bitmap.width) / atlasWidth_,
      static_cast<float>(currentY_ + bitmap.rows) / atlasHeight_};
    glyph.size    = {static_cast<float>(bitmap.width),
                     static_cast<float>(bitmap.rows)};
    glyph.bearing = {static_cast<float>(slot->bitmap_left),
                     static_cast<float>(slot->bitmap_top)};
    glyph.advance = static_cast<float>(slot->advance.x / 64);

    currentX_ += bitmap.width + 1;  // Add 1 pixel padding

    return glyphMap_[codepoint] = glyph;
  }

  // Get kerning adjustment between two characters
  float getKerning(uint32_t leftChar, uint32_t rightChar) {
    if (!face_ || !FT_HAS_KERNING(face_)) {
      return 0.0f;  // Font doesn't support kerning
    }

    FT_UInt leftIndex = FT_Get_Char_Index(face_, leftChar);
    FT_UInt rightIndex = FT_Get_Char_Index(face_, rightChar);

    if (leftIndex == 0 || rightIndex == 0) {
      return 0.0f;  // One of the characters not found
    }

    FT_Vector kerning;
    FT_Error error = FT_Get_Kerning(face_, leftIndex, rightIndex, FT_KERNING_DEFAULT, &kerning);
    
    if (error) {
      return 0.0f;  // Error getting kerning
    }

    // Convert from 26.6 fractional pixels to regular pixels
    float kernOffset = static_cast<float>(kerning.x / 64.0f);
    
#if TEXT_RENDERER_DEBUG
    // Debug output for significant kerning adjustments
    if (std::abs(kernOffset) > 0.5f) {
      static int debugCounter = 0;
      if (debugCounter++ % 60 == 0) {  // Print occasionally to avoid spam
        std::cout << "Kerning: '" << static_cast<char>(leftChar) 
                  << "' + '" << static_cast<char>(rightChar) 
                  << "' = " << kernOffset << " pixels" << std::endl;
      }
    }
#endif
    return kernOffset;
  }

  void updateAtlasTexture(const FT_Bitmap& bitmap, int x, int y) {
    // Create staging buffer
    VkDeviceSize bufferSize = bitmap.width * bitmap.rows;
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
    memcpy(data, bitmap.buffer, bufferSize);
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
                      static_cast<uint32_t>(bitmap.rows),
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

canvas::VoidResult TextRenderer::loadFont(const std::string& fontPath, int fontSize) {
  return impl_->initializeFreeType(fontPath, fontSize);
}

void TextRenderer::cleanUp() { impl_->cleanUp(); }
void TextRenderer::beginTextRendering() { 
    impl_->instanceData_.clear(); 
}

void TextRenderer::renderText(const std::string& text, vec2 position, vec3 color, TextAlign align) {
    if (!impl_->face_) {
        thread_local static int frameCointer = 0;
        if (frameCointer++ % 1000 == 0)
          std::cerr << "No font loaded, cannot render text." << std::endl;
        return;
    }

    float x = position.x;
    float y = position.y;

    // Handle text alignment
    if (align != TextAlign::Left) {
        TextMetrics metrics = getTextMetrics(text);
        if (align == TextAlign::Center) {
            x -= metrics.w * 0.5f;
        } else if (align == TextAlign::Right) {
            x -= static_cast<float>(metrics.w);
        }
    }

    // Process each character using UTF-8 decoder
    uint32_t previousChar = 0;  // Track previous character for kerning
    utils::utf8::read(text, [&](uint32_t codepoint) {
        if (codepoint == ' ') {
            x += static_cast<float>(impl_->face_->size->metrics.max_advance / 64) * 0.5f;
            previousChar = codepoint;
            return;
        }

        // Apply kerning if we have a previous character
        if (previousChar != 0) {
            float kerningOffset = impl_->getKerning(previousChar, codepoint);
            x += kerningOffset;
        }

        GlyphInfo& glyph = impl_->getOrCreateGlyph(codepoint);

        // Create text instance
        TextInstance instance;
        instance.position      = {x + glyph.bearing.x, y - glyph.bearing.y};
        instance.uvTopLeft     = glyph.atlasUV[0];
        instance.uvBottomRight = glyph.atlasUV[1];
        instance.size          = glyph.size;
        instance.color         = {color.x, color.y, color.z, 1.0f}; // Convert vec3 to vec4 with alpha

        impl_->instanceData_.push_back(instance);

        x += glyph.advance;
        previousChar = codepoint;  // Update previous character
    });
}

void TextRenderer::endTextRendering() {
    if (impl_->instanceData_.empty()) return;

    // Upload instance data to GPU
    VkDeviceSize dataSize = impl_->instanceData_.size() * sizeof(TextInstance);

    void*    mappedMemory;
    VkDevice device = impl_->vulkan_.getDevice();
    vkMapMemory(device, impl_->instanceBufferMemory_, 0, dataSize, 0, &mappedMemory);
    memcpy(mappedMemory, impl_->instanceData_.data(), dataSize);
    vkUnmapMemory(device, impl_->instanceBufferMemory_);
}

void TextRenderer::draw(VkCommandBuffer commandBuffer, vec2 viewportSize) {
    if (impl_->instanceData_.empty()) return;
    
    // Bind the text rendering pipeline
    vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, impl_->renderPipeline_);

    // Bind descriptor sets (atlas texture)
    bindDescriptorSet(commandBuffer);

    // Set push constants (projection matrix and viewport size)
    struct {
        glm::mat4 projection;
        glm::vec2 viewportSize;
    } pushConstants;
    
    pushConstants.viewportSize = glm::vec2(viewportSize.x, viewportSize.y);
    pushConstants.projection = glm::ortho(0.0f, viewportSize.x, 0.0f, viewportSize.y, -1.0f, 1.0f);
    
    vkCmdPushConstants(commandBuffer, impl_->pipelineLayout_, VK_SHADER_STAGE_VERTEX_BIT,
                       0, sizeof(pushConstants), &pushConstants);

    // Bind vertex buffers
    VkBuffer vertexBuffers[] = { impl_->quadVertexBuffer_, impl_->instanceBuffer_ };
    VkDeviceSize offsets[] = { 0, 0 };
    vkCmdBindVertexBuffers(commandBuffer, 0, 2, vertexBuffers, offsets);

    // Draw instanced quads (6 vertices per quad)
    vkCmdDraw(commandBuffer, 6, static_cast<uint32_t>(impl_->instanceData_.size()), 0, 0);
}

TextMetrics TextRenderer::getTextMetrics(const std::string& text) {
    if (!impl_->face_) return {0, 0};

    TextMetrics metrics = {0, impl_->lineHeight_};
    float       width   = 0.0f;

    uint32_t previousChar = 0;  // Track previous character for kerning
    utils::utf8::read(text, [&](uint32_t codepoint) {
        if (codepoint == ' ') {
            width += static_cast<float>(impl_->face_->size->metrics.max_advance / 64) * 0.5f;
            previousChar = codepoint;
            return;
        }

        // Apply kerning if we have a previous character
        if (previousChar != 0) {
            float kerningOffset = impl_->getKerning(previousChar, codepoint);
            width += kerningOffset;
        }

        GlyphInfo& glyph = impl_->getOrCreateGlyph(codepoint);
        width += glyph.advance;
        previousChar = codepoint;
    });

    metrics.w = static_cast<int>(width);
    return metrics;
}

float TextRenderer::getLineHeight() const {
    return static_cast<float>(impl_->lineHeight_);
}

void TextRenderer::bindDescriptorSet(VkCommandBuffer commandBuffer) {
    vkCmdBindDescriptorSets(commandBuffer,
                            VK_PIPELINE_BIND_POINT_GRAPHICS,
                            impl_->pipelineLayout_,
                            0,
                            1,
                            &impl_->descriptorSet_,
                            0,
                            nullptr);
}
